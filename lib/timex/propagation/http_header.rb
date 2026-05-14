# frozen_string_literal: true

module TIMEx
  module Propagation
    # Helpers for reading and writing the {Deadline::HEADER_NAME} wire format on
    # Rack env and generic header maps.
    #
    # @see Deadline.from_header
    # @see Deadline#to_header
    module HttpHeader

      HEADER_NAME      = Deadline::HEADER_NAME
      RACK_HEADER_KEY  = "HTTP_X_TIMEX_DEADLINE"

      extend self

      # @param env [Hash{String => Object}] Rack environment (+HTTP_*+ keys)
      # @return [Deadline, nil] parsed deadline or +nil+
      def from_rack_env(env)
        Deadline.from_header(env[RACK_HEADER_KEY])
      end

      # Resolves a deadline from a case-insensitive header map when possible.
      #
      # @param headers [Hash, #key?, #find, nil] header-like collection
      # @return [Deadline, nil]
      def from_headers(headers)
        return Deadline.from_header(nil) if headers.nil?

        return Deadline.from_header(headers[HEADER_NAME]) if headers.respond_to?(:key?) && headers.key?(HEADER_NAME)

        pair = headers.find { |k, _| k.to_s.casecmp?(HEADER_NAME) } if headers.respond_to?(:find)
        Deadline.from_header(pair&.last)
      end

      # Writes +deadline+ into +headers+ under {HEADER_NAME}.
      #
      # @param headers [Hash] mutable header map (mutated in place)
      # @param deadline [Deadline]
      # @param prefer [:remaining, :wall] forwarded to {Deadline#to_header}
      # @return [Hash] +headers+ (same object)
      def inject(headers, deadline, prefer: :remaining)
        headers[HEADER_NAME] = deadline.to_header(prefer:)
        headers
      end

    end
  end
end
