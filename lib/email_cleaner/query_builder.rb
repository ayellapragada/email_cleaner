# frozen_string_literal: true

module EmailCleaner
  # Translates the user's pattern into a Gmail server-side query so the
  # API only returns candidate messages instead of the whole inbox.
  module QueryBuilder
    module_function

    def from_pattern(pattern, days)
      window = "newer_than:#{days}d"
      from = pattern.to_s
      from = from.start_with?("@") ? from[1..] : from
      from.empty? ? window : "from:#{from} #{window}"
    end
  end
end
