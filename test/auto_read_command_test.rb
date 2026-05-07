# test/auto_read_command_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "email_cleaner/auto_read_command"
require "email_cleaner/auto_read_state"

class AutoReadCommandTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "auto_read.yaml")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  # Captures GmailFilter calls without hitting any service.
  class FakeFilter
    attr_reader :created_with, :deleted_ids
    def initialize(create_returns: "FID-NEW", delete_result: :ok)
      @create_returns = create_returns
      @delete_result  = delete_result
      @created_with   = []
      @deleted_ids    = []
    end
    def create(query:)
      @created_with << query
      @create_returns
    end
    def delete(id:)
      @deleted_ids << id
      @delete_result
    end
  end

  def state
    EmailCleaner::AutoReadState.new(path: @path)
  end

  def test_add_persists_address
    out = StringIO.new
    rc = EmailCleaner::AutoReadCommand.run(
      argv: ["add", "a@x.com"], state_path: @path, gmail_filter: FakeFilter.new, io: out
    )
    assert_equal 0, rc
    assert_equal ["a@x.com"], state.addresses
  end

  def test_add_persists_domain
    EmailCleaner::AutoReadCommand.run(
      argv: ["add", "@chase.com"], state_path: @path, gmail_filter: FakeFilter.new, io: StringIO.new
    )
    assert_equal ["chase.com"], state.domains
  end

  def test_remove_persists
    s = state; s.add("a@x.com"); s.save
    EmailCleaner::AutoReadCommand.run(
      argv: ["remove", "a@x.com"], state_path: @path, gmail_filter: FakeFilter.new, io: StringIO.new
    )
    assert_equal [], state.addresses
  end

  def test_list_prints_entries
    s = state; s.add("a@x.com"); s.add_domain("y.com"); s.save
    out = StringIO.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["list"], state_path: @path, gmail_filter: FakeFilter.new, io: out
    )
    assert_match(/a@x\.com/, out.string)
    assert_match(/@y\.com/,  out.string)
  end

  def test_sync_creates_when_no_prior_filter
    s = state; s.add("a@x.com"); s.save
    ff = FakeFilter.new(create_returns: "FID-1")
    rc = EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_equal 0, rc
    assert_equal ["from:(a@x.com)"], ff.created_with
    assert_empty ff.deleted_ids
    assert_equal "FID-1", state.filter_id
  end

  def test_sync_deletes_then_creates_when_filter_id_present
    s = state; s.add("a@x.com"); s.filter_id = "FID-OLD"; s.save
    ff = FakeFilter.new(create_returns: "FID-NEW")
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_equal ["FID-OLD"], ff.deleted_ids
    assert_equal ["from:(a@x.com)"], ff.created_with
    assert_equal "FID-NEW", state.filter_id
  end

  def test_sync_warns_on_stale_filter_id_and_creates
    s = state; s.add("a@x.com"); s.filter_id = "STALE"; s.save
    ff = FakeFilter.new(delete_result: :not_found, create_returns: "FID-NEW")
    out = StringIO.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: out
    )
    assert_match(/already gone|not found/i, out.string)
    assert_equal "FID-NEW", state.filter_id
  end

  def test_sync_with_empty_list_deletes_filter_and_clears_id
    s = state; s.filter_id = "FID-OLD"; s.save
    ff = FakeFilter.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_equal ["FID-OLD"], ff.deleted_ids
    assert_empty ff.created_with
    assert_nil state.filter_id
  end

  def test_sync_with_empty_list_and_no_filter_is_noop
    ff = FakeFilter.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["sync"], state_path: @path, gmail_filter: ff, io: StringIO.new
    )
    assert_empty ff.deleted_ids
    assert_empty ff.created_with
  end

  def test_status_prints_count_and_filter_id
    s = state; s.add("a@x.com"); s.add_domain("y.com"); s.filter_id = "FID-1"; s.save
    out = StringIO.new
    EmailCleaner::AutoReadCommand.run(
      argv: ["status"], state_path: @path, gmail_filter: FakeFilter.new, io: out
    )
    assert_match(/1 address/, out.string)
    assert_match(/1 domain/,  out.string)
    assert_match(/FID-1/,     out.string)
  end
end
