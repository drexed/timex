# frozen_string_literal: true

module TIMEx
  module Propagation
    # Rack middleware: parses inbound {HttpHeader::HEADER_NAME}, stores
    # +env["timex.deadline"]+, optionally clamps and rejects abusive values, and
    # can echo remaining budget on the response.
    #
    # @note The header is **untrusted** on public networks. Combine +max_seconds:+,
    #   +max_depth:+, and network controls; see class body for threat summary.
    #
    # @see HttpHeader
    # @see Deadline.from_header
    class RackMiddleware

      ENV_KEY              = "timex.deadline"
      RAW_HEADER_KEY       = HttpHeader::RACK_HEADER_KEY

      # Rack 3 mandates lower-case response header names; Rack 2 (and many
      # 3rd-party middlewares that haven't migrated) still emit canonical
      # case. Pass `header_case: :canonical` to switch the response header
      # names to `Content-Type` / `X-TIMEx-*` for Rack-2-era stacks.
      HEADER_NAMES = {
        rack3: {
          remaining: "x-timex-remaining-ms",
          outcome: "x-timex-outcome",
          content_type: "content-type"
        }.freeze,
        canonical: {
          remaining: "X-TIMEx-Remaining-Ms",
          outcome: "X-TIMEx-Outcome",
          content_type: "Content-Type"
        }.freeze
      }.freeze

      # @param app [#call] inner Rack application
      # @param default_seconds [Numeric, nil] installed when no header is present
      # @param max_seconds [Numeric, nil] clamps inbound deadlines to at most this budget
      # @param max_depth [Integer, nil] rejects requests whose parsed +depth+ exceeds this value
      # @param expose_remaining [Boolean] when +true+, adds remaining-ms response header
      # @param clamp_infinite_to_default [Boolean] when +true+ with +default_seconds+, maps inbound infinite to default
      # @param header_case [:rack3, :canonical] response header casing
      # @raise [ArgumentError] when +header_case+ is unknown
      def initialize(app, default_seconds: nil, max_seconds: nil, max_depth: nil, # rubocop:disable Metrics/ParameterLists
                     expose_remaining: false, clamp_infinite_to_default: false,
                     header_case: :rack3)
        raise ArgumentError, "header_case must be :rack3 or :canonical" unless HEADER_NAMES.key?(header_case)

        @app = app
        @default_seconds = default_seconds
        @max_seconds = max_seconds
        @max_depth = max_depth
        @expose_remaining = expose_remaining
        @clamp_infinite_to_default = clamp_infinite_to_default
        @headers = HEADER_NAMES.fetch(header_case)
      end

      # Security: this header is taken from the inbound HTTP request without
      # authentication. An attacker who can reach this endpoint can send
      # `ms=0` to force an immediate 503, or a large `ms=` value to extend a
      # request's allowed processing window beyond what your server intended.
      # Only mount this middleware on networks where the upstream is trusted
      # (e.g. internal service mesh, signed/authenticated requests).
      #
      # For internet-facing deployments, **always** pass `max_seconds:` so any
      # incoming deadline is clamped to that ceiling, and `max_depth:` to bound
      # propagation hops (example: `use TIMEx::Propagation::RackMiddleware, max_seconds: 30, max_depth: 8`).
      #
      # `Deadline.from_header` also caps untrusted input length at
      # `Deadline::MAX_HEADER_BYTESIZE`, rejects non-finite/negative/very large
      # `ms=` values, and clamps `depth=` at `Deadline::MAX_DEPTH`.
      #
      # `max_depth` is enforced on the *parsed inbound* deadline before
      # `max_seconds` clamping. Clamping via {Deadline#min} can yield a fresh
      # deadline without propagation metadata; checking depth only after clamp
      # would let a client bypass the hop limit with an oversized `ms=`.
      #
      # @param env [Hash{String => Object}]
      # @return [Array(Integer, Hash, #each)] Rack triplet
      def call(env)
        # Distinguish "no header sent" from "header present but unparseable":
        # the latter is suspicious (truncation, smuggling attempt) and
        # deserves a telemetry signal even though we still fall through to
        # `default_seconds` / unbounded handling.
        raw = env[RAW_HEADER_KEY]
        deadline = HttpHeader.from_rack_env(env)
        if raw && !raw.empty? && deadline.nil?
          TIMEx::Telemetry.emit(
            event: "rack.deadline.unparseable",
            bytesize: raw.bytesize
          )
        end

        if depth_exceeded?(deadline)
          TIMEx::Telemetry.emit(
            event: "rack.deadline.rejected",
            reason: :max_depth_exceeded,
            depth: deadline.depth,
            origin: deadline.origin
          )
          return reject_response("max-depth-exceeded", "Deadline propagation depth exceeded")
        end

        deadline = nil if deadline&.infinite? && @clamp_infinite_to_default && @default_seconds
        deadline = clamp(deadline)
        deadline ||= Deadline.in(@default_seconds) if @default_seconds

        if deadline
          env[ENV_KEY] = deadline
          env[RAW_HEADER_KEY] = deadline.to_header
        else
          env.delete(RAW_HEADER_KEY)
        end

        if deadline&.expired?
          TIMEx::Telemetry.emit(
            event: "rack.deadline.rejected",
            reason: :expired_on_arrival,
            origin: deadline.origin
          )
          return reject_response("expired-on-arrival", "Deadline expired before request handling")
        end

        status, headers, body = @app.call(env)
        headers = inject_remaining(headers, deadline) if @expose_remaining
        [status, headers, body]
      end

      private

      # @param outcome [String] value for the outcome response header
      # @param body [String] plain-text body (wrapped in a single-element array)
      # @return [Array(Integer, Hash, Array<String>)]
      def reject_response(outcome, body)
        [
          503,
          {
            @headers[:content_type] => "text/plain",
            @headers[:outcome] => outcome
          },
          [body]
        ]
      end

      # @param deadline [Deadline, nil]
      # @return [Deadline, nil]
      def clamp(deadline)
        return deadline unless deadline && @max_seconds

        deadline.min(Deadline.in(@max_seconds))
      end

      # @param deadline [Deadline, nil]
      # @return [Boolean]
      def depth_exceeded?(deadline)
        return false unless deadline && @max_depth

        deadline.depth > @max_depth
      end

      # @param headers [Hash, Object]
      # @param deadline [Deadline, nil]
      # @return [Hash, Object]
      def inject_remaining(headers, deadline)
        return headers unless deadline && !deadline.infinite?
        return headers unless headers.is_a?(Hash) || headers.respond_to?(:merge)

        value = deadline.remaining_ms.round.to_s
        key = @headers[:remaining]
        if headers.frozen?
          headers.merge(key => value)
        else
          headers[key] = value
          headers
        end
      end

    end
  end
end
