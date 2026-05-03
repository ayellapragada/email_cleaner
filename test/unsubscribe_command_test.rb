# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "email_cleaner/unsubscribe_command"
require "email_cleaner/state"

class UnsubscribeCommandTest < Minitest::Test
  FakeService = TestSupport::FakeGmailService

  def msg(**kwargs) = TestSupport.fake_message(**kwargs)

  def setup
    @tmp = Dir.mktmpdir
    @state = EmailCleaner::State.new(path: File.join(@tmp, "u.yaml"))
    @log_path = File.join(@tmp, "u.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    super
  end

  def test_one_click_path_records_state_and_appends_log
    stub_request(:post, "https://x.com/u").to_return(status: 200)
    msgs = {
      "1" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      "2" => msg(from: "a@substack.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click")
    }
    svc = FakeService.new(messages_by_id: msgs)

    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "substack",
      options: { days: 30, yes: true },
      gmail_service: svc, state: @state, log_path: @log_path,
      io: StringIO.new, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal 0, rc
    assert @state.already_unsubscribed?("a@substack.com")
    log = File.read(@log_path)
    assert_match(/one_click/, log)
    assert_match(/a@substack\.com/, log)
    assert_match(/200/, log)
  end

  def test_no_matches_exits_zero_with_message
    svc = FakeService.new(messages_by_id: {})
    out = StringIO.new
    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "nothing",
      options: { days: 30, yes: true },
      gmail_service: svc, state: @state, log_path: @log_path,
      io: out, stdin: StringIO.new, progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/No matches/i, out.string)
  end

  def test_prompt_no_answer_aborts
    stub = stub_request(:post, "https://x.com/u")
    msgs = {
      "1" => msg(from: "a@x.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      "2" => msg(from: "a@x.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click")
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new
    stdin = StringIO.new("n\n")

    rc = EmailCleaner::UnsubscribeCommand.run(
      pattern: "@x.com",
      options: { days: 30, yes: false },
      gmail_service: svc, state: @state, log_path: @log_path,
      io: out, stdin: stdin, progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/abort/i, out.string)
    refute_requested(stub)
    refute @state.already_unsubscribed?("a@x.com")
  end
end
