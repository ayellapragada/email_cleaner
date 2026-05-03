# frozen_string_literal: true

require_relative "snapshot"
require_relative "table"

module EmailCleaner
  module Audit
    module_function

    # options: { days:, actionable:, min:, include_done:, include_kept: }
    def run(options:, gmail_service:, state:, io: $stdout, progress: $stderr)
      stats = Snapshot.all_senders(
        days: options[:days], gmail_service: gmail_service,
        state: state, progress: progress
      )
      stats = filter(stats, options) if options[:actionable]

      Table.print(stats, io: io)
      io.puts
      io.puts "#{stats.size} senders shown, #{stats.sum(&:count)} messages."
      io.puts "Use: email_cleaner triage to walk these one at a time." if options[:actionable]
    end

    def filter(stats, options)
      stats.select do |s|
        next false if s.unsub_info.nil?
        next false if s.count < options[:min]
        next false if !options[:include_done] && s.state_status == :confirmed
        next false if !options[:include_kept] && s.state_status == :kept
        true
      end
    end
  end
end
