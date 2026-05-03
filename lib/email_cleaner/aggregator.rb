# frozen_string_literal: true

require_relative "headers"
require_relative "sender"
require_relative "sender_stats"
require_relative "unsub_info"

module EmailCleaner
  module Aggregator
    module_function

    # How many recent subject lines to retain per sender (for triage display).
    SUBJECT_RETENTION = 3

    # Input: array of {id:, headers: {String => String}, internal_date: Date}.
    # Output: array of SenderStats, sorted by count desc.
    def group(messages)
      groups = {}

      messages.each do |m|
        headers = m[:headers] || {}
        from = headers["From"]
        next if from.nil?

        name, address = Headers.parse_from(from)
        next if address.empty?

        key = address
        g = groups[key] ||= {
          name: nil,
          count: 0,
          last_seen: nil,
          list_unsub: nil,
          post: nil,
          # [{date:, subject:}, ...] — kept sorted desc by date, capped to SUBJECT_RETENTION.
          recent: [],
          message_ids: []
        }
        g[:name] ||= name
        g[:count] += 1
        date = m[:internal_date]
        g[:last_seen] = date if date && (g[:last_seen].nil? || date > g[:last_seen])
        g[:list_unsub] ||= headers["List-Unsubscribe"]
        g[:post] ||= headers["List-Unsubscribe-Post"]
        g[:message_ids] << m[:id] if m[:id]

        subject = headers["Subject"]
        if subject && date
          g[:recent] << { date: date, subject: subject }
          g[:recent].sort_by! { |e| -e[:date].to_time.to_i }
          g[:recent] = g[:recent].first(SUBJECT_RETENTION)
        end
      end

      groups.map do |address, g|
        urls = Headers.parse_list_unsubscribe(g[:list_unsub])
        unsub_info =
          if urls.empty?
            nil
          else
            UnsubInfo.new(urls: urls, one_click: Headers.one_click?(g[:post], urls))
          end

        SenderStats.new(
          sender: Sender.new(address: address, name: g[:name]),
          count: g[:count],
          unsub_info: unsub_info,
          last_seen: g[:last_seen],
          recent_subjects: g[:recent].map { |e| e[:subject] },
          message_ids: g[:message_ids]
        )
      end.sort_by { |s| -s.count }
    end

    # Drops senders with count == 1. Used by display layers (Audit) to declutter;
    # not applied during aggregation so Phase B persistence sees every sender.
    def drop_singletons(stats)
      stats.reject { |s| s.count < 2 }
    end
  end
end
