# frozen_string_literal: true

require_relative "email_cleaner/version"

module EmailCleaner
  # Tunables shared across multiple commands. Anything that's used in
  # exactly one place lives next to that code.
  DEFAULT_DAYS_WINDOW = 30
  DEFAULT_KEEP_DAYS = 90
  DEFAULT_MIN_COUNT = 3
end
