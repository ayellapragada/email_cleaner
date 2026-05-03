# frozen_string_literal: true

require "date"
require_relative "log_writer"
require_relative "prompt"
require_relative "snapshot"
require_relative "table"

module EmailCleaner
  # Marks senders as "kept" — opt them out of audit's actionable view
  # until kept_until passes. After that they reappear automatically.
  module KeepCommand
    module_function

    def run(pattern:, options:, gmail_service:, state:, log_path:, io: $stdout, stdin: $stdin, progress: $stderr)
      matched = Snapshot.matching_senders(
        pattern: pattern, days: options[:days],
        gmail_service: gmail_service, state: state, progress: progress
      )

      if matched.empty?
        io.puts "No matches."
        return 0
      end

      Table.print(matched, io: io)
      io.puts

      keep_days = options[:for] || EmailCleaner::DEFAULT_KEEP_DAYS
      until_date = Date.today + keep_days

      unless Prompt.confirm?("Keep #{matched.size} senders until #{until_date}?",
                             io: io, stdin: stdin, assume_yes: options[:yes])
        io.puts "Aborted."
        return 0
      end

      begin
        LogWriter.open(log_path, command: "keep") do |log|
          matched.each do |s|
            state.keep(s.sender.address, until_date: until_date)
            log.write(s.sender.address, "until=#{until_date}")
            io.puts "[keep] #{s.sender.address} until #{until_date}"
          end
        end
      ensure
        state.save
      end

      io.puts
      io.puts "#{matched.size} senders kept until #{until_date}."
      0
    end
  end
end
