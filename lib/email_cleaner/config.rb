# frozen_string_literal: true

module EmailCleaner
  class Config
    DEFAULT_ROOT = File.expand_path("../..", __dir__)

    attr_reader :root

    def initialize(root: DEFAULT_ROOT)
      @root = root
    end

    def credentials_path = File.join(@root, "credentials.json")
    def token_path       = File.join(@root, "token.yaml")
    def state_path       = File.join(@root, "unsubscribed.yaml")
    def log_path         = File.join(@root, "unsubscribe.log")
    def trash_log_path   = File.join(@root, "trash.log")
    def triage_log_path  = File.join(@root, "triage.log")
    def auto_read_path        = File.join(@root, "auto_read.yaml")
  end
end
