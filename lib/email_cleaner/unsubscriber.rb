# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "google/apis/gmail_v1"

module EmailCleaner
  class Unsubscriber
    HTTP_TIMEOUT = 10 # seconds

    def initialize(gmail_service:)
      @gmail = gmail_service
    end

    # Returns { method:, status:, url:, confirmed: }.
    def run(stats)
      info = stats.unsub_info

      if info.one_click? && info.https_url
        post_one_click(info.https_url)
      elsif info.https_url
        { method: :https_only, status: "manual", url: info.https_url, confirmed: false }
      elsif info.mailto_url
        send_mailto(stats.sender.address, info.mailto_url)
      else
        { method: :error, status: "no_url", url: nil, confirmed: false }
      end
    end

    private

    def post_one_click(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = "List-Unsubscribe=One-Click"

      response = http.request(req)
      status = response.code.to_i
      {
        method: :one_click,
        status: status,
        url: url,
        # 2xx is unambiguous success; many real senders return 3xx redirects
        # to a confirmation page on success, so treat those as confirmed too.
        confirmed: status >= 200 && status < 400
      }
    rescue StandardError => e
      { method: :error, status: e.class.name, url: url, confirmed: false }
    end

    def send_mailto(_sender_addr, mailto)
      uri = URI.parse(mailto)
      opaque = uri.opaque || ""
      to, query_str = opaque.split("?", 2)
      params = CGI.parse(query_str || uri.query || "")
      subject = params["subject"]&.first&.strip
      subject = "unsubscribe" if subject.nil? || subject.empty?
      body = params["body"]&.first.to_s

      raw = build_rfc5322(to: to, subject: subject, body: body)

      message = Google::Apis::GmailV1::Message.new(raw: raw)
      @gmail.send_user_message("me", message)

      { method: :mailto, status: "sent", url: mailto, confirmed: true }
    rescue StandardError => e
      { method: :error, status: e.class.name, url: mailto, confirmed: false }
    end

    def build_rfc5322(to:, subject:, body:)
      [
        "To: #{to}",
        "Subject: #{subject}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=utf-8",
        "",
        body
      ].join("\r\n")
    end
  end
end
