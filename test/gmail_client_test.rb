# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "stringio"
require "email_cleaner/gmail_client"

class GmailClientTest < Minitest::Test
  # Minimal fake service: tracks calls, returns canned data.
  class FakeService
    attr_reader :list_calls, :batched_gets

    def initialize(message_pages:, message_responses:)
      @message_pages = message_pages       # Array of [ids, next_page_token]
      @message_responses = message_responses # Hash{id => msg or :raise}
      @list_calls = []
      @batched_gets = []
    end

    def list_user_messages(user_id, q:, page_token: nil, max_results: 500)
      @list_calls << { user_id: user_id, q: q, page_token: page_token }
      ids, next_token = @message_pages.shift
      msgs = ids.map { |i| Struct.new(:id).new(i) }
      Struct.new(:messages, :next_page_token).new(msgs, next_token)
    end

    def batch(&block)
      yield self
    end

    def get_user_message(user_id, id, format:, metadata_headers:, &block)
      @batched_gets << id
      response = @message_responses[id]
      if response == :raise
        block.call(nil, StandardError.new("boom"))
      else
        block.call(response, nil)
      end
    end
  end

  def fake_msg(id: "msg-id", headers:, internal_date_ms:)
    Struct.new(:id, :payload, :internal_date).new(
      id,
      Struct.new(:headers).new(
        headers.map { |n, v| Struct.new(:name, :value).new(n, v) }
      ),
      internal_date_ms.to_s
    )
  end

  def test_list_paginates
    pages = [[%w[a b c], "tok"], [%w[d e], nil]]
    svc = FakeService.new(message_pages: pages, message_responses: {})
    client = EmailCleaner::GmailClient.new(service: svc)

    ids = client.list_message_ids(query: "newer_than:30d")
    assert_equal %w[a b c d e], ids
    assert_equal 2, svc.list_calls.size
    assert_equal "newer_than:30d", svc.list_calls.first[:q]
  end

  def test_batch_fetches_in_chunks_of_50
    ids = (1..101).map(&:to_s)
    responses = ids.to_h { |i| [i, fake_msg(headers: { "From" => "a@b.com" }, internal_date_ms: 1_700_000_000_000)] }
    svc = FakeService.new(message_pages: [], message_responses: responses)
    client = EmailCleaner::GmailClient.new(service: svc, progress: StringIO.new)

    msgs = client.fetch_metadata_batched(ids, batch_size: 50)
    assert_equal 101, msgs.size
    assert_equal 101, svc.batched_gets.size
  end

  def test_individual_failure_warns_and_continues
    ids = %w[a b c]
    responses = {
      "a" => fake_msg(headers: { "From" => "x@y.com" }, internal_date_ms: 1_700_000_000_000),
      "b" => :raise,
      "c" => fake_msg(headers: { "From" => "z@y.com" }, internal_date_ms: 1_700_000_000_000)
    }
    svc = FakeService.new(message_pages: [], message_responses: responses)
    progress = StringIO.new
    client = EmailCleaner::GmailClient.new(service: svc, progress: progress)

    msgs = client.fetch_metadata_batched(ids)
    assert_equal 2, msgs.size
    assert_match(/warn|fail|skip/i, progress.string)
  end

  def test_message_shape_has_headers_and_date
    ids = ["a"]
    responses = { "a" => fake_msg(headers: { "From" => "x@y.com", "Subject" => "hi" }, internal_date_ms: 1_700_000_000_000) }
    svc = FakeService.new(message_pages: [], message_responses: responses)
    client = EmailCleaner::GmailClient.new(service: svc, progress: StringIO.new)

    msgs = client.fetch_metadata_batched(ids)
    assert_equal "x@y.com", msgs.first[:headers]["From"]
    assert_equal "hi", msgs.first[:headers]["Subject"]
    assert_kind_of Date, msgs.first[:internal_date]
  end
end
