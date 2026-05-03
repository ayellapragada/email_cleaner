# frozen_string_literal: true

# A small Gmail API double used across command tests. Implements the
# methods our GmailClient and Trasher actually call:
#
#   - list_user_messages(user, q:, page_token:, max_results:) — single page
#   - batch { |svc| ... } — yields self
#   - get_user_message(user, id, format:, metadata_headers: nil, &block)
#       * with block + metadata_headers: the batch metadata fetch path
#       * without block, format: "full": single full-body fetch
#   - batch_modify_messages(user, request) — records ids in @batch_calls
#
# Construct with a hash of {id => msg}. Optionally pass full_bodies for
# the prefs-page fetch path.
module TestSupport
  class FakeGmailService
    attr_reader :batch_calls, :list_queries

    def initialize(messages_by_id:, full_bodies: {})
      @messages_by_id = messages_by_id
      @full_bodies = full_bodies
      @batch_calls = []
      @list_queries = []
    end

    def list_user_messages(_user, q:, page_token: nil, max_results: 500)
      @list_queries << q
      ids = @messages_by_id.keys.map { |i| Struct.new(:id).new(i) }
      Struct.new(:messages, :next_page_token).new(ids, nil)
    end

    def batch
      yield self
    end

    def get_user_message(_user, id, format:, metadata_headers: nil, &block)
      if block
        block.call(@messages_by_id[id], nil)
      else
        body = @full_bodies[id]
        return nil unless body

        body_part = Struct.new(:mime_type, :body, :parts).new(
          "text/html",
          Struct.new(:data).new(body),
          nil
        )
        Struct.new(:payload).new(body_part)
      end
    end

    def batch_modify_messages(_user, request)
      @batch_calls << request.ids.dup
    end
  end

  # Builds a fake Gmail message struct with the headers and id our
  # Aggregator/GmailClient pipeline expects.
  def self.fake_message(from:, list_unsub: nil, post: nil, subject: nil, id: "id", ms: 1_700_000_000_000)
    headers = { "From" => from }
    headers["List-Unsubscribe"] = list_unsub if list_unsub
    headers["List-Unsubscribe-Post"] = post if post
    headers["Subject"] = subject if subject
    Struct.new(:id, :payload, :internal_date).new(
      id,
      Struct.new(:headers).new(headers.map { |n, v| Struct.new(:name, :value).new(n, v) }),
      ms.to_s
    )
  end
end
