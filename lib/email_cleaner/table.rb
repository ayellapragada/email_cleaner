# frozen_string_literal: true

module EmailCleaner
  module Table
    HEADERS = %w[COUNT UNSUB 1-CLICK DONE DOMAIN NAME ADDRESS].freeze

    module_function

    def print(stats, io: $stdout)
      rows = stats.map { |s| row_for(s) }
      widths = column_widths(rows)
      io.puts format_row(HEADERS, widths)
      io.puts format_row(widths.map { |w| "-" * w }, widths)
      rows.each { |r| io.puts format_row(r, widths) }
    end

    def row_for(s)
      [
        s.count.to_s,
        s.unsub_info ? "✓" : "",
        (s.unsub_info && s.unsub_info.one_click?) ? "✓" : "",
        done_marker(s),
        s.sender.domain,
        (s.sender.name || ""),
        s.sender.address
      ]
    end

    def done_marker(s)
      case s.state_status
      when :confirmed   then "✓"
      when :kept        then s.kept_until ? "• until #{s.kept_until}" : "•"
      when :unconfirmed then "~"
      else ""
      end
    end

    def column_widths(rows)
      HEADERS.each_with_index.map do |h, i|
        ([h.length] + rows.map { |r| r[i].to_s.length }).max
      end
    end

    def format_row(cells, widths)
      cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ")
    end
  end
end
