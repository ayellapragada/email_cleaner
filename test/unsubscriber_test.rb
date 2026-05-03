# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/unsubscriber"
require "email_cleaner/sender"
require "email_cleaner/sender_stats"
require "email_cleaner/unsub_info"

class UnsubscriberTest < Minitest::Test
  def stats(urls:, one_click:)
    EmailCleaner::SenderStats.new(
      sender: EmailCleaner::Sender.new(address: "a@b.com", name: "Alice"),
      count: 5,
      unsub_info: EmailCleaner::UnsubInfo.new(urls: urls, one_click: one_click),
      last_seen: nil
    )
  end

  def test_one_click_post_2xx_is_confirmed
    stub_request(:post, "https://x.com/u")
      .with(body: "List-Unsubscribe=One-Click",
            headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      .to_return(status: 200, body: "")

    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    u = EmailCleaner::Unsubscriber.new(gmail_service: nil)
    result = u.run(s)

    assert_equal :one_click, result[:method]
    assert_equal 200, result[:status]
    assert_equal true, result[:confirmed]
  end

  def test_one_click_post_3xx_is_confirmed
    stub_request(:post, "https://x.com/u").to_return(status: 302, headers: { "Location" => "https://x.com/done" })
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :one_click, result[:method]
    assert_equal 302, result[:status]
    assert_equal true, result[:confirmed]
  end

  def test_one_click_post_5xx_is_error
    stub_request(:post, "https://x.com/u").to_return(status: 503)
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :one_click, result[:method]
    assert_equal 503, result[:status]
    assert_equal false, result[:confirmed]
  end

  def test_one_click_timeout_is_error
    stub_request(:post, "https://x.com/u").to_timeout
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: true)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :error, result[:method]
    assert_equal false, result[:confirmed]
  end

  def test_https_only_makes_no_http_call
    s = stats(urls: [{ scheme: :https, value: "https://x.com/u" }], one_click: false)
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)

    assert_equal :https_only, result[:method]
    assert_equal "https://x.com/u", result[:url]
    assert_equal false, result[:confirmed]
    refute_requested :post, "https://x.com/u"
  end

  def test_mailto_sends_via_gmail
    fake_gmail = Minitest::Mock.new
    fake_gmail.expect(:send_user_message, nil) do |user_id, message|
      raw = message.raw
      user_id == "me" &&
        raw.include?("To: unsub@x.com") &&
        raw.include?("Subject: bye") &&
        raw.include?("\r\n\r\n") # headers/body separator present
    end

    s = stats(urls: [{ scheme: :mailto, value: "mailto:unsub@x.com?subject=bye&body=stop" }], one_click: false)
    result = EmailCleaner::Unsubscriber.new(gmail_service: fake_gmail).run(s)

    assert_equal :mailto, result[:method]
    assert_equal "sent", result[:status]
    assert_equal true, result[:confirmed]
    fake_gmail.verify
  end

  def test_prefers_https_when_both_present
    stub_request(:post, "https://x.com/u").to_return(status: 200)
    s = stats(
      urls: [
        { scheme: :mailto, value: "mailto:u@x.com" },
        { scheme: :https,  value: "https://x.com/u" }
      ],
      one_click: true
    )
    result = EmailCleaner::Unsubscriber.new(gmail_service: nil).run(s)
    assert_equal :one_click, result[:method]
  end
end
