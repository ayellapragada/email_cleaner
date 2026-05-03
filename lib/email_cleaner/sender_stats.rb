# frozen_string_literal: true

module EmailCleaner
  class SenderStats
    attr_reader :sender, :count, :unsub_info, :last_seen, :recent_subjects, :message_ids
    attr_accessor :state_status, # :none | :confirmed | :unconfirmed | :kept
                  :kept_until    # Date or nil; populated by State#annotate when kept

    def initialize(sender:, count:, unsub_info:, last_seen:, recent_subjects: [], message_ids: [])
      @sender = sender
      @count = count
      @unsub_info = unsub_info
      @last_seen = last_seen
      @recent_subjects = recent_subjects
      @message_ids = message_ids
      @state_status = :none
    end

    def already_unsubscribed?
      @state_status == :confirmed
    end

    def kept?
      @state_status == :kept
    end
  end
end
