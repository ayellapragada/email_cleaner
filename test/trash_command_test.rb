# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "email_cleaner/trash_command"

class TrashCommandTest < Minitest::Test
  class FakeService
    attr_reader :batch_calls, :list_queries

    def initialize(message_ids:)
      @message_ids = message_ids
      @batch_calls = []
      @list_queries = []
    end

    def list_user_messages(_user, q:, page_token: nil, max_results: 500)
      @list_queries << q
      ids = @message_ids.map { |i| Struct.new(:id).new(i) }
      Struct.new(:messages, :next_page_token).new(ids, nil)
    end

    def batch_modify_messages(_user, request)
      @batch_calls << request.ids.dup
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @log = File.join(@tmp, "trash.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_no_matches_exits_zero_with_message
    svc = FakeService.new(message_ids: [])
    out = StringIO.new
    rc = EmailCleaner::TrashCommand.run(
      pattern: "nothing",
      options: { days: 30, yes: true },
      gmail_service: svc, log_path: @log,
      io: out, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/No matches/i, out.string)
    refute File.exist?(@log)
  end

  def test_yes_skips_prompt_and_trashes
    svc = FakeService.new(message_ids: %w[a b c])
    out = StringIO.new
    rc = EmailCleaner::TrashCommand.run(
      pattern: "@x.com",
      options: { days: 30, yes: true },
      gmail_service: svc, log_path: @log,
      io: out, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal 0, rc
    assert_equal [%w[a b c]], svc.batch_calls
    assert_match(/3 trashed, 0 errors/, out.string)
    log = File.read(@log)
    assert_match(/\ttrash\t@x\.com\t3\t0/, log)
  end

  def test_no_answer_aborts_without_trashing
    svc = FakeService.new(message_ids: %w[a b])
    out = StringIO.new
    stdin = StringIO.new("n\n")
    rc = EmailCleaner::TrashCommand.run(
      pattern: "@x.com",
      options: { days: 30, yes: false },
      gmail_service: svc, log_path: @log,
      io: out, stdin: stdin, progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/Aborted/, out.string)
    assert_empty svc.batch_calls
  end

  def test_pushes_pattern_into_gmail_query
    svc = FakeService.new(message_ids: %w[a])
    EmailCleaner::TrashCommand.run(
      pattern: "@queenslibrary.org",
      options: { days: 14, yes: true },
      gmail_service: svc, log_path: @log,
      io: StringIO.new, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal "from:queenslibrary.org newer_than:14d", svc.list_queries.first
  end
end
