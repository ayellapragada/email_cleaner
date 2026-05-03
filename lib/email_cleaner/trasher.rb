# frozen_string_literal: true

require "google/apis/gmail_v1"

module EmailCleaner
  # Moves Gmail messages to Trash via batchModify, in chunks. Trashed
  # messages are recoverable for 30 days; this is intentionally NOT
  # users.messages.delete (permanent).
  class Trasher
    # Gmail's batchModify accepts up to 1000 IDs per call.
    BATCH_SIZE = 1000

    def initialize(gmail_service:, progress: $stderr)
      @gmail = gmail_service
      @progress = progress
    end

    # Returns { trashed: N, errors: M }. Never raises — per-batch
    # failures warn and continue.
    def trash(ids)
      summary = { trashed: 0, errors: 0 }
      ids.each_slice(BATCH_SIZE) do |chunk|
        request = Google::Apis::GmailV1::BatchModifyMessagesRequest.new(
          ids: chunk,
          add_label_ids: ["TRASH"]
        )
        @gmail.batch_modify_messages("me", request)
        summary[:trashed] += chunk.size
        @progress.write(".")
        @progress.flush if @progress.respond_to?(:flush)
      rescue StandardError => e
        @progress.puts "warn: failed to trash batch of #{chunk.size}: #{e.message}"
        summary[:errors] += chunk.size
      end
      @progress.write("\n") unless ids.empty?
      summary
    end
  end
end
