# frozen_string_literal: true

module EmailCleaner
  class Sender
    attr_reader :address, :name

    def initialize(address:, name:)
      @address = address.to_s.downcase
      @name = name
    end

    def domain
      idx = @address.index("@")
      idx ? @address[(idx + 1)..] : ""
    end

    def ==(other)
      other.is_a?(Sender) && other.address == @address
    end
    alias eql? ==

    def hash
      @address.hash
    end
  end
end
