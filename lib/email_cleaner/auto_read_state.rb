# lib/email_cleaner/auto_read_state.rb
# frozen_string_literal: true

require "yaml"
require "fileutils"

module EmailCleaner
  # Local source of truth for the managed auto-read Gmail filter.
  # Addresses are full email addresses; domains are bare hostnames
  # (no leading @). Both are stored lowercased and deduped.
  class AutoReadState
    attr_accessor :filter_id

    def initialize(path:)
      @path = path
      data = load_or_init
      @addresses = data["addresses"] || []
      @domains   = data["domains"]   || []
      @filter_id = data["filter_id"]
    end

    def addresses = @addresses.dup
    def domains   = @domains.dup
    def empty?    = @addresses.empty? && @domains.empty?

    # Accepts "a@x.com" (address), "@x.com" (domain), and routes accordingly.
    def add(entry)
      e = entry.to_s.strip.downcase
      if e.start_with?("@")
        add_domain(e[1..])
      else
        @addresses << e unless @addresses.include?(e)
      end
    end

    def add_domain(domain)
      d = domain.to_s.strip.downcase.sub(/\A@/, "")
      @domains << d unless @domains.include?(d)
    end

    def remove(entry)
      e = entry.to_s.strip.downcase
      if e.start_with?("@")
        @domains.delete(e[1..])
      else
        @addresses.delete(e)
      end
    end

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump(
          "filter_id" => @filter_id,
          "addresses" => @addresses,
          "domains"   => @domains
        ))
      end
    end

    private

    def load_or_init
      return {} unless File.exist?(@path)

      YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false) || {}
    end
  end
end
