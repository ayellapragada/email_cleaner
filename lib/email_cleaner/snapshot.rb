# frozen_string_literal: true

require_relative "aggregator"
require_relative "gmail_client"
require_relative "pattern_matcher"
require_relative "query_builder"

module EmailCleaner
  # Shared fetch -> aggregate -> annotate pipeline used by every
  # command that needs sender stats. Pulls metadata for messages in the
  # window (optionally narrowed to a Gmail `from:` query), groups by
  # sender, drops singletons, and tags each row with state status.
  module Snapshot
    module_function

    # For the audit subcommand: no pattern, no pre-filter; gets every
    # sender in the window so the table can show the full picture.
    def all_senders(days:, gmail_service:, state:, progress:)
      messages = fetch_messages(query: "newer_than:#{days}d",
                                gmail_service: gmail_service, progress: progress)
      stats = Aggregator.group(messages)
      stats = Aggregator.drop_singletons(stats)
      state.annotate(stats)
      stats
    end

    # For pattern-targeted commands (unsubscribe, keep): pushes the
    # pattern down into the Gmail query so we don't refetch the whole
    # inbox just to filter to one sender.
    def matching_senders(pattern:, days:, gmail_service:, state:, progress:)
      messages = fetch_messages(query: QueryBuilder.from_pattern(pattern, days),
                                gmail_service: gmail_service, progress: progress)
      stats = Aggregator.group(messages)
      state.annotate(stats)
      PatternMatcher.filter(stats, pattern)
    end

    def fetch_messages(query:, gmail_service:, progress:)
      client = GmailClient.new(service: gmail_service, progress: progress)
      ids = client.list_message_ids(query: query)
      messages = client.fetch_metadata_batched(ids)
      progress.puts "Fetched #{messages.size} messages."
      messages
    end
  end
end
