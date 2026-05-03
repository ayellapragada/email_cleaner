# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_module_loads_and_has_version
    assert defined?(EmailCleaner)
    assert_match(/\A\d+\.\d+\.\d+\z/, EmailCleaner::VERSION)
  end
end
