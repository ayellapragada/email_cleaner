# frozen_string_literal: true

module EmailCleaner
  module PatternMatcher
    module_function

    # Filters an array of SenderStats by pattern.
    # - "@domain.com" → exact-domain match (no subdomains).
    # - anything else → case-insensitive substring on address.
    def filter(stats, pattern)
      p = pattern.to_s.downcase
      if p.start_with?("@")
        domain = p[1..]
        stats.select { |s| s.sender.domain == domain }
      else
        stats.select { |s| s.sender.address.include?(p) }
      end
    end
  end
end
