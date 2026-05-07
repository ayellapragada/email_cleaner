# frozen_string_literal: true

require "optparse"
require_relative "config"
require_relative "auth"
require_relative "state"
require_relative "audit"
require_relative "keep_command"
require_relative "trash_command"
require_relative "triage_command"
require_relative "unsubscribe_command"
require_relative "auto_read_command"
require_relative "gmail_filter"

module EmailCleaner
  module CLI
    module_function

    USAGE = <<~USAGE
      email_cleaner — audit and clean up Gmail bulk senders

      Usage:
        email_cleaner triage      [--days N] [--min N]
        email_cleaner audit       [--days N] [--actionable] [--min N] [--include-done] [--include-kept]
        email_cleaner unsubscribe <pattern> [--days N] [--yes]
        email_cleaner keep        <pattern> [--days N] [--for DAYS] [--yes]
        email_cleaner trash       <pattern> [--days N] [--yes]
        email_cleaner auto-read   list|add|remove|sync|status [args...]
        email_cleaner --help

      Pattern: substring on email address (case-insensitive),
               or "@domain.com" for exact domain match.
    USAGE

    def run(argv)
      argv = argv.dup
      if argv.empty? || %w[-h --help].include?(argv.first)
        puts USAGE
        return 0
      end

      subcmd = argv.shift
      case subcmd
      when "audit"        then run_audit(argv)
      when "triage"       then run_triage(argv)
      when "unsubscribe"  then run_unsubscribe(argv)
      when "keep"         then run_keep(argv)
      when "trash"        then run_trash(argv)
      when "auto-read"    then run_auto_read(argv)
      else
        warn "Unknown subcommand: #{subcmd}"
        warn USAGE
        2
      end
    rescue Auth::SetupError, Auth::AuthError => e
      warn "auth error: #{e.message}"
      1
    rescue Interrupt
      warn "\nInterrupted."
      1
    end

    # Builds the trio every command needs: a Config, an authorized Gmail
    # service, and a State pointed at the right file. Yields them so the
    # caller can inline-pick which it actually uses.
    def build_context
      config = Config.new
      service = Auth.authorize(config: config)
      state = State.new(path: config.state_path)
      [config, service, state]
    end

    def parse_options(argv, defaults, banner, &block)
      opts = defaults.dup
      parser = OptionParser.new do |o|
        o.banner = banner
        block.call(o, opts)
        o.on("-h", "--help") { puts o; exit 0 }
      end
      parser.parse!(argv)
      [opts, parser]
    end

    # Parses options + a required positional <pattern> argument. Returns
    # nil and prints usage on missing/empty pattern; caller exits 2.
    def parse_pattern_command(argv, defaults, banner, &block)
      opts, parser = parse_options(argv, defaults, banner, &block)
      pattern = argv.shift
      if pattern.nil? || pattern.empty?
        warn "missing required <pattern>"
        warn parser
        return nil
      end
      [pattern, opts]
    end

    def run_audit(argv)
      opts, _ = parse_options(
        argv,
        { days: EmailCleaner::DEFAULT_DAYS_WINDOW, actionable: false,
          min: EmailCleaner::DEFAULT_MIN_COUNT, include_done: false, include_kept: false },
        "Usage: email_cleaner audit [options]"
      ) do |o, opts|
        o.on("--days N", Integer) { |n| opts[:days] = n }
        o.on("--actionable")      { opts[:actionable] = true }
        o.on("--min N", Integer)  { |n| opts[:min] = n }
        o.on("--include-done")    { opts[:include_done] = true }
        o.on("--include-kept")    { opts[:include_kept] = true }
      end

      _, service, state = build_context
      Audit.run(options: opts, gmail_service: service, state: state)
      0
    end

    def run_triage(argv)
      opts, _ = parse_options(
        argv,
        { days: EmailCleaner::DEFAULT_DAYS_WINDOW, min: EmailCleaner::DEFAULT_MIN_COUNT },
        "Usage: email_cleaner triage [options]"
      ) do |o, opts|
        o.on("--days N",  Integer) { |n| opts[:days]  = n }
        o.on("--min N",   Integer) { |n| opts[:min]   = n }
      end

      config, service, state = build_context
      TriageCommand.run(
        options: opts, gmail_service: service, state: state,
        log_path: config.triage_log_path,
        auto_read_path: config.auto_read_path
      )
    end

    def run_auto_read(argv)
      config, service, _ = build_context
      gmail_filter = GmailFilter.new(service: service)
      AutoReadCommand.run(
        argv: argv,
        state_path: config.auto_read_path,
        gmail_filter: gmail_filter
      )
    end

    def run_unsubscribe(argv)
      result = parse_pattern_command(
        argv,
        { days: EmailCleaner::DEFAULT_DAYS_WINDOW, yes: false },
        "Usage: email_cleaner unsubscribe <pattern> [options]"
      ) do |o, opts|
        o.on("--days N", Integer) { |n| opts[:days] = n }
        o.on("--yes")             { opts[:yes] = true }
      end
      return 2 unless result

      pattern, opts = result
      config, service, state = build_context
      UnsubscribeCommand.run(
        pattern: pattern, options: opts, gmail_service: service,
        state: state, log_path: config.log_path
      )
    end

    def run_keep(argv)
      result = parse_pattern_command(
        argv,
        { days: EmailCleaner::DEFAULT_DAYS_WINDOW, for: EmailCleaner::DEFAULT_KEEP_DAYS, yes: false },
        "Usage: email_cleaner keep <pattern> [options]"
      ) do |o, opts|
        o.on("--days N", Integer)   { |n| opts[:days] = n }
        o.on("--for DAYS", Integer) { |n| opts[:for] = n }
        o.on("--yes")               { opts[:yes] = true }
      end
      return 2 unless result

      pattern, opts = result
      config, service, state = build_context
      KeepCommand.run(
        pattern: pattern, options: opts, gmail_service: service,
        state: state, log_path: config.log_path
      )
    end

    def run_trash(argv)
      result = parse_pattern_command(
        argv,
        { days: EmailCleaner::DEFAULT_DAYS_WINDOW, yes: false },
        "Usage: email_cleaner trash <pattern> [options]"
      ) do |o, opts|
        o.on("--days N", Integer) { |n| opts[:days] = n }
        o.on("--yes")             { opts[:yes] = true }
      end
      return 2 unless result

      pattern, opts = result
      config, service, _ = build_context
      TrashCommand.run(
        pattern: pattern, options: opts, gmail_service: service, log_path: config.trash_log_path
      )
    end
  end
end
