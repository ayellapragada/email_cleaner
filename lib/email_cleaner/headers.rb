# frozen_string_literal: true

module EmailCleaner
  module Headers
    module_function

    # Returns [name_or_nil, address_lowercased_string].
    # Never raises. Malformed input returns [nil, original_string].
    def parse_from(value)
      return [nil, ""] if value.nil?

      v = value.strip

      # "Quoted Name" <addr> or Name <addr>
      if (m = v.match(/\A\s*"?(.*?)"?\s*<\s*([^<>\s]+)\s*>\s*\z/)) && m[2].include?("@")
        name = m[1].strip
        name = nil if name.empty?
        return [name, m[2].downcase]
      end

      # Bare email
      if v.include?("@") && !v.include?(" ")
        return [nil, v.downcase]
      end

      [nil, v]
    end

    # Splits a List-Unsubscribe header value into [{scheme:, value:}, ...].
    # Splits on commas OUTSIDE angle brackets so commas inside URLs don't break.
    # Drops malformed entries; never raises.
    def parse_list_unsubscribe(value)
      return [] if value.nil? || value.strip.empty?

      entries = []
      buf = +""
      depth = 0
      value.each_char do |ch|
        case ch
        when "<" then depth += 1; buf << ch
        when ">" then depth -= 1; buf << ch
        when ","
          if depth.zero?
            entries << buf
            buf = +""
          else
            buf << ch
          end
        else
          buf << ch
        end
      end
      entries << buf

      entries.filter_map do |raw|
        m = raw.strip.match(/\A<\s*(.+?)\s*>\z/)
        next nil unless m

        url = m[1]
        scheme =
          if url.start_with?("https://") then :https
          elsif url.start_with?("http://") then :https
          elsif url.start_with?("mailto:") then :mailto
          end
        scheme ? { scheme: scheme, value: url } : nil
      end
    end

    # RFC 8058 one-click requires:
    #   - List-Unsubscribe-Post header equal to "List-Unsubscribe=One-Click"
    #   - at least one https URL in List-Unsubscribe
    def one_click?(post_header_value, parsed_urls)
      return false if post_header_value.nil?

      normalized = post_header_value.gsub(/\s+/, "").downcase
      return false unless normalized == "list-unsubscribe=one-click"

      parsed_urls.any? { |u| u[:scheme] == :https }
    end
  end
end
