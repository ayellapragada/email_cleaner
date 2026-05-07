# test/gmail_filter_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "email_cleaner/gmail_filter"

class GmailFilterTest < Minitest::Test
  def test_build_query_addresses_only
    q = EmailCleaner::GmailFilter.build_query(addresses: ["a@x.com", "b@y.com"], domains: [])
    assert_equal "from:(a@x.com OR b@y.com)", q
  end

  def test_build_query_domains_only
    q = EmailCleaner::GmailFilter.build_query(addresses: [], domains: ["x.com", "y.com"])
    assert_equal "from:(@x.com OR @y.com)", q
  end

  def test_build_query_mixed
    q = EmailCleaner::GmailFilter.build_query(addresses: ["a@x.com"], domains: ["y.com"])
    assert_equal "from:(a@x.com OR @y.com)", q
  end

  def test_build_query_empty_raises
    assert_raises(EmailCleaner::GmailFilter::EmptyError) do
      EmailCleaner::GmailFilter.build_query(addresses: [], domains: [])
    end
  end

  def test_build_query_too_long_raises
    many = (1..400).map { |i| "user#{i}@somelongdomain.example.com" }
    err = assert_raises(EmailCleaner::GmailFilter::TooLongError) do
      EmailCleaner::GmailFilter.build_query(addresses: many, domains: [])
    end
    assert_match(/exceeds/i, err.message)
  end

  def test_create_calls_filters_create
    svc = Minitest::Mock.new
    expected = Google::Apis::GmailV1::Filter.new(
      criteria: Google::Apis::GmailV1::FilterCriteria.new(query: "from:(a@x.com)"),
      action:   Google::Apis::GmailV1::FilterAction.new(remove_label_ids: ["UNREAD"])
    )
    returned = Google::Apis::GmailV1::Filter.new(id: "FID1")
    svc.expect(:create_user_setting_filter, returned) do |user, filter|
      user == "me" &&
        filter.criteria.query == expected.criteria.query &&
        filter.action.remove_label_ids == ["UNREAD"]
    end

    gf = EmailCleaner::GmailFilter.new(service: svc)
    id = gf.create(query: "from:(a@x.com)")
    assert_equal "FID1", id
    svc.verify
  end

  def test_delete_calls_filters_delete
    svc = Minitest::Mock.new
    svc.expect(:delete_user_setting_filter, nil, ["me", "FID1"])
    gf = EmailCleaner::GmailFilter.new(service: svc)
    gf.delete(id: "FID1")
    svc.verify
  end

  def test_delete_swallows_404
    svc = Object.new
    def svc.delete_user_setting_filter(_user, _id)
      raise Google::Apis::ClientError.new("not found", status_code: 404)
    end
    gf = EmailCleaner::GmailFilter.new(service: svc)
    assert_equal :not_found, gf.delete(id: "FID1")
  end
end
