# frozen_string_literal: true

require "time"

module EmailCleaner
  # Tab-separated append-only log used by all command modules. Each
  # entry is `<iso8601 utc>\t<command>\t<step>\t<fields...>`.
  #
  #   LogWriter.open(path, command: "triage") do |log|
  #     log.write("unsub", "a@x.com", "one_click", "200", "ok")
  #     log.write("trash", "a@x.com", 47, "ok")
  #   end
  class LogWriter
    def self.open(path, command:, &block)
      File.open(path, "a") do |io|
        block.call(new(io: io, command: command))
      end
    end

    def initialize(io:, command:)
      @io = io
      @command = command
    end

    def write(*fields)
      @io.puts([Time.now.utc.iso8601, @command, *fields].join("\t"))
      @io.flush
    end
  end
end
