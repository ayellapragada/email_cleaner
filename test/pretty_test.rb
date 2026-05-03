# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/pretty"

class PrettyTest < Minitest::Test
  P = EmailCleaner::Pretty

  def test_returns_plain_text_when_disabled
    P.stub(:enabled?, false) do
      assert_equal "ok", P.green("ok")
      assert_equal "fail", P.red("fail")
    end
  end

  def test_wraps_with_codes_when_enabled
    P.stub(:enabled?, true) do
      assert_equal "\e[32mok\e[0m", P.green("ok")
      assert_equal "\e[31mfail\e[0m", P.red("fail")
    end
  end

  def test_style_combines_multiple_codes
    P.stub(:enabled?, true) do
      assert_equal "\e[1m\e[36mhi\e[0m", P.style("hi", :bold, :cyan)
    end
  end

  def test_no_color_env_disables
    original = ENV["NO_COLOR"]
    ENV["NO_COLOR"] = "1"
    refute P.enabled?
  ensure
    ENV["NO_COLOR"] = original
  end
end
