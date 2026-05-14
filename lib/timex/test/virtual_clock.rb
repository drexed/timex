# frozen_string_literal: true

module TIMEx
  # Test helpers for controlling TIMEx time without real sleeps.
  #
  # Installs a {Clock::VirtualClock} on the current thread and exposes helpers to
  # advance it from nested code.
  #
  # @see Clock::VirtualClock
  module Test

    extend self

    # Installs a {Clock::VirtualClock} for the block and yields it for manual control.
    #
    # @param start_ns [Integer] initial monotonic nanoseconds for the virtual clock
    # @yieldparam clock [Clock::VirtualClock] the installed virtual clock
    # @return [Object] the block's return value
    #
    # @note Also sets +:timex_test_clock+ so {.advance} can find the active clock
    #   without threading the object through call sites.
    def with_virtual_clock(start_ns: 0)
      previous_clock = Thread.current.thread_variable_get(:timex_clock)
      previous_test_clock = Thread.current.thread_variable_get(:timex_test_clock)
      clock = Clock::VirtualClock.new(monotonic_ns: start_ns)
      Thread.current.thread_variable_set(:timex_clock, clock)
      Thread.current.thread_variable_set(:timex_test_clock, clock)
      yield clock
    ensure
      Thread.current.thread_variable_set(:timex_clock, previous_clock)
      Thread.current.thread_variable_set(:timex_test_clock, previous_test_clock)
    end

    # Advances the active {Clock::VirtualClock} by +seconds+.
    #
    # @param seconds [Numeric] delta in seconds
    # @return [Clock::VirtualClock] the advanced clock
    # @raise [RuntimeError] when called outside {.with_virtual_clock}
    def advance(seconds)
      clock = Thread.current.thread_variable_get(:timex_test_clock) ||
              raise("call inside TIMEx::Test.with_virtual_clock { ... }")
      clock.advance(seconds)
    end

    # @see .with_virtual_clock
    def freeze_time(&)
      with_virtual_clock(&)
    end

  end
end
