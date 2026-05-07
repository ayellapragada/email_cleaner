# test/auto_read_state_test.rb
# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "email_cleaner/auto_read_state"

class AutoReadStateTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, "auto_read.yaml")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_empty_file_initializes_blank
    s = EmailCleaner::AutoReadState.new(path: @path)
    assert_equal [], s.addresses
    assert_equal [], s.domains
    assert_nil s.filter_id
  end

  def test_add_address_dedupes_and_lowercases
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("Foo@Bar.com")
    s.add("foo@bar.com")
    assert_equal ["foo@bar.com"], s.addresses
    assert_equal [], s.domains
  end

  def test_add_at_prefixed_string_becomes_domain
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("@Chase.com")
    assert_equal [], s.addresses
    assert_equal ["chase.com"], s.domains
  end

  def test_add_domain_only_becomes_domain
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add_domain("Stripe.com")
    assert_equal ["stripe.com"], s.domains
  end

  def test_remove_strips_address_or_domain
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("a@x.com")
    s.add_domain("y.com")
    s.remove("a@x.com")
    s.remove("@y.com")
    assert_equal [], s.addresses
    assert_equal [], s.domains
  end

  def test_save_and_reload_roundtrip
    s = EmailCleaner::AutoReadState.new(path: @path)
    s.add("a@x.com")
    s.add_domain("y.com")
    s.filter_id = "FID123"
    s.save

    s2 = EmailCleaner::AutoReadState.new(path: @path)
    assert_equal ["a@x.com"], s2.addresses
    assert_equal ["y.com"], s2.domains
    assert_equal "FID123", s2.filter_id
  end

  def test_empty_returns_true_when_no_addresses_or_domains
    s = EmailCleaner::AutoReadState.new(path: @path)
    assert s.empty?
    s.add("a@x.com")
    refute s.empty?
  end
end
