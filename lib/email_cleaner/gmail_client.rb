# frozen_string_literal: true

require "date"

module EmailCleaner
  class GmailClient
    METADATA_HEADERS = %w[From List-Unsubscribe List-Unsubscribe-Post Subject Date].freeze

    def initialize(service:, progress: $stderr)
      @service = service
      @progress = progress
    end

    # Lists message IDs matching `query`, paginating through all results.
    def list_message_ids(query:)
      ids = []
      page_token = nil
      loop do
        result = @service.list_user_messages("me", q: query, page_token: page_token, max_results: 500)
        (result.messages || []).each { |m| ids << m.id }
        page_token = result.next_page_token
        break unless page_token
      end
      ids
    end

    # Fetches metadata for each id, in batches. Returns
    #   [{ headers: {String=>String}, internal_date: Date }, ...]
    #
    # Gmail enforces two relevant throttles:
    #   - Concurrent requests (~10 in flight per user). Hit by big batches.
    #   - Per-minute quota (~250 units/min/user; messages.get costs 5).
    #     At batch_size 25 that's 125 units/batch; 2 sustained batches per
    #     minute is the ceiling. We pace at PER_BATCH_DELAY between batches.
    #
    # Errors of either flavor are caught and the affected ids are retried.
    # Per-minute quota errors back off 60s; concurrent errors back off
    # 1/2/4s. After max_retries, persistent failures are summarized once
    # per batch instead of per-message.
    PER_BATCH_DELAY = 6.0  # seconds; ~10 batches/minute = within quota
    PER_MINUTE_BACKOFF = 60

    def fetch_metadata_batched(ids, batch_size: 25, max_retries: 3)
      results = []
      pending = ids.dup
      attempt = 0

      while pending.any? && attempt <= max_retries
        retry_ids = []
        last_err_kind = nil
        chunks = pending.each_slice(batch_size).to_a

        chunks.each_with_index do |chunk, chunk_idx|
          batch_failures = Hash.new(0) # error message → count

          @service.batch do |svc|
            chunk.each do |id|
              svc.get_user_message(
                "me", id,
                format: "metadata",
                metadata_headers: METADATA_HEADERS
              ) do |msg, err|
                if err
                  kind = error_kind(err)
                  last_err_kind = kind if kind
                  if kind && attempt < max_retries
                    retry_ids << id
                  else
                    batch_failures[err.message.to_s.split("\n").first] += 1
                  end
                else
                  results << to_message_hash(msg)
                end
              end
            end
          end

          unless batch_failures.empty?
            batch_failures.each do |msg, n|
              @progress.puts "warn: dropped #{n} message(s) — #{msg}"
            end
          end

          @progress.write(".")
          @progress.flush if @progress.respond_to?(:flush)

          # Throttle between batches once we've had any rate-limit signal,
          # OR when the run is big enough that we'll otherwise blow quota.
          if (last_err_kind || chunks.size > 5) && chunk_idx < chunks.size - 1
            sleep(PER_BATCH_DELAY)
          end
        end

        pending = retry_ids
        if pending.any?
          attempt += 1
          sleep_for = last_err_kind == :per_minute ? PER_MINUTE_BACKOFF : 2**(attempt - 1)
          @progress.puts "(rate-limited on #{pending.size} messages; retry #{attempt}/#{max_retries} after #{sleep_for}s)"
          sleep(sleep_for)
        end
      end

      @progress.write("\n") unless ids.empty?
      results
    end

    # Fetches a single message in full format (with body). Returns the
    # HTML body if present, else the plain-text body, else nil. Used for
    # preferences-page discovery; never raises (returns nil on any error).
    def fetch_message_body(id)
      msg = @service.get_user_message("me", id, format: "full")
      return nil if msg.nil?

      extract_body(msg.payload)
    rescue StandardError => e
      @progress.puts "warn: failed to fetch full message #{id}: #{e.message}"
      nil
    end

    private

    def extract_body(part)
      return nil if part.nil?

      mime = part.mime_type.to_s
      data = part.body&.data
      if mime == "text/html" && data
        decode(data)
      elsif mime == "text/plain" && data
        decode(data)
      elsif part.parts && !part.parts.empty?
        # Multipart: prefer html, fall back to plain.
        html = part.parts.map { |p| extract_body(p) }.find { |b| b && b.start_with?("<") }
        return html if html

        part.parts.map { |p| extract_body(p) }.find { |b| b }
      end
    end

    def decode(data)
      # Gmail returns base64url-encoded bodies; the gem does the decode
      # via attr_accessor, but in case it didn't (older versions), do it
      # explicitly. The gem's decoded data already arrives as a String.
      data.to_s
    end

    # Returns :per_minute, :concurrent, or nil. Per-minute quota
    # exhaustion needs a long cooldown (~60s), while concurrent-request
    # errors clear in milliseconds.
    def error_kind(err)
      msg = err.message.to_s
      return :per_minute if msg.include?("Quota exceeded for quota metric 'Queries'") ||
                            msg.include?("Queries per minute per user")
      return :concurrent if msg.include?("Too many concurrent requests") ||
                            msg.include?("rateLimitExceeded") ||
                            msg.include?("userRateLimitExceeded")

      nil
    end

    def to_message_hash(msg)
      headers = {}
      Array(msg.payload&.headers).each { |h| headers[h.name] = h.value }
      ms = msg.internal_date.to_i
      date = ms.zero? ? nil : Time.at(ms / 1000).utc.to_date
      { id: msg.id, headers: headers, internal_date: date }
    end
  end
end
