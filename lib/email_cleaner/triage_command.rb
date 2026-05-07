# frozen_string_literal: true

require "date"
require_relative "auto_read_state"
require_relative "browser"
require_relative "gmail_client"
require_relative "log_writer"
require_relative "preferences_finder"
require_relative "pretty"
require_relative "snapshot"
require_relative "trasher"
require_relative "unsubscriber"

module EmailCleaner
  # Interactive triage: walks the audit-actionable list one sender at a
  # time, prompting for an action per sender. Saves state after every
  # decision so the user can quit and resume later — undecided senders
  # automatically reappear next run because no state was written for them.
  #
  # Per-sender menu:
  #   u — unsubscribe + trash all matching messages
  #   m — open URL in browser, mark done, trash backlog
  #   k — keep for DEFAULT_KEEP_DAYS days
  #   t — trash backlog only (no state change)
  #   s — skip (no state change)
  #   q — quit
  module TriageCommand
    module_function

    def run(options:, gmail_service:, state:, log_path:, auto_read_path:,
            io: $stdout, stdin: $stdin, progress: $stderr)
      snapshot = build_snapshot(options, gmail_service, state, progress, query_override: nil)

      if snapshot.empty?
        io.puts "Nothing to triage. Inbox is clean (or fully decided)."
        return 0
      end

      auto_read = AutoReadState.new(path: auto_read_path)

      total_msgs = snapshot.sum(&:count)
      io.puts Pretty.bold("Triaging #{snapshot.size} senders representing #{total_msgs} messages.")
      io.puts Pretty.dim("Type ? for help, q to quit.")
      io.puts

      decisions = { unsub: [], done: [], keep: [], trash: [], skip: [], auto_read: [] }
      total_trashed = 0

      LogWriter.open(log_path, command: "triage") do |log|
        log.write("session_start", "#{snapshot.size} senders")

        snapshot.each_with_index do |stats, idx|
          render_sender(stats, idx + 1, snapshot.size, io)

          choice, trashed_this_step = prompt_and_act(stats, gmail_service, state, auto_read, log, io, stdin, progress)

          if choice == :quit
            state.save
            print_recap(decisions, total_trashed, idx, snapshot.size, io)
            return 0
          end

          decisions[choice] << decision_record(stats, choice, trashed_this_step)
          total_trashed += trashed_this_step
          state.save
          io.puts Pretty.dim("  so far: #{format_tally(decisions)}")
          io.puts
        end

        log.write("session_end")
      end

      print_recap(decisions, total_trashed, snapshot.size, snapshot.size, io)
      0
    end

    # Returns [choice_symbol, trashed_count]. Loops on unrecognized
    # input. Returns [:quit, 0] if the user typed q (or EOF).
    def prompt_and_act(stats, gmail, state, auto_read, log, io, stdin, progress)
      loop do
        io.print Pretty.cyan("[u/m/k/t/s/r/R/q/?]") + " > "
        answer = stdin.gets || "q"
        answer_raw = answer.strip
        answer = answer_raw.downcase

        case answer_raw
        when "R"
          handle_auto_read_domain(stats, auto_read, log, io); return [:auto_read, 0]
        end

        case answer
        when "u"         then return [:unsub, handle_unsub_and_trash(stats, gmail, state, log, io, progress)]
        when "m"         then return [:done,  handle_mark_done(stats, gmail, state, log, io, progress)]
        when "k"         then handle_keep(stats, state, log, io); return [:keep, 0]
        when "t"         then return [:trash, trash_backlog(stats, gmail, log, io, progress)]
        when "s"         then handle_skip(stats, log, io); return [:skip, 0]
        when "r"         then handle_auto_read_addr(stats, auto_read, log, io); return [:auto_read, 0]
        when "q", ""     then handle_quit(log, io); return [:quit, 0]
        when "?", "help" then print_help(io)
        else
          io.puts "  " + Pretty.dim("unrecognized: '#{answer_raw}' — type ? for help")
        end
      end
    end

    def handle_auto_read_addr(stats, auto_read, log, io)
      addr = stats.sender.address
      auto_read.add(addr)
      auto_read.save
      log.write("auto_read_addr", addr, "ok")
      io.puts "  " + Pretty.green("auto-read: #{addr} (run `auto-read sync` to apply)")
    end

    def handle_auto_read_domain(stats, auto_read, log, io)
      addr = stats.sender.address
      domain = addr.split("@", 2).last.to_s.downcase
      auto_read.add_domain(domain)
      auto_read.save
      log.write("auto_read_domain", domain, "ok")
      io.puts "  " + Pretty.green("auto-read domain: @#{domain} (run `auto-read sync` to apply)")
    end

    # Audit-actionable senders that haven't yet been decided. Reuses the
    # shared Snapshot.all_senders pipeline plus per-triage filtering.
    def build_snapshot(options, gmail_service, state, progress, query_override: nil)
      stats = Snapshot.all_senders(
        days: options[:days], gmail_service: gmail_service,
        state: state, progress: progress, query_override: query_override
      )
      min = options[:min] || EmailCleaner::DEFAULT_MIN_COUNT
      stats.select do |s|
        s.unsub_info &&
          s.count >= min &&
          s.state_status != :confirmed &&
          s.state_status != :kept
      end
    end

    def render_sender(stats, position, total, io)
      header = Pretty.dim("[#{position} of #{total}]") + " " +
               Pretty.bold(stats.sender.address) +
               (stats.sender.name ? Pretty.dim(" (#{stats.sender.name})") : "") +
               " — " + Pretty.bold(stats.count.to_s) + Pretty.dim(" messages")
      io.puts header

      marks = []
      marks << "unsub: #{Pretty.green('✓')}" if stats.unsub_info
      marks << "1-click: #{Pretty.green('✓')}" if stats.unsub_info&.one_click?
      io.puts "  #{marks.join("  ")}" unless marks.empty?

      stats.recent_subjects.first(3).each_with_index do |subj, i|
        prefix = i.zero? ? "  recent: " : "          "
        io.puts prefix + Pretty.dim(subj)
      end
    end

    # Returns the number of messages trashed.
    def handle_unsub_and_trash(stats, gmail, state, log, io, progress)
      addr = stats.sender.address

      result = Unsubscriber.new(gmail_service: gmail).run(stats)
      log.write("unsub", addr, result[:method], result[:status], result[:confirmed] ? "ok" : "failed")
      status_word = result[:confirmed] ? Pretty.green("ok") : Pretty.red("failed")
      io.puts "  unsub: #{result[:method]} → #{result[:status]} (#{status_word})"

      state.record(addr,
                   method: result[:method],
                   status: result[:status],
                   confirmed: result[:confirmed],
                   last_url: result[:url])

      trash_backlog(stats, gmail, log, io, progress)
    end

    def handle_mark_done(stats, gmail, state, log, io, progress)
      addr = stats.sender.address
      url = preferences_url_for(stats, gmail, log, io) ||
            stats.unsub_info&.https_url ||
            stats.unsub_info&.mailto_url

      if url && url.start_with?("https://", "http://")
        opened = Browser.open(url)
        log.write("open", addr, url, opened ? "ok" : "failed")
        if opened
          io.puts "  opened: #{Pretty.cyan(url)}"
        else
          io.puts "  " + Pretty.red("could not open browser") + "; copy this URL: #{url}"
        end
      end

      state.record(addr, method: :manual, status: "confirmed", confirmed: true, last_url: url)
      log.write("done", addr, "manual", "confirmed", "ok")
      io.puts "  " + Pretty.green("marked done")

      trash_backlog(stats, gmail, log, io, progress)
    end

    # Looks at the most recent message body for a "manage preferences"
    # link — usually the right destination for senders with multiple
    # streams (NYT, Substack, etc.) where the List-Unsubscribe header
    # would only kill one specific newsletter.
    def preferences_url_for(stats, gmail, log, io)
      return nil if stats.message_ids.empty?

      msg_id = stats.message_ids.first
      body = GmailClient.new(service: gmail).fetch_message_body(msg_id)
      url = PreferencesFinder.find(body)

      if url
        log.write("prefs", stats.sender.address, "found", url)
        io.puts "  " + Pretty.green("found preferences page")
      else
        log.write("prefs", stats.sender.address, "none")
      end
      url
    end

    def handle_keep(stats, state, log, io)
      addr = stats.sender.address
      until_date = Date.today + EmailCleaner::DEFAULT_KEEP_DAYS
      state.keep(addr, until_date: until_date)
      log.write("keep", addr, "-", "until=#{until_date}", "ok")
      io.puts "  " + Pretty.yellow("kept until #{until_date}")
    end

    # Trashes every message id in the snapshot for this sender. Returns
    # the trashed count for the recap. Logs "no_ids" if the snapshot is
    # empty (already trashed, etc.).
    def trash_backlog(stats, gmail, log, io, progress)
      addr = stats.sender.address
      if stats.message_ids.empty?
        log.write("trash", addr, 0, "no_ids")
        io.puts "  " + Pretty.dim("trash: nothing to do (no message ids in snapshot)")
        return 0
      end

      summary = Trasher.new(gmail_service: gmail, progress: progress).trash(stats.message_ids)
      errors = summary[:errors]
      trashed = summary[:trashed]
      err_part = errors.zero? ? Pretty.dim("0 errors") : Pretty.red("#{errors} errors")
      log.write("trash", addr, trashed, errors.zero? ? "ok" : "failed")
      io.puts "  trash: #{Pretty.green("#{trashed} trashed")}, #{err_part}"
      trashed
    end

    def handle_skip(stats, log, io)
      log.write("skip", stats.sender.address, "ok")
      io.puts "  " + Pretty.dim("skipped")
    end

    def handle_quit(log, io)
      log.write("quit", "ok")
      io.puts Pretty.dim("Quit. State saved; resume anytime.")
    end

    def print_help(io)
      io.puts <<~HELP.gsub(/^/, "  ")
        #{Pretty.bold('u')} — unsubscribe + trash backlog
        #{Pretty.bold('m')} — mark done (open URL in browser, record as manually unsubscribed, trash backlog)
        #{Pretty.bold('k')} — keep #{EmailCleaner::DEFAULT_KEEP_DAYS}d (auto-resurfaces after that)
        #{Pretty.bold('t')} — trash backlog only (no state change)
        #{Pretty.bold('s')} — skip (no state change, reappears next run)
        #{Pretty.bold('r')} — auto-read this address (local only; run `auto-read sync` to apply)
        #{Pretty.bold('R')} — auto-read whole domain (local only; run `auto-read sync` to apply)
        #{Pretty.bold('q')} — quit (state is saved)
      HELP
    end

    # Builds the per-decision row for the recap. Trashed count and
    # kept_until are shown in the recap when present.
    def decision_record(stats, choice, trashed)
      record = { address: stats.sender.address }
      record[:trashed] = trashed if trashed.positive?
      record[:until] = (Date.today + EmailCleaner::DEFAULT_KEEP_DAYS) if choice == :keep
      record
    end

    def format_tally(decisions)
      [
        "#{decisions[:unsub].size} unsub",
        "#{decisions[:done].size} done",
        "#{decisions[:keep].size} keep",
        "#{decisions[:trash].size} trash",
        "#{decisions[:skip].size} skip",
        "#{decisions[:auto_read].size} auto-read"
      ].join(", ")
    end

    RECAP_HEADINGS = {
      unsub:     "Unsubscribed",
      done:      "Marked done",
      keep:      "Kept",
      trash:     "Trashed only",
      skip:      "Skipped",
      auto_read: "Marked auto-read"
    }.freeze

    def print_recap(decisions, total_trashed, processed, total, io)
      io.puts
      io.puts Pretty.bold("Session recap: #{processed} of #{total} senders triaged.")
      io.puts "  " + format_tally(decisions)

      RECAP_HEADINGS.each do |action, heading|
        rows = decisions[action]
        next if rows.empty?

        io.puts
        io.puts Pretty.bold(heading) + ":"
        rows.each { |r| io.puts "  " + format_recap_row(r) }
      end

      if total_trashed.positive?
        io.puts
        io.puts Pretty.dim("Total messages trashed: #{total_trashed}")
      end
    end

    def format_recap_row(r)
      line = r[:address]
      line += Pretty.dim(" (#{r[:trashed]} trashed)") if r[:trashed]
      line += Pretty.dim(" (until #{r[:until]})") if r[:until]
      line
    end
  end
end
