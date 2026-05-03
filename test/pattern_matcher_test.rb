# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/pattern_matcher"
require "email_cleaner/sender"
require "email_cleaner/sender_stats"

class PatternMatcherTest < Minitest::Test
  PM = EmailCleaner::PatternMatcher

  def stats(addr)
    EmailCleaner::SenderStats.new(
      sender: EmailCleaner::Sender.new(address: addr, name: nil),
      count: 5, unsub_info: nil, last_seen: nil
    )
  end

  def test_substring_case_insensitive
    pool = [stats("news@SUBSTACK.com"), stats("a@b.com")]
    matched = PM.filter(pool, "substack")
    assert_equal 1, matched.size
    assert_equal "news@substack.com", matched.first.sender.address
  end

  def test_at_domain_exact_match
    # Mixed case in both pattern and addresses verifies case-insensitive
    # match alongside the no-subdomains rule in one pass.
    pool = [stats("a@SUBSTACK.com"), stats("b@news.substack.com"), stats("c@xsubstack.com")]
    matched = PM.filter(pool, "@Substack.COM")
    assert_equal ["a@substack.com"], matched.map { |s| s.sender.address }
  end

  def test_no_match_returns_empty
    assert_empty PM.filter([stats("a@b.com")], "zzz")
  end
end
