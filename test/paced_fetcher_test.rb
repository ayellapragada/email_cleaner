# frozen_string_literal: true
require_relative "test_helper"
require "date"
require "email_cleaner/paced_fetcher"

class PacedFetcherTest < Minitest::Test
  def test_build_windows_splits_30_days_into_weekly
    today = Date.new(2026, 5, 6)
    windows = EmailCleaner::PacedFetcher.build_windows(days: 30, today: today)
    assert_equal 5, windows.size  # 7+7+7+7+2
    assert_equal Date.new(2026, 4, 29), windows.first[:from]
    assert_equal today, windows.first[:to]
    assert_equal Date.new(2026, 4, 6), windows.last[:from]
  end

  def test_build_windows_handles_small_days
    today = Date.new(2026, 5, 6)
    windows = EmailCleaner::PacedFetcher.build_windows(days: 5, today: today)
    assert_equal 1, windows.size
    assert_equal Date.new(2026, 5, 1), windows.first[:from]
    assert_equal today, windows.first[:to]
  end
end
