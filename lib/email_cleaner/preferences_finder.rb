# frozen_string_literal: true

require "cgi"

module EmailCleaner
  # Best-effort scan of an email body for a "manage subscription
  # preferences" page URL — the page where you can opt out of multiple
  # streams from one sender, not just the single List-Unsubscribe link.
  #
  # Returns the most likely preferences URL or nil. Hand-rolled regex
  # rather than a full HTML parser; we just need to find anchor tags
  # whose visible text or surrounding context contains preferences-y
  # words. Good enough for the major newsletter platforms.
  module PreferencesFinder
    module_function

    # Phrases that strongly suggest a preferences page (vs. a one-shot
    # unsubscribe link). Ordered roughly by specificity — earlier
    # matches preferred.
    KEYWORDS = [
      /manage\s+(your\s+)?(email\s+|subscription\s+|notification\s+)?preferences/i,
      /update\s+(your\s+)?(email\s+|subscription\s+|notification\s+)?preferences/i,
      /email\s+preferences/i,
      /notification\s+preferences/i,
      /subscription\s+preferences/i,
      /manage\s+(your\s+)?subscriptions?/i,
      /change\s+(your\s+)?preferences/i,
      /email\s+settings/i,
      /notification\s+settings/i
    ].freeze

    # Anchor with optional leading whitespace; capture href and inner text.
    # Tolerant of single/double quotes and stray attributes between.
    ANCHOR_RE = /<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/im

    def find(body)
      return nil if body.nil? || body.empty?

      anchors = body.scan(ANCHOR_RE)
      return nil if anchors.empty?

      # Score each anchor by which keyword matches its visible text
      # (lower index = better match). Return the URL of the best.
      best = nil
      best_score = nil

      anchors.each do |href, inner|
        text = strip_tags(inner)
        next if text.empty?

        KEYWORDS.each_with_index do |re, i|
          if text.match?(re)
            if best_score.nil? || i < best_score
              best = unescape(href)
              best_score = i
            end
            break
          end
        end
      end

      best
    end

    def strip_tags(html)
      html.gsub(/<[^>]+>/, "").gsub(/\s+/, " ").strip
    end

    def unescape(href)
      CGI.unescapeHTML(href.strip)
    end
  end
end
