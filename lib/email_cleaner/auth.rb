# frozen_string_literal: true

require "googleauth"
require "googleauth/stores/file_token_store"
require "google/apis/gmail_v1"
require "webrick"
require_relative "browser"

module EmailCleaner
  module Auth
    SCOPES = [
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.send",
      "https://www.googleapis.com/auth/gmail.modify"
    ].freeze
    REDIRECT_URI = "http://localhost:47765"
    PORT = 47765
    CALLBACK_TIMEOUT = 300 # seconds

    module_function

    def authorize(config:)
      unless File.exist?(config.credentials_path)
        warn "Missing credentials.json at #{config.credentials_path}."
        warn "See README.md for setup instructions."
        raise SetupError, "credentials.json not found"
      end

      authorizer = build_authorizer(config)
      credentials = authorizer.get_credentials("default")
      credentials ||= run_loopback_flow(authorizer)

      service = Google::Apis::GmailV1::GmailService.new
      service.authorization = credentials
      service
    end

    class SetupError < StandardError; end
    class AuthError < StandardError; end

    def build_authorizer(config)
      client_id = Google::Auth::ClientId.from_file(config.credentials_path)
      token_store = Google::Auth::Stores::FileTokenStore.new(file: config.token_path)
      Google::Auth::UserAuthorizer.new(client_id, SCOPES, token_store)
    end

    def run_loopback_flow(authorizer)
      url = authorizer.get_authorization_url(base_url: REDIRECT_URI)
      code = capture_code_via_loopback(url)
      authorizer.get_and_store_credentials_from_code(
        user_id: "default",
        code: code,
        base_url: REDIRECT_URI
      )
    end

    def capture_code_via_loopback(url)
      code_holder = { code: nil }
      mutex = Mutex.new
      cond = ConditionVariable.new

      server = WEBrick::HTTPServer.new(
        Port: PORT,
        BindAddress: "127.0.0.1",
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )

      server.mount_proc "/" do |req, res|
        mutex.synchronize do
          code_holder[:code] = req.query["code"]
          cond.signal
        end
        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = "<html><body><h2>Authentication received.</h2>" \
                   "<p>You can close this tab.</p></body></html>"
      end

      thread = Thread.new { server.start }
      Browser.open(url) || warn("Open this URL to authorize: #{url}")

      mutex.synchronize do
        cond.wait(mutex, CALLBACK_TIMEOUT)
      end

      server.shutdown
      thread.join

      raise AuthError, "OAuth code not received within #{CALLBACK_TIMEOUT}s" if code_holder[:code].nil?

      code_holder[:code]
    end

  end
end
