# frozen_string_literal: true

module TIMEx
  module Composers
    # Runs a **soft** strategy first, then escalates to a **hard** strategy after
    # +grace+ seconds beyond the soft budget, killing the soft worker and
    # re-invoking the block (requires +idempotent: true+).
    #
    # @see Base
    class TwoPhase < Base

      attr_reader :soft, :hard, :grace, :hard_deadline, :idempotent

      # @param soft [Symbol, Strategies::Base] strategy for the first attempt
      # @param hard [Symbol, Strategies::Base] strategy that forcibly bounds the second attempt
      # @param grace [Numeric] seconds after soft budget before escalation
      # @param hard_deadline [Numeric] hard-phase budget in seconds (clamped to parent remaining)
      # @param idempotent [Boolean] must be +true+; acknowledges the block may run twice
      # @raise [ArgumentError] when invariants are violated
      def initialize(soft:, hard:, grace: 0.5, hard_deadline: 1.0, idempotent: false)
        super()
        raise ArgumentError, "TwoPhase escalates by re-invoking the block; pass idempotent: true to acknowledge" unless idempotent
        raise ArgumentError, "grace must be a non-negative Numeric" unless grace.is_a?(Numeric) && !grace.negative?
        raise ArgumentError, "hard_deadline must be a positive Numeric" unless hard_deadline.is_a?(Numeric) && hard_deadline.positive?

        @soft = Registry.resolve(soft)
        @hard = Registry.resolve(hard)
        @grace = grace
        @hard_deadline = hard_deadline
        @idempotent = idempotent
      end

      # @param deadline [Deadline, Numeric, Time, nil]
      # @param on_timeout [Symbol, Proc]
      # @param opts [Hash{Symbol => Object}] forwarded to child strategies
      # @yieldparam deadline [Deadline]
      # @return [Object] soft-path value, hard-path value, or handler result
      # @raise [StandardError] when the soft worker raises a non-timeout error
      def call(deadline:, on_timeout: :raise, **opts, &block)
        deadline = Deadline.coerce(deadline)
        soft_budget = deadline.infinite? ? nil : deadline.remaining
        wait = soft_budget ? soft_budget + @grace : nil

        TIMEx::Telemetry.instrument(
          event: "composer.two_phase",
          soft_ms: soft_budget && (soft_budget * 1000).round,
          grace_ms: (@grace * 1000).round
        ) do |payload|
          queue = Queue.new
          worker = Thread.new do
            value = @soft.call(deadline:, on_timeout: :raise, **opts, &block)
            queue << [:ok, value]
          rescue Expired => e
            queue << [:soft_timeout, e]
          rescue StandardError => e
            queue << [:error, e]
          end

          if (outcome = pop_with_timeout(queue, wait))
            kind, value = outcome
            payload[:outcome] = kind == :ok ? :ok : kind
            return value if kind == :ok
            raise value if kind == :error

            return handle_timeout(on_timeout, value)
          end

          # Worker exceeded soft + grace. Force-stop and escalate.
          worker.kill
          payload[:soft_timeout] = true

          # Clamp the hard-phase budget to whatever remains on the parent
          # deadline, so escalation cannot extend the caller's contract.
          hard_deadline = Deadline.in(@hard_deadline).min(deadline)
          begin
            @hard.call(deadline: hard_deadline, on_timeout: :raise, **opts, &block)
          rescue Expired => e
            payload[:outcome] = :hard_timeout
            handle_timeout(on_timeout, e)
          end
        end
      end

      private

      # @param queue [Queue]
      # @param seconds [Numeric, nil]
      # @return [Array, nil] queued pair or +nil+ on timeout
      def pop_with_timeout(queue, seconds)
        return queue.pop if seconds.nil?

        queue.pop(timeout: seconds)
      end

    end
  end
end
