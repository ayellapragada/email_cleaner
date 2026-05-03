# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "stringio"
require "email_cleaner/table"
require "email_cleaner/sender"
require "email_cleaner/sender_stats"
require "email_cleaner/unsub_info"

class TableTest < Minitest::Test
  def stats(addr:, count:, name: nil, has_unsub: false, one_click: false, state_status: :none)
    info =
      if has_unsub
        EmailCleaner::UnsubInfo.new(
          urls: [{ scheme: :https, value: "https://x.com/u" }],
          one_click: one_click
        )
      end

    s = EmailCleaner::SenderStats.new(
      sender: EmailCleaner::Sender.new(address: addr, name: name),
      count: count, unsub_info: info, last_seen: Date.new(2026, 5, 1)
    )
    s.state_status = state_status
    s
  end

  def test_renders_columns_and_marks
    rows = [
      stats(addr: "a@b.com", count: 10, name: "A", has_unsub: true,  one_click: true,  state_status: :confirmed),
      stats(addr: "c@d.com", count: 3,  name: nil, has_unsub: true,  one_click: false, state_status: :unconfirmed),
      stats(addr: "e@f.com", count: 2,  name: "E", has_unsub: false, one_click: false, state_status: :none)
    ]
    out = StringIO.new
    EmailCleaner::Table.print(rows, io: out)
    s = out.string

    assert_match(/COUNT/, s)
    assert_match(/a@b\.com/, s)
    assert_match(/c@d\.com/, s)
    assert_match(/e@f\.com/, s)
    # one-click row has both ✓ for UNSUB and 1-CLICK
    assert_match(/10\s+✓\s+✓\s+✓/, s) # COUNT UNSUB 1-CLICK DONE
    # unconfirmed gets ~ in DONE
    assert_match(/c@d\.com/, s)
    assert_includes s, "~"
  end

  def test_kept_row_shows_until_date
    s = stats(addr: "k@x.com", count: 5, has_unsub: true, one_click: true, state_status: :kept)
    s.kept_until = Date.new(2026, 8, 1)
    out = StringIO.new
    EmailCleaner::Table.print([s], io: out)
    assert_match(/• until 2026-08-01/, out.string)
  end

  def test_kept_row_falls_back_to_bullet_when_no_until_date
    s = stats(addr: "k@x.com", count: 5, has_unsub: true, one_click: true, state_status: :kept)
    out = StringIO.new
    EmailCleaner::Table.print([s], io: out)
    # Just the bullet, no "until" suffix
    assert_match(/•(?! until)/, out.string)
  end
end
