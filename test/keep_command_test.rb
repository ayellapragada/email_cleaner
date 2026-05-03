# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "date"
require "email_cleaner/keep_command"
require "email_cleaner/state"

class KeepCommandTest < Minitest::Test
  FakeService = TestSupport::FakeGmailService

  def msg(from:, id: "id") = TestSupport.fake_message(from: from, id: id)

  def setup
    @tmp = Dir.mktmpdir
    @state = EmailCleaner::State.new(path: File.join(@tmp, "u.yaml"))
    @log = File.join(@tmp, "u.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_keeps_matched_senders_until_default_90_days
    msgs = {
      "1" => msg(from: "a@x.com"),
      "2" => msg(from: "a@x.com")
    }
    svc = FakeService.new(messages_by_id: msgs)
    rc = EmailCleaner::KeepCommand.run(
      pattern: "@x.com",
      options: { days: 30, yes: true, for: nil },
      gmail_service: svc, state: @state, log_path: @log,
      io: StringIO.new, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal 0, rc
    assert @state.kept_active?("a@x.com")
    expected_until = Date.today + EmailCleaner::DEFAULT_KEEP_DAYS
    assert_equal expected_until.to_s, @state.lookup("a@x.com")["kept_until"]
    assert_match(/keep\ta@x\.com\tuntil=#{expected_until}/, File.read(@log))
  end

  def test_for_flag_overrides_default_duration
    msgs = { "1" => msg(from: "a@x.com"), "2" => msg(from: "a@x.com") }
    svc = FakeService.new(messages_by_id: msgs)
    EmailCleaner::KeepCommand.run(
      pattern: "@x.com",
      options: { days: 30, yes: true, for: 30 },
      gmail_service: svc, state: @state, log_path: @log,
      io: StringIO.new, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal (Date.today + 30).to_s, @state.lookup("a@x.com")["kept_until"]
  end

  def test_no_matches_exits_zero
    svc = FakeService.new(messages_by_id: {})
    out = StringIO.new
    rc = EmailCleaner::KeepCommand.run(
      pattern: "nothing",
      options: { days: 30, yes: true, for: nil },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/No matches/i, out.string)
  end

  def test_no_answer_aborts
    msgs = { "1" => msg(from: "a@x.com"), "2" => msg(from: "a@x.com") }
    svc = FakeService.new(messages_by_id: msgs)
    rc = EmailCleaner::KeepCommand.run(
      pattern: "@x.com",
      options: { days: 30, yes: false, for: nil },
      gmail_service: svc, state: @state, log_path: @log,
      io: StringIO.new, stdin: StringIO.new("n\n"), progress: StringIO.new
    )
    assert_equal 0, rc
    refute @state.kept_active?("a@x.com")
  end
end
