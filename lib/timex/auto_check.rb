# frozen_string_literal: true

module TIMEx
  # Best-effort cooperative deadline checks driven by +TracePoint+ (+:line+ and
  # +:b_return+). Injects periodic {#Deadline#check!} calls without requiring manual
  # probes inside the block.
  #
  # @note +:line+ events are expensive; expect noticeable overhead on tight loops.
  #   Prefer explicit {#Deadline#check!} for hot paths.
  #
  # @note TracePoint does not fire inside C-native methods (+Mutex#synchronize+,
  #   blocking +IO+, etc.); pair with an IO-aware strategy for those regions.
  #
  # @note Only +target_thread:+ is traced; child threads need their own setup or
  #   explicit deadline checks.
  #
  # @see Strategies::Cooperative
  # @see Configuration#auto_check_interval
  module AutoCheck

    # Only Ruby-level events: +:line+ already polls between every Ruby
    # statement, and +:b_return+ adds coverage at block boundaries so we
    # interrupt promptly between iterations. +:c_return+ was tempting but
    # fires on every C method return (Hash#[], String#+, …) — the dispatch
    # cost dwarfs the latency win on any non-trivial loop body.
    EVENTS = %i[line b_return].freeze

    extend self

    # Runs +block+ with TracePoint-driven deadline checks every +interval+ Ruby events.
    #
    # @param deadline [Deadline]
    # @param interval [Integer] line/block events between checks (from config by default)
    # @yieldparam deadline [Deadline]
    # @return [Object] the block's return value
    # @raise [Expired] when the deadline elapses between checks
    def run(deadline, interval: TIMEx.config.auto_check_interval)
      return yield(deadline) if deadline.infinite?

      counter = 0
      tp = TracePoint.new(*EVENTS) do |_event|
        counter += 1
        next unless counter >= interval

        counter = 0
        next if Thread.current.thread_variable_get(:timex_shielded)
        next unless deadline.expired?

        tp.disable
        deadline.check!(strategy: :cooperative)
      end

      tp.enable(target_thread: Thread.current) do
        yield(deadline)
      end
    end

  end
end
