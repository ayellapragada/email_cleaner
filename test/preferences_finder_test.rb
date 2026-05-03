# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/preferences_finder"

class PreferencesFinderTest < Minitest::Test
  PF = EmailCleaner::PreferencesFinder

  def test_returns_nil_for_empty_or_nil_body
    assert_nil PF.find(nil)
    assert_nil PF.find("")
  end

  def test_returns_nil_when_no_anchors
    assert_nil PF.find("<html><body>Just text, no links.</body></html>")
  end

  def test_returns_nil_when_no_preferences_keyword
    body = '<a href="https://x.com/u">Unsubscribe</a><a href="https://x.com">Visit our site</a>'
    assert_nil PF.find(body)
  end

  def test_finds_manage_preferences_link
    body = <<~HTML
      <p>Don't want these? <a href="https://nytimes.com/prefs">Manage your email preferences</a></p>
      <p>Or <a href="https://nytimes.com/unsub">unsubscribe</a>.</p>
    HTML
    assert_equal "https://nytimes.com/prefs", PF.find(body)
  end

  def test_finds_email_settings_link
    body = '<a href="https://x.com/settings">Email settings</a>'
    assert_equal "https://x.com/settings", PF.find(body)
  end

  def test_prefers_more_specific_match_when_multiple_present
    # "manage your email preferences" should beat "subscription preferences"
    body = <<~HTML
      <a href="https://x.com/sub">subscription preferences</a>
      <a href="https://x.com/mgr">Manage your email preferences</a>
    HTML
    assert_equal "https://x.com/mgr", PF.find(body)
  end

  def test_handles_single_quotes_in_attributes
    body = "<a href='https://x.com/p'>email preferences</a>"
    assert_equal "https://x.com/p", PF.find(body)
  end

  def test_handles_html_entities_in_href
    body = '<a href="https://x.com/p?a=1&amp;b=2">manage preferences</a>'
    assert_equal "https://x.com/p?a=1&b=2", PF.find(body)
  end

  def test_handles_anchor_with_inner_html_tags
    body = '<a href="https://x.com/p"><span style="color:#888">manage preferences</span></a>'
    assert_equal "https://x.com/p", PF.find(body)
  end

  def test_case_insensitive_keyword_match
    body = '<a href="https://x.com/p">MANAGE EMAIL PREFERENCES</a>'
    assert_equal "https://x.com/p", PF.find(body)
  end

  def test_ignores_anchors_with_no_visible_text
    body = '<a href="https://x.com/p"></a><a href="https://x.com/q">Email Settings</a>'
    assert_equal "https://x.com/q", PF.find(body)
  end
end
