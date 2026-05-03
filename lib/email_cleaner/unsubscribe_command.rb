# frozen_string_literal: true

require_relative "log_writer"
require_relative "prompt"
require_relative "snapshot"
require_relative "table"
require_relative "unsubscriber"

module EmailCleaner
  module UnsubscribeCommand
    module_function

    # Bulk unsubscribe by pattern, with confirmation prompt. For
    # one-sender-at-a-time interactive flow, use `triage` instead.
    def run(pattern:, options:, gmail_service:, state:, log_path:, io: $stdout, stdin: $stdin, progress: $stderr)
      matched = Snapshot.matching_senders(
        pattern: pattern, days: options[:days],
        gmail_service: gmail_service, state: state, progress: progress
      ).select { |s| s.unsub_info }

      if matched.empty?
        io.puts "No matches."
        return 0
      end

      Table.print(matched, io: io)
      io.puts

      unless Prompt.confirm?("Unsubscribe from #{matched.size} senders?",
                             io: io, stdin: stdin, assume_yes: options[:yes])
        io.puts "Aborted."
        return 0
      end

      executor = Unsubscriber.new(gmail_service: gmail_service)
      summary = { success: 0, manual: 0, error: 0 }

      begin
        LogWriter.open(log_path, command: "unsubscribe") do |log|
          matched.each do |s|
            io.puts "warn: #{s.sender.address} already confirmed-unsubscribed; re-firing." \
              if state.already_unsubscribed?(s.sender.address)

            result = executor.run(s)
            state.record(
              s.sender.address,
              method: result[:method],
              status: result[:status],
              confirmed: result[:confirmed],
              last_url: result[:url]
            )
            log.write(result[:method], s.sender.address, result[:status])
            print_per_sender_result(result, s.sender.address, summary, io)
          end
        end
      ensure
        # Always persist what we did, even if the loop crashes mid-run.
        state.save
      end

      io.puts
      io.puts "#{summary[:success]} succeeded, #{summary[:manual]} manual, #{summary[:error]} errors."
      summary[:error].positive? ? 1 : 0
    end

    def print_per_sender_result(result, addr, summary, io)
      case result[:method]
      when :one_click
        io.puts "[one-click] #{addr} → HTTP #{result[:status]}"
        result[:confirmed] ? summary[:success] += 1 : summary[:error] += 1
      when :https_only
        io.puts "[manual] #{addr} → #{result[:url]}"
        summary[:manual] += 1
      when :mailto
        io.puts "[mailto] #{addr} → sent"
        summary[:success] += 1
      when :error
        io.puts "[error] #{addr} → #{result[:status]}"
        summary[:error] += 1
      end
    end
  end
end
