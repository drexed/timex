# frozen_string_literal: true

module TIMEx
  # Lightweight instrumentation facade for strategies, composers, and internal
  # events (deadline skew, cancellation observer errors, etc.).
  #
  # Resolution order for {#adapter}: explicit {Telemetry.adapter=} assignment,
  # then {Configuration#telemetry_adapter}, then {Adapters::Null}.
  #
  # @see Telemetry::Adapters
  # @see Configuration#telemetry_adapter=
  module Telemetry

    @adapter = nil
    @null_adapter = nil
    @strict = false

    extend self

    # Resolves the active adapter on each access so runtime config changes apply.
    #
    # @return [#emit, #start, #finish] concrete adapter instance
    def adapter
      return @adapter if @adapter

      TIMEx.config.telemetry_adapter || (@null_adapter ||= Adapters::Null.new)
    end

    # Forces a specific adapter (overrides {Configuration#telemetry_adapter} until cleared).
    #
    # @param value [#emit, #start, #finish, nil]
    # @return [#emit, #start, #finish, nil]
    def adapter=(value)
      @adapter = value
    end

    # When +true+, adapter errors propagate instead of being swallowed by {#instrument} / {#emit}.
    #
    # @return [Boolean]
    attr_accessor :strict

    # Clears memoized adapter state and resets {#strict} to +false+.
    #
    # @return [void]
    def reset!
      @adapter = nil
      @null_adapter = nil
      @strict = false
    end

    # @return [Boolean] +true+ when the resolved adapter is {Adapters::Null}
    #
    # @note Lets hot paths skip kwarg-heavy instrumentation when telemetry is disabled.
    def null_adapter?
      adapter.is_a?(Adapters::Null)
    end

    # Emits a one-shot event (no span pairing).
    #
    # @param event [Symbol, String] logical event name
    # @param payload [Hash{Symbol => Object}] structured attributes
    # @return [void]
    def emit(event:, **payload)
      a = adapter
      return if a.is_a?(Adapters::Null)

      safely { a.emit(event:, payload:) }
    end

    # Wraps a block with +start+ / +finish+ callbacks and elapsed timing in +payload+.
    #
    # @param event [Symbol, String] logical event name
    # @param base_payload [Hash{Symbol => Object}] initial payload (mutated; see @note)
    # @yieldparam payload [Hash{Symbol => Object}] same object passed to the adapter
    # @return [Object] the block's return value
    #
    # @note Mutates +base_payload+ in place to avoid per-call +dup+ on the hot path.
    def instrument(event:, **base_payload)
      a = adapter
      return yield(base_payload) if a.is_a?(Adapters::Null)

      # `base_payload` is a fresh hash from the kwarg splat at the call site;
      # the caller can't observe our mutations, so we skip the defensive dup
      # to save an allocation per instrumented call.
      payload = base_payload
      started_ns = Clock.monotonic_ns
      safely { a.start(event:, payload:) }
      begin
        result = yield(payload)
        payload[:outcome] ||= :ok
        result
      rescue StandardError, Expired => e
        payload[:outcome] ||= e.is_a?(Expired) ? :timeout : :error
        payload[:error_class] = e.class.name unless e.is_a?(Expired)
        raise
      end
    ensure
      if started_ns
        payload[:elapsed_ms] = (Clock.monotonic_ns - started_ns) / 1_000_000.0
        safely { a.finish(event:, payload:) }
      end
    end

    private

    # @yield adapter callback
    # @return [Object, nil]
    def safely
      yield
    rescue StandardError
      raise if @strict

      nil
    end

  end
end

require_relative "telemetry/adapters"
