# frozen_string_literal: true

module TIMEx
  module Composers
    # Chooses a per-call child deadline from a latency estimator, then delegates
    # to +child+ with +on_timeout: :raise+ so timeouts feed back into the
    # estimator uniformly before applying the caller's +on_timeout:+.
    #
    # @see Base
    class Adaptive < Base

      # O(1) streaming quantile estimator (P² algorithm, Jain & Chlamtac 1985).
      #
      # {#record} updates markers; {#estimate_ms} reads the last published estimate
      # without locking. Markers reset every +window+ samples.
      #
      # @note {#estimate_ms} is intentionally lock-free; it may briefly return a
      #   stale value while {#record} runs on another thread.
      class InMemoryStore

        P_DEFAULT = 0.99

        # @param window [Integer] samples before marker reset
        # @param alpha [Float] EWMA smoothing factor for the safety margin
        # @param p [Float] target quantile (default ~p99)
        def initialize(window: 200, alpha: 0.2, p: P_DEFAULT)
          @window = window
          @alpha = alpha
          @p = p
          @ewma = nil
          @count = 0
          @mutex = Mutex.new
          @last_estimate_ms = nil
          reset_markers
        end

        # Records a latency sample in milliseconds and refreshes the published estimate.
        #
        # @param ms [Numeric] observed latency in ms
        # @return [self]
        def record(ms)
          @mutex.synchronize do
            reset_markers if @count >= @window
            @count += 1
            @ewma  = @ewma.nil? ? ms : (@alpha * ms) + ((1 - @alpha) * @ewma)

            if @q.nil?
              @initial << ms
              promote_to_psquare if @initial.size == 5
            else
              psquare_step(ms)
            end
            # Publish the post-record estimate for lock-free reads. Single ivar
            # write is atomic in MRI; readers see either the previous or new
            # value, both of which are valid.
            @last_estimate_ms = compute_estimate
          end
          self
        end

        # Lock-free read: {#record} publishes a fresh estimate at the end of
        # every call under the mutex. Readers don't need to synchronize.
        #
        # @return [Float, nil] last estimated budget in ms, or +nil+ when empty
        def estimate_ms
          @last_estimate_ms
        end

        private

        def compute_estimate
          return nil if @count.zero?

          base = if @q
                   @q[2]
                 else
                   sorted = @initial.sort
                   sorted[((sorted.size - 1) * @p).round]
                 end
          [base, (@ewma || 0) * 3].max
        end

        def reset_markers
          @count   = 0
          @initial = []
          @q  = nil
          @n  = nil
          @np = nil
          @dn = nil
        end

        def promote_to_psquare
          @q  = @initial.sort
          @n  = [1, 2, 3, 4, 5]
          @np = [1.0, 1.0 + (2.0 * @p), 1.0 + (4.0 * @p), 3.0 + (2.0 * @p), 5.0]
          @dn = [0.0, @p / 2.0, @p, (1.0 + @p) / 2.0, 1.0]
          @initial = nil
        end

        def psquare_step(x)
          k = locate_cell(x)
          ((k + 1)..4).each { |i| @n[i] += 1 }
          5.times { |i| @np[i] += @dn[i] }
          (1..3).each { |i| adjust_marker(i) }
        end

        def locate_cell(x)
          if x < @q[0]
            @q[0] = x
            0
          elsif x < @q[1] then 0
          elsif x < @q[2] then 1
          elsif x < @q[3] then 2
          elsif x <= @q[4] then 3
          else
            @q[4] = x
            3
          end
        end

        def adjust_marker(i)
          d = @np[i] - @n[i]
          return unless (d >= 1 && @n[i + 1] - @n[i] > 1) || (d <= -1 && @n[i - 1] - @n[i] < -1)

          d = d.positive? ? 1 : -1
          qp = parabolic(i, d)
          qp = linear(i, d) if qp <= @q[i - 1] || qp >= @q[i + 1]
          @q[i] = qp
          @n[i] += d
        end

        def parabolic(i, d)
          @q[i] + ((d.to_f / (@n[i + 1] - @n[i - 1])) *
            ((((@n[i] - @n[i - 1] + d) * (@q[i + 1] - @q[i])) / (@n[i + 1] - @n[i])) +
             (((@n[i + 1] - @n[i] - d) * (@q[i] - @q[i - 1])) / (@n[i] - @n[i - 1]))))
        end

        def linear(i, d)
          @q[i] + ((d * (@q[i + d] - @q[i])) / (@n[i + d] - @n[i]))
        end

      end

      # @param child [Symbol, Strategies::Base] inner strategy
      # @param history [#estimate_ms, #record] latency store (defaults to {InMemoryStore})
      # @param multiplier [Numeric] scales the estimate into a budget
      # @param floor_ms [Numeric] minimum adaptive budget
      # @param ceiling_ms [Numeric] maximum adaptive budget
      # @raise [ArgumentError] when parameters are invalid
      def initialize(child:, history: InMemoryStore.new, multiplier: 1.5, floor_ms: 25, ceiling_ms: 30_000)
        super()
        raise ArgumentError, "multiplier must be > 0" unless multiplier.is_a?(Numeric) && multiplier.positive?
        raise ArgumentError, "floor_ms must be a positive Numeric" unless floor_ms.is_a?(Numeric) && floor_ms.positive?
        raise ArgumentError, "ceiling_ms must be >= floor_ms" unless ceiling_ms.is_a?(Numeric) && ceiling_ms >= floor_ms

        @child = Registry.resolve(child)
        @history = history
        @multiplier = multiplier
        @floor_ms = floor_ms
        @ceiling_ms = ceiling_ms
      end

      # @param deadline [Deadline, Numeric, Time, nil, Object] optional outer cap (+min+ with adaptive budget)
      # @param on_timeout [Symbol, Proc] applied after child raises {Expired}
      # @param opts [Hash{Symbol => Object}] forwarded to +child+
      # @yieldparam deadline [Deadline]
      # @return [Object] child return or timeout handler result
      # @raise [StandardError] non-timeout errors from the child propagate after recording latency
      def call(deadline: nil, on_timeout: :raise, **opts, &block)
        estimate  = @history.estimate_ms
        budget_ms = if estimate
                      (estimate * @multiplier).clamp(@floor_ms, @ceiling_ms)
                    else
                      @ceiling_ms
                    end

        adaptive_deadline = Deadline.in(budget_ms / 1000.0)
        effective         = deadline ? Deadline.coerce(deadline).min(adaptive_deadline) : adaptive_deadline

        TIMEx::Telemetry.instrument(
          event: "composer.adaptive",
          estimate_ms: estimate&.round,
          budget_ms: budget_ms.round,
          deadline_ms: effective.infinite? ? nil : effective.remaining_ms.round
        ) do |payload|
          started = Clock.monotonic_ns
          begin
            # Force the child to surface `Expired` so we can record a uniform
            # timeout penalty regardless of the caller's `on_timeout:` (a
            # `:return_nil`/`:result` path would otherwise be recorded as a
            # success at ~budget_ms and never penalize the estimator). We
            # re-apply the caller's `on_timeout:` ourselves.
            value = @child.call(deadline: effective, on_timeout: :raise, **opts, &block)
            @history.record((Clock.monotonic_ns - started) / 1_000_000.0)
            value
          rescue Expired => e
            payload[:outcome] = :timeout
            # Record the *budget* as the penalty (capped at ceiling), not the
            # multiplied estimate. Previously we recorded the parent-clamped
            # budget_ms back into history, which on a tight parent deadline
            # could differ from what we actually waited and bias the estimator.
            # Use `effective.remaining_ms` (post-clamp elapsed) if available so
            # the estimator tracks real wait time, falling back to budget_ms.
            elapsed_ms = (Clock.monotonic_ns - started) / 1_000_000.0
            @history.record([elapsed_ms, budget_ms.to_f].max.clamp(@floor_ms, @ceiling_ms))
            handle_timeout(on_timeout, e)
          rescue StandardError
            # User-cancelled or otherwise-failed attempts should still feed
            # the estimator: a child that consistently raises after ~budget_ms
            # tells us latency is rising, even if the caller is the one
            # throwing the exception. Cap the recorded sample at the ceiling
            # so a slow upstream-of-failure doesn't pin the estimator high.
            elapsed_ms = (Clock.monotonic_ns - started) / 1_000_000.0
            @history.record(elapsed_ms.clamp(@floor_ms, @ceiling_ms))
            raise
          end
        end
      end

    end
  end
end
