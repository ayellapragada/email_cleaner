# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "date"
require "email_cleaner/state"

class StateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "unsubscribed.yaml")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_missing_file_loads_empty
    state = EmailCleaner::State.new(path: @path)
    assert_nil state.lookup("a@b.com")
    refute state.already_unsubscribed?("a@b.com")
  end

  def test_record_then_lookup
    state = EmailCleaner::State.new(path: @path)
    state.record(
      "a@b.com",
      method: :one_click, status: 200, confirmed: true,
      last_url: "https://x.com/u"
    )
    state.save

    reloaded = EmailCleaner::State.new(path: @path)
    entry = reloaded.lookup("a@b.com")
    assert_equal "one_click", entry["method"]
    assert_equal 200, entry["status"]
    assert_equal true, entry["confirmed"]
    assert reloaded.already_unsubscribed?("a@b.com")
  end

  def test_already_unsubscribed_only_when_confirmed
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :https_only, status: "manual", confirmed: false, last_url: "https://x")
    refute state.already_unsubscribed?("a@b.com")
  end

  def test_record_overwrites_prior_entry
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :error, status: 500, confirmed: false, last_url: "https://x")
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x")
    assert state.already_unsubscribed?("a@b.com")
    assert_equal "one_click", state.lookup("a@b.com")["method"]
  end

  def test_file_written_with_0600
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x")
    state.save
    mode = File.stat(@path).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_each_yields_address_and_entry
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "https://x")
    state.record("c@d.com", method: :mailto, status: "sent", confirmed: true, last_url: "mailto:x")
    seen = {}
    state.each { |addr, entry| seen[addr] = entry["method"] }
    assert_equal({ "a@b.com" => "one_click", "c@d.com" => "mailto" }, seen)
  end

  def test_keep_records_until_date_and_kept_active
    state = EmailCleaner::State.new(path: @path)
    state.keep("a@b.com", until_date: Date.today + 30)
    state.save

    reloaded = EmailCleaner::State.new(path: @path)
    entry = reloaded.lookup("a@b.com")
    assert_equal "keep", entry["method"]
    assert_equal (Date.today + 30).to_s, entry["kept_until"]
    assert reloaded.kept_active?("a@b.com")
  end

  def test_kept_active_false_when_date_passed
    state = EmailCleaner::State.new(path: @path)
    state.keep("a@b.com", until_date: Date.today - 1)
    refute state.kept_active?("a@b.com")
  end

  def test_keep_overwrites_prior_unsub_state
    state = EmailCleaner::State.new(path: @path)
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "x")
    state.keep("a@b.com", until_date: Date.today + 30)
    refute state.already_unsubscribed?("a@b.com")
    assert state.kept_active?("a@b.com")
  end

  def test_record_overwrites_prior_keep_state
    state = EmailCleaner::State.new(path: @path)
    state.keep("a@b.com", until_date: Date.today + 30)
    state.record("a@b.com", method: :one_click, status: 200, confirmed: true, last_url: "x")
    refute state.kept_active?("a@b.com")
    assert state.already_unsubscribed?("a@b.com")
  end

  def test_annotate_marks_kept_for_active_keeps_and_none_for_expired
    state = EmailCleaner::State.new(path: @path)
    state.keep("active@x.com", until_date: Date.today + 30)
    state.keep("expired@x.com", until_date: Date.today - 1)
    state.record("done@x.com", method: :one_click, status: 200, confirmed: true, last_url: "x")

    require "email_cleaner/sender"
    require "email_cleaner/sender_stats"
    stats = %w[active@x.com expired@x.com done@x.com unknown@x.com].map do |a|
      EmailCleaner::SenderStats.new(
        sender: EmailCleaner::Sender.new(address: a, name: nil),
        count: 5, unsub_info: nil, last_seen: nil
      )
    end

    state.annotate(stats)
    by_addr = stats.to_h { |s| [s.sender.address, s.state_status] }
    assert_equal :kept,      by_addr["active@x.com"]
    assert_equal :none,      by_addr["expired@x.com"]
    assert_equal :confirmed, by_addr["done@x.com"]
    assert_equal :none,      by_addr["unknown@x.com"]
  end
end
