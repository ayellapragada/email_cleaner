# frozen_string_literal: true

require_relative "test_helper"
require "email_cleaner/config"

class ConfigTest < Minitest::Test
  def test_default_root_is_project_root
    config = EmailCleaner::Config.new
    assert_equal File.expand_path("..", __dir__), config.root
  end

  def test_paths_resolve_relative_to_root
    config = EmailCleaner::Config.new(root: "/tmp/ec")
    assert_equal "/tmp/ec/credentials.json", config.credentials_path
    assert_equal "/tmp/ec/token.yaml", config.token_path
    assert_equal "/tmp/ec/unsubscribed.yaml", config.state_path
    assert_equal "/tmp/ec/unsubscribe.log", config.log_path
    assert_equal "/tmp/ec/trash.log", config.trash_log_path
    assert_equal "/tmp/ec/triage.log", config.triage_log_path
  end

  def test_auto_read_path
    c = EmailCleaner::Config.new(root: "/tmp/foo")
    assert_equal "/tmp/foo/auto_read.yaml", c.auto_read_path
  end

end
