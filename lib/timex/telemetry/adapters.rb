# frozen_string_literal: true

module TIMEx
  module Telemetry
    # Concrete {Telemetry} backends. All adapters receive symbol/string event names
    # and a mutable +payload+ hash for a single logical operation.
    #
    # @see Telemetry.instrument
    # @see Telemetry.emit
    module Adapters

      # No-op base type documenting the adapter protocol.
      class Base

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def start(event:, payload:); end

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def finish(event:, payload:); end

        # Default one-shot implementation pairing {#start} and {#finish}.
        #
        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def emit(event:, payload:)
          start(event:, payload:)
          finish(event:, payload:)
        end

      end

      # Sentinel adapter used when nothing is configured.
      class Null < Base; end

      # Emits a single structured log line per {#finish} with a conservative key allowlist.
      class Logger < Base

        # Keys considered safe to log by default. Application-supplied data
        # like `headers` or block arguments are excluded to avoid leaking
        # secrets/PII through structured logs. `origin` is whitelisted
        # because {Deadline.from_header} enforces `ORIGIN_PATTERN` so the
        # value can only be `[A-Za-z0-9_.-]+`. Pass `extra_keys:` to include
        # additional whitelisted keys.
        DEFAULT_SAFE_KEYS = %i[event strategy outcome deadline_ms elapsed_ms error_class
                               soft_ms grace_ms estimate_ms budget_ms
                               soft_timeout hard_timeout depth skew_ms origin
                               reason].freeze

        # @param logger [#info] logger receiving +#info+ calls
        # @param extra_keys [Array<Symbol, String>] additional payload keys to include
        def initialize(logger, extra_keys: [])
          super()
          @logger    = logger
          @safe_keys = (DEFAULT_SAFE_KEYS + Array(extra_keys).map(&:to_sym)).uniq.freeze
        end

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def finish(event:, payload:)
          @logger.info("[timex] #{event} #{filtered(payload).inspect}")
        end

        private

        # @param payload [Hash{Symbol => Object}]
        # @return [Hash{Symbol => Object}]
        def filtered(payload)
          payload.each_with_object({}) do |(k, v), acc|
            acc[k] = v if @safe_keys.include?(k)
          end
        end

      end

      # Bridges TIMEx events to +ActiveSupport::Notifications+.
      class ActiveSupportNotifications < Base

        EVENT_PREFIX = "timex."

        def initialize
          super
          require "active_support/notifications"
        end

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def start(event:, payload:)
          instrumenter = ::ActiveSupport::Notifications.instrumenter
          payload[:__asn_token] = instrumenter.start("#{EVENT_PREFIX}#{event}", payload)
        end

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def finish(event:, payload:)
          token = payload.delete(:__asn_token)
          return unless token

          ::ActiveSupport::Notifications.instrumenter.finish_with_state(token, "#{EVENT_PREFIX}#{event}", payload)
        end

      end

      # Bridges TIMEx spans to OpenTelemetry when the gem is available.
      class OpenTelemetry < Base

        ATTRIBUTE_TYPES = [String, Symbol, Numeric, TrueClass, FalseClass, NilClass].freeze

        def initialize
          super
          require "opentelemetry/api"
        end

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def start(event:, payload:)
          tracer = ::OpenTelemetry.tracer_provider.tracer("timex")
          payload[:__otel_span] = tracer.start_span(
            event,
            attributes: coerce_attributes(payload)
          )
        end

        # @param event [Symbol, String]
        # @param payload [Hash{Symbol => Object}]
        # @return [void]
        def finish(event:, payload:)
          span = payload.delete(:__otel_span)
          return unless span

          span.set_attribute("timex.elapsed_ms", payload[:elapsed_ms]) if payload[:elapsed_ms] && span.respond_to?(:set_attribute)

          if span.respond_to?(:status=)
            case payload[:outcome]
            when :timeout
              span.status = ::OpenTelemetry::Trace::Status.error("timeout")
            when :error
              span.status = ::OpenTelemetry::Trace::Status.error(payload[:error_class].to_s)
            end
          end

          span.finish
        end

        private

        # Drops keys with nested or non-OTel-supported values rather than
        # lossy `to_s`-ifying everything.
        #
        # @param payload [Hash{Symbol => Object}]
        # @return [Hash{String => Object}]
        def coerce_attributes(payload)
          payload.each_with_object({}) do |(k, v), acc|
            next if k.to_s.start_with?("__")
            next unless ATTRIBUTE_TYPES.any? { |t| v.is_a?(t) }

            acc[k.to_s] = v.is_a?(Symbol) ? v.to_s : v
          end
        end

      end

    end
  end
end
