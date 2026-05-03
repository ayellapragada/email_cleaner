# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "email_cleaner/aggregator"

class AggregatorTest < Minitest::Test
  A = EmailCleaner::Aggregator

  def msg(from:, list_unsub: nil, post: nil, date: Date.new(2026, 5, 1))
    headers = { "From" => from }
    headers["List-Unsubscribe"] = list_unsub if list_unsub
    headers["List-Unsubscribe-Post"] = post if post
    { headers: headers, internal_date: date }
  end

  def test_groups_by_address_case_insensitive
    stats = A.group([
      msg(from: "Joe <joe@x.com>"),
      msg(from: "JOE@X.COM"),
      msg(from: "Other <a@b.com>")
    ])
    by_addr = stats.to_h { |s| [s.sender.address, s] }
    assert_equal 2, by_addr["joe@x.com"].count
    assert_equal 1, by_addr["a@b.com"].count # singletons preserved for Phase B
  end

  def test_drop_singletons_removes_count_one_senders
    stats = A.group([
      msg(from: "a@x.com"),
      msg(from: "b@x.com"),
      msg(from: "b@x.com")
    ])
    filtered = A.drop_singletons(stats)
    addrs = filtered.map { |s| s.sender.address }
    refute_includes addrs, "a@x.com"
    assert_includes addrs, "b@x.com"
  end

  def test_sorts_by_count_descending
    stats = A.group([
      msg(from: "a@x.com"), msg(from: "a@x.com"),
      msg(from: "b@x.com"), msg(from: "b@x.com"), msg(from: "b@x.com")
    ])
    assert_equal "b@x.com", stats[0].sender.address
    assert_equal "a@x.com", stats[1].sender.address
  end

  def test_last_seen_is_max_date
    stats = A.group([
      msg(from: "a@x.com", date: Date.new(2026, 4, 1)),
      msg(from: "a@x.com", date: Date.new(2026, 5, 2)),
      msg(from: "a@x.com", date: Date.new(2026, 4, 15))
    ])
    assert_equal Date.new(2026, 5, 2), stats.first.last_seen
  end

  def test_unsub_info_built_from_first_seen_headers
    stats = A.group([
      msg(from: "a@x.com", list_unsub: "<https://x.com/u>", post: "List-Unsubscribe=One-Click"),
      msg(from: "a@x.com")
    ])
    info = stats.first.unsub_info
    refute_nil info
    assert info.one_click?
    assert_equal 1, info.urls.size
  end

  def test_unsub_info_nil_when_no_headers
    stats = A.group([msg(from: "a@x.com"), msg(from: "a@x.com")])
    assert_nil stats.first.unsub_info
  end

  def test_takes_name_from_first_message_with_a_name
    stats = A.group([
      msg(from: "a@x.com"),
      msg(from: "Alice <a@x.com>")
    ])
    assert_equal "Alice", stats.first.sender.name
  end
end
