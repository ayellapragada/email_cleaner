# frozen_string_literal: true

require "rbconfig"

module EmailCleaner
  # Cross-platform "open this URL in the user's default browser" helper.
  # Returns true on success, false otherwise. Never raises.
  module Browser
    module_function

    def open(url)
      cmd =
        case RbConfig::CONFIG["host_os"]
        when /darwin/             then ["open", url]
        when /mswin|mingw|cygwin/ then ["cmd", "/c", "start", url]
        when /linux|bsd/          then ["xdg-open", url]
        end
      return false unless cmd

      pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
      Process.detach(pid)
      true
    rescue StandardError
      false
    end
  end
end
