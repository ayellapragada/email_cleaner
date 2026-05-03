# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "date"
require "email_cleaner/triage_command"
require "email_cleaner/state"

class TriageCommandTest < Minitest::Test
  FakeService = TestSupport::FakeGmailService

  def msg(**kwargs) = TestSupport.fake_message(**kwargs)

  def setup
    @tmp = Dir.mktmpdir
    @state = EmailCleaner::State.new(path: File.join(@tmp, "u.yaml"))
    @log = File.join(@tmp, "triage.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def actionable_msgs(addr, list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click", count: 3)
    (1..count).each_with_object({}) do |i, h|
      h[i.to_s] = msg(from: addr, list_unsub: list_unsub, post: post, id: i.to_s, subject: "Subject #{i}")
    end
  end

  def run_triage(svc, stdin_input)
    EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: StringIO.new, stdin: StringIO.new(stdin_input), progress: StringIO.new
    )
  end

  def test_empty_snapshot_exits_zero
    svc = FakeService.new(messages_by_id: {})
    rc = run_triage(svc, "")
    assert_equal 0, rc
  end

  def test_q_quits_immediately
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    rc = run_triage(svc, "q\n")
    assert_equal 0, rc
    refute @state.already_unsubscribed?("a@x.com")
    refute @state.kept_active?("a@x.com")
  end

  def test_k_keeps_for_default_period
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    rc = run_triage(svc, "k\nq\n")
    assert_equal 0, rc
    assert @state.kept_active?("a@x.com")
    expected = Date.today + EmailCleaner::DEFAULT_KEEP_DAYS
    assert_equal expected.to_s, @state.lookup("a@x.com")["kept_until"]
    assert_match(/triage\tkeep\ta@x\.com.*until=#{expected}/, File.read(@log))
  end

  def test_s_skips_without_state_change
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    rc = run_triage(svc, "s\nq\n")
    assert_equal 0, rc
    assert_nil @state.lookup("a@x.com")
    assert_match(/triage\tskip\ta@x\.com/, File.read(@log))
  end

  def test_u_fires_unsub_then_trash
    stub_request(:post, "https://x.com/u").to_return(status: 200)
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    rc = run_triage(svc, "u\nq\n")
    assert_equal 0, rc
    assert @state.already_unsubscribed?("a@x.com")
    assert_equal [%w[1 2 3]], svc.batch_calls
    log = File.read(@log)
    assert_match(/triage\tunsub\ta@x\.com\tone_click\t200\tok/, log)
    assert_match(/triage\ttrash\ta@x\.com\t3\tok/, log)
  end

  def test_u_trashes_even_if_unsub_fails
    stub_request(:post, "https://x.com/u").to_return(status: 503)
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    rc = run_triage(svc, "u\nq\n")
    assert_equal 0, rc
    refute @state.already_unsubscribed?("a@x.com")
    # state recorded the unsub error but trash still ran
    assert_equal [%w[1 2 3]], svc.batch_calls
    log = File.read(@log)
    assert_match(/triage\tunsub\ta@x\.com\tone_click\t503\tfailed/, log)
    assert_match(/triage\ttrash\ta@x\.com\t3\tok/, log)
  end

  def test_t_trash_only_no_state_change
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    rc = run_triage(svc, "t\nq\n")
    assert_equal 0, rc
    assert_nil @state.lookup("a@x.com")
    assert_equal [%w[1 2 3]], svc.batch_calls
    assert_match(/triage\ttrash\ta@x\.com\t3\tok/, File.read(@log))
  end

  def test_m_falls_back_to_list_unsubscribe_when_no_prefs_link
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    # No full_bodies set, so PreferencesFinder gets nil → fallback path.
    EmailCleaner::Browser.stub(:open, true) do
      rc = run_triage(svc, "m\nq\n")
      assert_equal 0, rc
    end
    assert @state.already_unsubscribed?("a@x.com")
    assert_equal [%w[1 2 3]], svc.batch_calls
    log = File.read(@log)
    assert_match(/triage\tprefs\ta@x\.com\tnone/, log)
    assert_match(/triage\topen\ta@x\.com\thttps:\/\/x\.com\/u\tok/, log)
    assert_match(/triage\tdone\ta@x\.com\tmanual\tconfirmed\tok/, log)
    assert_match(/triage\ttrash\ta@x\.com\t3\tok/, log)
  end

  def test_m_opens_preferences_page_when_found_in_body
    svc = FakeService.new(
      messages_by_id: actionable_msgs("a@x.com"),
      full_bodies: { "1" => '<a href="https://x.com/prefs">manage email preferences</a>' }
    )
    EmailCleaner::Browser.stub(:open, true) do
      rc = run_triage(svc, "m\nq\n")
      assert_equal 0, rc
    end
    log = File.read(@log)
    assert_match(/triage\tprefs\ta@x\.com\tfound\thttps:\/\/x\.com\/prefs/, log)
    assert_match(/triage\topen\ta@x\.com\thttps:\/\/x\.com\/prefs\tok/, log)
  end

  def test_session_header_shows_total_messages_and_recap_shows_tally
    msgs1 = actionable_msgs("a@x.com", count: 3)
    msgs2 = actionable_msgs("b@x.com", count: 5)
    # Renumber ids so they don't collide
    msgs2 = msgs2.transform_keys { |k| "b#{k}" }
    msgs2 = msgs2.transform_values do |m|
      Struct.new(:id, :payload, :internal_date).new("b#{m.id}", m.payload, m.internal_date)
    end
    svc = FakeService.new(messages_by_id: msgs1.merge(msgs2))
    out = StringIO.new
    EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new("k\nq\n"), progress: StringIO.new
    )
    # 3 + 5 = 8 total messages across 2 senders.
    assert_match(/Triaging 2 senders representing 8 messages/, out.string)
    assert_match(/Session recap: 1 of 2 senders triaged/, out.string)
    assert_match(/1 keep/, out.string)
  end

  def test_recap_lists_addresses_grouped_by_action
    stub_request(:post, "https://x.com/u").to_return(status: 200)
    msgs_a = actionable_msgs("a@x.com", count: 3)
    msgs_b = actionable_msgs("b@x.com", count: 4).transform_keys { |k| "b#{k}" }
    msgs_b = msgs_b.transform_values do |m|
      Struct.new(:id, :payload, :internal_date).new("b#{m.id}", m.payload, m.internal_date)
    end
    msgs_c = actionable_msgs("c@x.com", count: 5).transform_keys { |k| "c#{k}" }
    msgs_c = msgs_c.transform_values do |m|
      Struct.new(:id, :payload, :internal_date).new("c#{m.id}", m.payload, m.internal_date)
    end
    svc = FakeService.new(messages_by_id: msgs_a.merge(msgs_b).merge(msgs_c))
    out = StringIO.new

    EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new("u\nk\ns\n"), progress: StringIO.new
    )

    s = out.string
    # Recap groups by action heading
    assert_match(/Unsubscribed:\n.*c@x\.com/m, s)
    assert_match(/Kept:\n.*b@x\.com/m, s)
    assert_match(/Skipped:\n.*a@x\.com/m, s)
    # Total trashed count includes only the unsub'd sender's backlog.
    assert_match(/Total messages trashed: 5/, s)
  end

  def test_recap_omits_empty_action_groups
    msgs = actionable_msgs("a@x.com", count: 3)
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new
    EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new("k\n"), progress: StringIO.new
    )
    s = out.string
    refute_match(/Unsubscribed:/, s)
    refute_match(/Skipped:/, s)
    assert_match(/Kept/, s)
  end

  def test_unrecognized_input_re_prompts
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    out = StringIO.new
    EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new("xyz\nq\n"), progress: StringIO.new
    )
    assert_match(/unrecognized: 'xyz'/, out.string)
  end

  def test_skips_already_kept_senders
    @state.keep("a@x.com", until_date: Date.today + 30)
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    out = StringIO.new
    rc = EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new(""), progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/Nothing to triage/i, out.string)
  end

  def test_skips_already_confirmed_unsubscribed_senders
    @state.record("a@x.com", method: :one_click, status: 200, confirmed: true, last_url: "x")
    svc = FakeService.new(messages_by_id: actionable_msgs("a@x.com"))
    out = StringIO.new
    rc = EmailCleaner::TriageCommand.run(
      options: { days: 30, min: 3 },
      gmail_service: svc, state: @state, log_path: @log,
      io: out, stdin: StringIO.new(""), progress: StringIO.new
    )
    assert_equal 0, rc
    assert_match(/Nothing to triage/i, out.string)
  end
end
