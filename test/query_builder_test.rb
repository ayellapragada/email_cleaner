# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/query_builder"

class QueryBuilderTest < Minitest::Test
  QB = EmailCleaner::QueryBuilder

  def test_at_domain_pattern_becomes_from_query
    assert_equal "from:secretflying.com newer_than:30d", QB.from_pattern("@secretflying.com", 30)
  end

  def test_substring_pattern_becomes_from_query
    assert_equal "from:substack newer_than:7d", QB.from_pattern("substack", 7)
  end

  def test_empty_pattern_falls_back_to_window_only
    assert_equal "newer_than:30d", QB.from_pattern("", 30)
  end
end
