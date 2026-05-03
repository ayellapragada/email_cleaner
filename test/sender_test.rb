# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/sender"

class SenderTest < Minitest::Test
  S = EmailCleaner::Sender

  def test_attributes
    s = S.new(address: "Joe@Example.COM", name: "Joe")
    assert_equal "joe@example.com", s.address
    assert_equal "Joe", s.name
    assert_equal "example.com", s.domain
  end

  def test_equality_by_address
    a = S.new(address: "x@y.com", name: "A")
    b = S.new(address: "X@Y.COM", name: "B")
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  def test_can_be_used_as_hash_key
    h = {}
    h[S.new(address: "x@y.com", name: "A")] = 1
    h[S.new(address: "X@Y.com", name: "B")] = 2
    assert_equal 1, h.size
    assert_equal 2, h.values.first
  end
end
