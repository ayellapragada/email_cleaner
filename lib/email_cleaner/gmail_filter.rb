# lib/email_cleaner/gmail_filter.rb
# frozen_string_literal: true

require "google/apis/gmail_v1"

module EmailCleaner
  # Thin wrapper around users.settings.filters plus the query builder
  # used to compose the managed auto-read filter from a list of
  # addresses and domains. Filters are immutable in the Gmail API, so
  # "updating" means delete + create.
  class GmailFilter
    MAX_QUERY_LENGTH = 1500

    class EmptyError   < StandardError; end
    class TooLongError < StandardError; end

    def self.build_query(addresses:, domains:)
      parts = addresses.map(&:to_s) + domains.map { |d| "@#{d}" }
      raise EmptyError, "no addresses or domains" if parts.empty?

      query = "from:(#{parts.join(' OR ')})"
      if query.length > MAX_QUERY_LENGTH
        raise TooLongError, "query length #{query.length} exceeds #{MAX_QUERY_LENGTH} (entries: #{parts.size})"
      end

      query
    end

    def initialize(service:)
      @service = service
    end

    def create(query:)
      filter = Google::Apis::GmailV1::Filter.new(
        criteria: Google::Apis::GmailV1::FilterCriteria.new(query: query),
        action:   Google::Apis::GmailV1::FilterAction.new(remove_label_ids: ["UNREAD"])
      )
      @service.create_user_setting_filter("me", filter).id
    end

    # Returns :ok on success, :not_found if the filter id was already
    # gone server-side (manual deletion or stale id from a half-failed
    # prior sync).
    def delete(id:)
      @service.delete_user_setting_filter("me", id)
      :ok
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404

      :not_found
    end
  end
end
