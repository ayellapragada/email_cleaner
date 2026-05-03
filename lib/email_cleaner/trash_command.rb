# frozen_string_literal: true

require_relative "gmail_client"
require_relative "log_writer"
require_relative "prompt"
require_relative "query_builder"
require_relative "trasher"

module EmailCleaner
  # Bulk-trash messages by query pattern. Operates on raw Gmail query
  # results — does not touch state or aggregate by sender. For trashing
  # a single sender's backlog interactively, use `triage`.
  module TrashCommand
    module_function

    def run(pattern:, options:, gmail_service:, log_path:, io: $stdout, stdin: $stdin, progress: $stderr)
      client = GmailClient.new(service: gmail_service, progress: progress)
      query = QueryBuilder.from_pattern(pattern, options[:days])
      ids = client.list_message_ids(query: query)

      if ids.empty?
        io.puts "No matches."
        return 0
      end

      io.puts "Found #{ids.size} messages matching '#{pattern}' in last #{options[:days]} days."

      unless Prompt.confirm?("Trash #{ids.size} messages? (recoverable for 30 days)",
                             io: io, stdin: stdin, assume_yes: options[:yes])
        io.puts "Aborted."
        return 0
      end

      summary = Trasher.new(gmail_service: gmail_service, progress: progress).trash(ids)

      LogWriter.open(log_path, command: "trash") do |log|
        log.write(pattern, summary[:trashed], summary[:errors])
      end

      io.puts "#{summary[:trashed]} trashed, #{summary[:errors]} errors."
      summary[:errors].positive? ? 1 : 0
    end
  end
end
