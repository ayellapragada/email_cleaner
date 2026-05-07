# frozen_string_literal: true
require "date"
require_relative "gmail_client"

module EmailCleaner
  # Splits a large date window into smaller fetch windows (default 7
  # days each) and accumulates messages from each. Used by Snapshot
  # when the requested window is too large for a single fetch to be
  # responsive. Aggregation happens once over the full result set —
  # this is purely a fetch-pacing concern.
  module PacedFetcher
    FETCH_WINDOW_DAYS = 7

    module_function

    def fetch(days:, gmail_service:, progress:, today: Date.today)
      windows = build_windows(days: days, today: today)
      client = GmailClient.new(service: gmail_service, progress: progress)
      seen_ids = {}
      all_ids = []
      windows.each_with_index do |w, i|
        progress.puts "fetching window #{i + 1}/#{windows.size} (#{w[:from]} → #{w[:to]})..."
        query = "after:#{w[:from].strftime('%Y/%m/%d')} before:#{w[:to].strftime('%Y/%m/%d')}"
        ids = client.list_message_ids(query: query)
        ids.each do |id|
          next if seen_ids[id]
          seen_ids[id] = true
          all_ids << id
        end
      end
      all_messages = client.fetch_metadata_batched(all_ids)
      progress.puts "fetched #{all_messages.size} messages across #{windows.size} window(s)."
      all_messages
    end

    def build_windows(days:, today: Date.today)
      result = []
      cursor_to = today
      remaining = days
      while remaining.positive?
        span = [FETCH_WINDOW_DAYS, remaining].min
        cursor_from = cursor_to - span
        result << { from: cursor_from, to: cursor_to }
        cursor_to = cursor_from
        remaining -= span
      end
      result
    end
  end
end
