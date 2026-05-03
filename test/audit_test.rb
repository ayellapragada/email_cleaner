# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "email_cleaner/audit"
require "email_cleaner/state"

class AuditTest < Minitest::Test
  FakeService = TestSupport::FakeGmailService

  # Audit's tests pass a headers hash directly (lots of variants); keep
  # the local wrapper rather than adapting every call site.
  def msg(id: "id", headers:, ms: 1_700_000_000_000)
    Struct.new(:id, :payload, :internal_date).new(
      id,
      Struct.new(:headers).new(
        headers.map { |n, v| Struct.new(:name, :value).new(n, v) }
      ),
      ms.to_s
    )
  end

  def make_state
    @tmp = Dir.mktmpdir
    EmailCleaner::State.new(path: File.join(@tmp, "u.yaml"))
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp
  end

  def test_audit_default_lists_count_gt_1_senders
    msgs = {
      "1" => msg(headers: { "From" => "a@x.com" }),
      "2" => msg(headers: { "From" => "a@x.com" }),
      "3" => msg(headers: { "From" => "b@x.com" }) # count 1, dropped
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new

    EmailCleaner::Audit.run(
      options: { days: 30, actionable: false, min: 3, include_done: false },
      gmail_service: svc,
      state: make_state,
      io: out,
      progress: StringIO.new
    )

    assert_match(/a@x\.com/, out.string)
    refute_match(/b@x\.com/, out.string)
    assert_match(/senders shown/, out.string)
  end

  def test_actionable_filters_min_and_unsub_header
    msgs = {
      "1" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "2" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "3" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "4" => msg(headers: { "From" => "b@x.com" }),  # no unsub header
      "5" => msg(headers: { "From" => "b@x.com" }),
      "6" => msg(headers: { "From" => "c@x.com", "List-Unsubscribe" => "<https://x/u>" }), # only count 2 → below min 3
      "7" => msg(headers: { "From" => "c@x.com", "List-Unsubscribe" => "<https://x/u>" })
    }
    svc = FakeService.new(messages_by_id: msgs)
    out = StringIO.new

    EmailCleaner::Audit.run(
      options: { days: 30, actionable: true, min: 3, include_done: false },
      gmail_service: svc,
      state: make_state,
      io: out,
      progress: StringIO.new
    )

    assert_match(/a@x\.com/, out.string)
    refute_match(/b@x\.com/, out.string)
    refute_match(/c@x\.com/, out.string)
    assert_match(/email_cleaner triage/, out.string)
  end

  def test_actionable_excludes_done_unless_include_done
    state = make_state
    state.record("a@x.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x/u")

    msgs = {
      "1" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "2" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" }),
      "3" => msg(headers: { "From" => "a@x.com", "List-Unsubscribe" => "<https://x/u>" })
    }
    svc = FakeService.new(messages_by_id: msgs)

    out_excluded = StringIO.new
    EmailCleaner::Audit.run(
      options: { days: 30, actionable: true, min: 3, include_done: false },
      gmail_service: svc, state: state, io: out_excluded, progress: StringIO.new
    )
    refute_match(/a@x\.com/, out_excluded.string)

    out_included = StringIO.new
    EmailCleaner::Audit.run(
      options: { days: 30, actionable: true, min: 3, include_done: true },
      gmail_service: svc, state: state, io: out_included, progress: StringIO.new
    )
    assert_match(/a@x\.com/, out_included.string)
  end
end
