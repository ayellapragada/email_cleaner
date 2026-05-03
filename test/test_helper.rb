# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "minitest/pride"
require "webmock/minitest"
require "vcr"

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path("fixtures/vcr", __dir__)
  c.hook_into :webmock
  c.default_cassette_options = {
    record: ENV["VCR_RECORD"] ? ENV["VCR_RECORD"].to_sym : :none
  }
  c.filter_sensitive_data("<OAUTH_TOKEN>") do |i|
    i.request.headers["Authorization"]&.first
  end
  c.filter_sensitive_data("<USER_EMAIL>") { ENV["USER_EMAIL_FOR_TESTS"] }
end

WebMock.disable_net_connect!(allow_localhost: false)

require "email_cleaner"
require_relative "support/fake_gmail_service"
