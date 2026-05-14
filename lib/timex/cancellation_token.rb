# frozen_string_literal: true

module TIMEx
  # Thread-safe manual cancellation signal for long-running or hedged work.
  #
  # Observers registered via {#on_cancel} run outside the mutex after the
  # transition to cancelled; observer exceptions are swallowed and reported
  # through {Telemetry}.
  #
  # @see Telemetry.emit
  class CancellationToken

    # @return [void]
    def initialize
      @mutex = Mutex.new
      @cancelled = false
      @reason = nil
      @observers = []
    end

    # @return [Boolean] +true+ after {#cancel} succeeds
    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    attr_reader :reason

    # Marks the token cancelled and notifies observers (once).
    #
    # @param reason [Object, nil] opaque payload passed to observers
    # @return [Boolean] +true+ when this call performed the transition, +false+ if already cancelled
    def cancel(reason: nil) # rubocop:disable Naming/PredicateMethod
      observers_to_notify = nil
      @mutex.synchronize do
        return false if @cancelled

        @cancelled = true
        @reason = reason
        observers_to_notify = @observers.dup
      end
      observers_to_notify.each { |o| safe_call(o, reason) }
      true
    end

    # Registers a callback invoked on cancellation (immediately if already cancelled).
    #
    # @yield [reason] invoked when cancelled
    # @yieldparam reason [Object, nil] the reason passed to {#cancel}
    # @return [self] for chaining
    def on_cancel(&block)
      fire_now = false
      @mutex.synchronize do
        if @cancelled
          fire_now = true
        else
          @observers << block
        end
      end
      safe_call(block, @reason) if fire_now
      self
    end

    private

    # @param observer [Proc, #call]
    # @param reason [Object, nil]
    # @return [void]
    def safe_call(observer, reason)
      observer.call(reason)
    rescue StandardError => e
      # Observers must not break the cancellation chain. Surface the failure
      # via telemetry so it's debuggable instead of vanishing.
      begin
        TIMEx::Telemetry.emit(
          event: "cancellation.observer_error",
          error_class: e.class.name
        )
      rescue StandardError
        nil
      end
    end

  end
end
