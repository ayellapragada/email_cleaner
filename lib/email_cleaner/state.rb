# frozen_string_literal: true

require "yaml"
require "fileutils"
require "time"
require "date"

module EmailCleaner
  class State
    SCHEMA_VERSION = 1

    def initialize(path:)
      @path = path
      @data = load_or_init
    end

    def lookup(address)
      @data["entries"][address.to_s.downcase]
    end

    def already_unsubscribed?(address)
      entry = lookup(address)
      !!(entry && entry["confirmed"])
    end

    def record(address, method:, status:, confirmed:, last_url:)
      @data["entries"][address.to_s.downcase] = {
        "method"       => method.to_s,
        "status"       => status,
        "attempted_at" => Time.now.utc.iso8601,
        "confirmed"    => !!confirmed,
        "last_url"     => last_url
      }
    end

    # Mark a sender as "kept" — opt out of audit's actionable view until
    # the kept_until date has passed. Overwrites any prior keep entry but
    # also stomps unsub state, which is the right call: the user just
    # explicitly chose to keep this sender.
    def keep(address, until_date:)
      @data["entries"][address.to_s.downcase] = {
        "method"       => "keep",
        "status"       => "kept",
        "attempted_at" => Time.now.utc.iso8601,
        "confirmed"    => false,
        "kept_until"   => until_date.to_s
      }
    end

    def kept_active?(address, today: Date.today)
      entry = lookup(address)
      return false unless entry && entry["method"] == "keep" && entry["kept_until"]

      Date.parse(entry["kept_until"]) > today
    end

    def each(&block)
      @data["entries"].each(&block)
    end

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump(@data))
      end
    end

    # Annotate a SenderStats array in place with state_status:
    #   :confirmed   — unsubscribed and confirmed (one-click 2xx/3xx, mailto sent, manual mark-done)
    #   :unconfirmed — unsubscribe attempted but not confirmed (https-only, errors)
    #   :kept        — sender is in a "keep" entry whose kept_until date is still in the future
    #   :none        — nothing recorded, or kept_until has passed (auto-resurfaces)
    def annotate(stats)
      today = Date.today
      stats.each do |s|
        entry = lookup(s.sender.address)
        s.kept_until = nil
        s.state_status =
          if entry.nil? then :none
          elsif entry["method"] == "keep"
            until_date = entry["kept_until"] ? Date.parse(entry["kept_until"]) : nil
            if until_date && until_date > today
              s.kept_until = until_date
              :kept
            else
              :none
            end
          elsif entry["confirmed"] then :confirmed
          else :unconfirmed
          end
      end
      stats
    end

    private

    def load_or_init
      if File.exist?(@path)
        loaded = YAML.safe_load(File.read(@path), permitted_classes: [Time, Date], aliases: false) || {}
        loaded["version"] ||= SCHEMA_VERSION
        loaded["entries"] ||= {}
        loaded
      else
        { "version" => SCHEMA_VERSION, "entries" => {} }
      end
    end
  end
end
