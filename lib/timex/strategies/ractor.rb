# frozen_string_literal: true

module TIMEx
  module Strategies
    # Runs the block inside a +Ractor+ for isolation from the caller's heap.
    #
    # The block and captured state must be Ractor-shareable; typical service
    # objects that close over +self+ will fail at runtime. Prefer a small frozen
    # lambda that only uses the yielded {Deadline}.
    #
    # @note On timeout the waiter thread is stopped but the Ractor may keep
    #   running; {Telemetry.emit} records a leak event for operators.
    #
    # @see ::Ractor
    # @see Base
    class Ractor < Base

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object] Ractor result value
      # @raise [TIMEx::Error] when Ruby lacks Ractor support, the block is missing,
      #   or the block cannot be made shareable
      # @raise [Expired] when the parent budget expires before the Ractor completes
      def run(deadline, &block)
        raise TIMEx::Error, "Ractor strategy requires a Ruby with Ractor support" unless defined?(::Ractor)
        raise TIMEx::Error, "Ractor strategy requires a block" unless block

        shareable_block    = ensure_shareable(block)
        shareable_deadline = ::Ractor.make_shareable(deadline)

        ractor = ::Ractor.new(shareable_block, shareable_deadline) do |b, d|
          b.call(d)
        end

        remaining = deadline.infinite? ? nil : deadline.remaining
        waiter    = Thread.new { ractor_value(ractor) }

        if waiter.join(remaining)
          waiter.value
        else
          # No public Ractor#kill — the Ractor will continue to completion
          # in the background. Surface this leak via telemetry so operators
          # can spot misbehaving children. Stop our own waiter so we don't
          # leak the Thread too.
          waiter.kill if waiter.alive?
          TIMEx::Telemetry.emit(
            event: "ractor.leak",
            deadline_ms: deadline.initial_ms&.round
          )
          raise deadline.expired_error(
            strategy: :ractor,
            message: "ractor deadline expired"
          )
        end
      end

      private

      # @param block [Proc]
      # @return [Proc]
      # @raise [TIMEx::Error] when the block captures non-shareable state
      def ensure_shareable(block)
        return block if ::Ractor.shareable?(block)

        ::Ractor.make_shareable(block)
      rescue ::Ractor::IsolationError, ArgumentError, TypeError => e
        raise TIMEx::Error,
          "Ractor strategy requires a shareable block; the supplied block " \
          "captures non-shareable state (#{e.class}: #{e.message})"
      end

      # @param ractor [Ractor]
      # @return [Object]
      def ractor_value(ractor)
        ractor.respond_to?(:value) ? ractor.value : ractor.take
      end

    end
  end
end

TIMEx::Registry.register(:ractor, TIMEx::Strategies::Ractor) if defined?(Ractor)
