# frozen_string_literal: true

module EmailCleaner
  class UnsubInfo
    attr_reader :urls

    def initialize(urls:, one_click:)
      @urls = urls
      @one_click = one_click
    end

    def one_click?
      @one_click
    end

    def https_url
      @urls.find { |u| u[:scheme] == :https }&.dig(:value)
    end

    def mailto_url
      @urls.find { |u| u[:scheme] == :mailto }&.dig(:value)
    end
  end
end
