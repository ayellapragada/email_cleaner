# frozen_string_literal: true

module EmailCleaner
  # Confirmation prompt shared by destructive subcommands. Honors --yes
  # (skip prompt entirely) and treats anything other than y/yes as a no.
  module Prompt
    module_function

    def confirm?(question, io:, stdin:, assume_yes: false)
      return true if assume_yes

      io.print "#{question} [y/N] "
      answer = stdin.gets&.strip&.downcase
      %w[y yes].include?(answer)
    end
  end
end
