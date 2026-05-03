# frozen_string_literal: true

module EmailCleaner
  # Minimal ANSI styling, auto-disabled when stdout isn't a TTY (so the
  # output stays clean when piped to `less`, redirected to a file, or
  # captured in tests). Set NO_COLOR=1 to force-disable.
  module Pretty
    CODES = {
      reset:  "\e[0m",
      bold:   "\e[1m",
      dim:    "\e[2m",
      red:    "\e[31m",
      green:  "\e[32m",
      yellow: "\e[33m",
      cyan:   "\e[36m"
    }.freeze

    module_function

    def enabled?
      return false if ENV["NO_COLOR"] && !ENV["NO_COLOR"].empty?

      $stdout.tty?
    end

    def style(text, *names)
      return text.to_s unless enabled?

      prefix = names.map { |n| CODES.fetch(n) }.join
      "#{prefix}#{text}#{CODES[:reset]}"
    end

    def green(t)  = style(t, :green)
    def red(t)    = style(t, :red)
    def yellow(t) = style(t, :yellow)
    def dim(t)    = style(t, :dim)
    def bold(t)   = style(t, :bold)
    def cyan(t)   = style(t, :cyan)
  end
end
