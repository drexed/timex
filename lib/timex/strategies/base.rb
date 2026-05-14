# frozen_string_literal: true

module TIMEx
  module Strategies
    # Abstract strategy: runs user code against a {Deadline} and maps {Expired}
    # to +on_timeout:+ behavior via {TimeoutHandling}.
    #
    # Subclasses implement {#run}. Telemetry wraps each invocation when a
    # non-null adapter is configured.
    #
    # @see TIMEx.deadline
    # @see Registry
    class Base

      include TIMEx::NamedComponent
      include TIMEx::TimeoutHandling

      class << self

        # Convenience constructor: +new(**opts).call(...)+.
        #
        # @param deadline [Deadline, Numeric, Time, nil] budget or absolute deadline
        # @param on_timeout [Symbol, Proc] timeout dispatch mode
        # @param opts [Hash{Symbol => Object}] subclass-specific options forwarded to +#initialize+
        # @yieldparam deadline [Deadline] coerced deadline passed to user block
        # @return [Object] block result or handler return (see {TimeoutHandling})
        def call(deadline:, on_timeout: :raise, **opts, &block)
          new(**opts).call(deadline:, on_timeout:, &block)
        end

      end

      # Coerces +deadline+, optionally instruments, and runs {#run}.
      #
      # @param deadline [Deadline, Numeric, Time, nil]
      # @param on_timeout [Symbol, Proc]
      # @yieldparam deadline [Deadline]
      # @return [Object]
      def call(deadline:, on_timeout: :raise, &block)
        deadline = Deadline.coerce(deadline)

        # Resolve the adapter exactly once per call. `Telemetry.adapter` walks
        # `Telemetry.@adapter || TIMEx.config.telemetry_adapter || ...` on
        # every access; we hand the resolved object straight to `instrument`
        # to avoid re-walking it under the hot-path null check.
        adapter = TIMEx::Telemetry.adapter
        return run_unobserved(deadline, on_timeout, &block) if adapter.is_a?(TIMEx::Telemetry::Adapters::Null)

        deadline_ms = deadline.infinite? ? nil : deadline.remaining_ms.round
        TIMEx::Telemetry.instrument(
          event: "strategy.call",
          strategy: self.class.name_symbol,
          deadline_ms:
        ) do |payload|
          run(deadline, &block)
        rescue Expired => e
          payload[:outcome] = :timeout
          handle_timeout(on_timeout, e)
        end
      end

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object]
      # @raise [NotImplementedError] on +Base+
      def run(_deadline)
        raise NotImplementedError
      end

      private

      # Telemetry-free path when the adapter is {Telemetry::Adapters::Null}.
      #
      # @param deadline [Deadline]
      # @param on_timeout [Symbol, Proc]
      # @yieldparam deadline [Deadline]
      # @return [Object]
      def run_unobserved(deadline, on_timeout, &)
        run(deadline, &)
      rescue Expired => e
        handle_timeout(on_timeout, e)
      end

    end
  end
end
