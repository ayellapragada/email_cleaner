# lib/email_cleaner/auto_read_command.rb
# frozen_string_literal: true

require_relative "auto_read_state"
require_relative "gmail_filter"
require_relative "pretty"

module EmailCleaner
  # Subcommand: email_cleaner auto-read [list|add|remove|sync|status] ...
  #
  # The local YAML at config.auto_read_path is the source of truth.
  # `sync` reconciles it to a single managed Gmail filter (delete the
  # prior one, create a fresh one with the current query, save id).
  module AutoReadCommand
    module_function

    USAGE = <<~USAGE
      Usage:
        email_cleaner auto-read list
        email_cleaner auto-read add    <addr|@domain>
        email_cleaner auto-read remove <addr|@domain>
        email_cleaner auto-read sync
        email_cleaner auto-read status
    USAGE

    def run(argv:, state_path:, gmail_filter:, io: $stdout)
      verb = argv.shift
      state = AutoReadState.new(path: state_path)

      case verb
      when "list"   then run_list(state, io)
      when "add"    then run_add(state, argv, io)
      when "remove" then run_remove(state, argv, io)
      when "sync"   then run_sync(state, gmail_filter, io)
      when "status" then run_status(state, io)
      else
        io.puts USAGE
        2
      end
    end

    def run_list(state, io)
      state.addresses.each { |a| io.puts a }
      state.domains.each   { |d| io.puts "@#{d}" }
      0
    end

    def run_add(state, argv, io)
      entry = argv.shift
      return missing_arg(io) if entry.nil? || entry.empty?

      state.add(entry)
      state.save
      io.puts "added: #{entry.downcase}"
      io.puts Pretty.dim("run `auto-read sync` to apply to Gmail")
      0
    end

    def run_remove(state, argv, io)
      entry = argv.shift
      return missing_arg(io) if entry.nil? || entry.empty?

      state.remove(entry)
      state.save
      io.puts "removed: #{entry.downcase}"
      io.puts Pretty.dim("run `auto-read sync` to apply to Gmail")
      0
    end

    def run_status(state, io)
      io.puts "#{state.addresses.size} address(es), #{state.domains.size} domain(s)"
      io.puts "filter_id: #{state.filter_id || '(none)'}"
      0
    end

    def run_sync(state, gmail_filter, io)
      if state.empty?
        if state.filter_id
          gmail_filter.delete(id: state.filter_id)
          io.puts "deleted managed filter #{state.filter_id} (list is empty)"
          state.filter_id = nil
          state.save
        else
          io.puts "nothing to sync (list is empty, no managed filter)"
        end
        return 0
      end

      query = GmailFilter.build_query(addresses: state.addresses, domains: state.domains)

      if state.filter_id
        result = gmail_filter.delete(id: state.filter_id)
        io.puts "warning: prior filter #{state.filter_id} already gone server-side" if result == :not_found
      end

      new_id = gmail_filter.create(query: query)
      state.filter_id = new_id
      state.save
      io.puts "synced: filter #{new_id} (#{state.addresses.size} address(es), #{state.domains.size} domain(s))"
      0
    rescue GmailFilter::TooLongError => e
      io.puts "error: #{e.message}"
      io.puts "split the list or remove some entries; multi-filter splitting is not supported."
      1
    end

    def missing_arg(io)
      io.puts "missing <addr|@domain>"
      io.puts USAGE
      2
    end
  end
end
