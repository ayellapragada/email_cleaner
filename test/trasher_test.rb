# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "email_cleaner/trasher"

class TrasherTest < Minitest::Test
  class FakeGmail
    attr_reader :calls

    def initialize(raise_on: [])
      @raise_on = raise_on
      @calls = []
    end

    def batch_modify_messages(_user, request)
      @calls << request.ids.dup
      raise StandardError, "boom" if @raise_on.include?(@calls.size)
    end
  end

  def test_empty_ids_does_nothing
    gmail = FakeGmail.new
    progress = StringIO.new
    summary = EmailCleaner::Trasher.new(gmail_service: gmail, progress: progress).trash([])
    assert_equal({ trashed: 0, errors: 0 }, summary)
    assert_empty gmail.calls
    assert_empty progress.string
  end

  def test_single_batch_under_limit
    gmail = FakeGmail.new
    summary = EmailCleaner::Trasher.new(gmail_service: gmail, progress: StringIO.new).trash(%w[a b c])
    assert_equal({ trashed: 3, errors: 0 }, summary)
    assert_equal [%w[a b c]], gmail.calls
  end

  def test_chunks_into_batches_of_1000
    ids = (1..2500).map(&:to_s)
    gmail = FakeGmail.new
    summary = EmailCleaner::Trasher.new(gmail_service: gmail, progress: StringIO.new).trash(ids)
    assert_equal 2500, summary[:trashed]
    assert_equal [1000, 1000, 500], gmail.calls.map(&:size)
  end

  def test_failed_batch_is_counted_and_run_continues
    gmail = FakeGmail.new(raise_on: [1])
    progress = StringIO.new
    ids = (1..1500).map(&:to_s)
    summary = EmailCleaner::Trasher.new(gmail_service: gmail, progress: progress).trash(ids)
    assert_equal 500, summary[:trashed]
    assert_equal 1000, summary[:errors]
    assert_match(/failed to trash batch/, progress.string)
  end

  def test_uses_TRASH_label
    gmail = Minitest::Mock.new
    gmail.expect(:batch_modify_messages, nil) do |user_id, request|
      user_id == "me" &&
        request.ids == %w[a b] &&
        request.add_label_ids == ["TRASH"]
    end
    EmailCleaner::Trasher.new(gmail_service: gmail, progress: StringIO.new).trash(%w[a b])
    gmail.verify
  end
end
