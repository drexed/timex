# frozen_string_literal: true

module TIMEx
  module Composers
    # Launches up to +max:+ staggered parallel attempts (+after:+ seconds apart)
    # of +child+ and returns the first successful result.
    #
    # @note Losers are stopped with +Thread#kill+; the block must tolerate
    #   concurrent execution, partial side effects, and abrupt termination.
    #
    # @see Base
    class Hedged < Base

      # @param after [Numeric] seconds between successive attempt launches
      # @param child [Symbol, Strategies::Base] strategy used per attempt
      # @param max [Integer] maximum concurrent attempts (>= 1)
      # @param idempotent [Boolean] must be +true+; acknowledges concurrent/kill semantics
      # @raise [ArgumentError] when parameters are invalid
      def initialize(after:, child:, max: 2, idempotent: false)
        super()
        raise ArgumentError, "Hedged requires idempotent: true" unless idempotent
        raise ArgumentError, "after must be a non-negative Numeric" unless after.is_a?(Numeric) && !after.negative?
        raise ArgumentError, "max must be >= 1" if max < 1

        @after = after
        @max = max
        @child = Registry.resolve(child)
      end

      # @param deadline [Deadline, Numeric, Time, nil]
      # @param on_timeout [Symbol, Proc]
      # @param opts [Hash{Symbol => Object}] forwarded to each child attempt
      # @yieldparam deadline [Deadline]
      # @return [Object] first successful value or handler result
      # @raise [StandardError] re-raised from a failed attempt when no success precedes it
      def call(deadline:, on_timeout: :raise, **opts, &block)
        deadline = Deadline.coerce(deadline)
        results = Queue.new
        # Side-channel of "a result just landed" notifications so the spawn
        # loop can block on `signal.pop(timeout:)` instead of polling — we
        # can't peek at `results` non-destructively without disturbing the
        # consumption order of `await_outcome`.
        signal = Queue.new
        threads = []

        threads << launch(deadline, results, signal, opts, &block)
        until !results.empty? || (threads.size >= @max) || deadline.expired?
          status = wait_for_result(@after, signal, deadline)
          break if status == :result_ready
          # `wait_for_result` returns `:expired` when the parent deadline
          # elapsed during the wait. Bail before launching a redundant
          # worker that would race against the expiration.
          break if status == :expired

          threads << launch(deadline, results, signal, opts, &block)
        end

        outcome = await_outcome(results, threads.size, deadline)
        threads.each { |t| t.kill if t.alive? }

        case outcome[0]
        when :ok then outcome[1]
        when :error then raise outcome[1]
        when :timeout
          handle_timeout(
            on_timeout,
            deadline.expired_error(
              strategy: :hedged,
              message: "all hedged attempts timed out"
            )
          )
        end
      end

      private

      # Drains queued results so that a non-`:ok` outcome doesn't beat a still-
      # pending successful attempt. Returns the first `:ok`, otherwise the last
      # outcome seen (preferring `:error` over `:timeout`). Bounded by the
      # parent deadline so a non-cooperative child cannot hang the composer.
      #
      # @param results [Queue]
      # @param expected [Integer] number of workers launched
      # @param deadline [Deadline]
      # @return [Array] +[:ok, value]+, +[:error, exception]+, or +[:timeout]+
      def await_outcome(results, expected, deadline)
        seen = []
        expected.times do
          remaining = deadline.infinite? ? nil : [deadline.remaining, 0.0].max
          outcome   = remaining.nil? ? results.pop : results.pop(timeout: remaining)
          if outcome.nil?
            # Drain anything that landed between the previous pop and now so a
            # late-arriving winner isn't dropped on a tight deadline.
            until results.empty?
              late = results.pop(timeout: 0)
              break if late.nil?
              return late if late[0] == :ok

              seen << late
            end
            break
          end
          return outcome if outcome[0] == :ok

          seen << outcome
        end
        seen.find { |o| o[0] == :error } || seen.last || [:timeout]
      end

      # @return [Thread]
      def launch(deadline, results, signal, opts, &block)
        Thread.new do
          value = @child.call(deadline:, on_timeout: :raise, **opts, &block)
          results << [:ok, value]
          signal  << :ready
        rescue Expired
          results << [:timeout]
          signal  << :ready
        rescue StandardError => e
          results << [:error, e]
          signal  << :ready
        end
      end

      # Blocks for up to +seconds+ (or until the parent deadline elapses)
      # waiting for a worker to enqueue a result. Uses a notification queue so
      # we don't have to poll or peek at +results+. Returns +:expired+ when
      # the parent deadline already elapsed (so +signal.pop(timeout: 0)+
      # would no-op and the caller would otherwise spawn a redundant worker
      # before the outer +deadline.expired?+ re-check).
      #
      # @param seconds [Numeric]
      # @param signal [Queue]
      # @param deadline [Deadline]
      # @return [Symbol] +:result_ready+, +:expired+, or +:time_up+
      def wait_for_result(seconds, signal, deadline)
        return :result_ready if signal.pop(timeout: 0)
        return :expired if !deadline.infinite? && deadline.remaining <= 0

        wait = deadline.infinite? ? seconds : [deadline.remaining, seconds].min
        signal.pop(timeout: wait) ? :result_ready : :time_up
      end

    end
  end
end
