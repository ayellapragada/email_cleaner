# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/headers"

class HeadersFromTest < Minitest::Test
  H = EmailCleaner::Headers

  def test_name_and_angle_address
    name, addr = H.parse_from("Joe Smith <joe@example.com>")
    assert_equal "Joe Smith", name
    assert_equal "joe@example.com", addr
  end

  def test_quoted_name_with_comma
    name, addr = H.parse_from('"Smith, Joe" <joe@example.com>')
    assert_equal "Smith, Joe", name
    assert_equal "joe@example.com", addr
  end

  def test_bare_address
    name, addr = H.parse_from("joe@example.com")
    assert_nil name
    assert_equal "joe@example.com", addr
  end

  def test_address_lowercased
    _, addr = H.parse_from("Joe <Joe@Example.COM>")
    assert_equal "joe@example.com", addr
  end

  def test_malformed_returns_input_as_address_no_name
    name, addr = H.parse_from("not really an email")
    assert_nil name
    assert_equal "not really an email", addr
  end

  def test_extra_whitespace_trimmed
    name, addr = H.parse_from("  Joe   <joe@example.com>  ")
    assert_equal "Joe", name
    assert_equal "joe@example.com", addr
  end
end

class HeadersListUnsubscribeTest < Minitest::Test
  H = EmailCleaner::Headers

  def test_single_https
    urls = H.parse_list_unsubscribe("<https://example.com/u?id=1>")
    assert_equal [{ scheme: :https, value: "https://example.com/u?id=1" }], urls
  end

  def test_single_mailto
    urls = H.parse_list_unsubscribe("<mailto:unsub@example.com?subject=bye>")
    assert_equal [{ scheme: :mailto, value: "mailto:unsub@example.com?subject=bye" }], urls
  end

  def test_both_comma_separated
    urls = H.parse_list_unsubscribe("<mailto:u@x.com>, <https://x.com/u>")
    assert_equal 2, urls.size
    assert_equal :mailto, urls[0][:scheme]
    assert_equal :https,  urls[1][:scheme]
  end

  def test_comma_inside_url_not_a_separator
    urls = H.parse_list_unsubscribe("<https://x.com/u?a=1,2>, <mailto:u@x.com>")
    assert_equal 2, urls.size
    assert_equal "https://x.com/u?a=1,2", urls[0][:value]
  end

  def test_extra_whitespace
    urls = H.parse_list_unsubscribe("  <https://x.com/u>  ,  <mailto:u@x.com>  ")
    assert_equal 2, urls.size
  end

  def test_malformed_entries_dropped
    urls = H.parse_list_unsubscribe("garbage, <https://ok.com/u>, also-bad")
    assert_equal 1, urls.size
    assert_equal "https://ok.com/u", urls[0][:value]
  end

  def test_nil_returns_empty
    assert_equal [], H.parse_list_unsubscribe(nil)
  end
end

class HeadersOneClickTest < Minitest::Test
  H = EmailCleaner::Headers

  def test_one_click_with_https
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    assert H.one_click?("List-Unsubscribe=One-Click", urls)
  end

  def test_one_click_case_and_whitespace_tolerant
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    assert H.one_click?("  list-unsubscribe = one-click  ", urls)
  end

  def test_no_post_header
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    refute H.one_click?(nil, urls)
  end

  def test_post_header_but_no_https
    urls = [{ scheme: :mailto, value: "mailto:u@x.com" }]
    refute H.one_click?("List-Unsubscribe=One-Click", urls)
  end

  def test_unrelated_post_value
    urls = [{ scheme: :https, value: "https://x.com/u" }]
    refute H.one_click?("Something-Else=Foo", urls)
  end
end
