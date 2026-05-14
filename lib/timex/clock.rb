# frozen_string_literal: true

module TIMEx
  # Thread-scoped clock abstraction for monotonic and wall time in nanoseconds.
  #
  # Production code reads {RealClock} unless {TIMEx::Configuration#clock=} or
  # {TIMEx::Test.with_virtual_clock} overrides the current binding via
  # +thread_variable_*+ (not fiber-local storage).
  #
  # @note Uses +Thread.current.thread_variable_get/set(:timex_clock)+ so every fiber
  #   in a thread shares one clock context (deadline shielding, {AutoCheck}, tests).
  #
  # @see TIMEx::Configuration#clock=
  # @see TIMEx::Test.with_virtual_clock
  module Clock

    NS_PER_SECOND = 1_000_000_000

    extend self

    # @return [Integer] monotonic time in nanoseconds from the active clock
    def monotonic_ns
      current.monotonic_ns
    end

    # @return [Integer] wall-clock time in nanoseconds from the active clock
    def wall_ns
      current.wall_ns
    end

    # @return [Float] monotonic time expressed in fractional seconds
    def now_seconds
      monotonic_ns / NS_PER_SECOND.to_f
    end

    # Returns the clock object consulted by {.monotonic_ns} and {.wall_ns}.
    #
    # @return [#monotonic_ns, #wall_ns] {RealClock}, {VirtualClock}, or a custom clock
    def current
      Thread.current.thread_variable_get(:timex_clock) || TIMEx.config.clock || RealClock
    end

    # Binds +clock+ for the duration of the block on the current thread.
    #
    # @param clock [#monotonic_ns, #wall_ns] clock implementation to install
    # @yield runs with the thread-local clock swapped
    # @return [Object] the block's return value
    def with(clock)
      previous = Thread.current.thread_variable_get(:timex_clock)
      Thread.current.thread_variable_set(:timex_clock, clock)
      yield
    ensure
      Thread.current.thread_variable_set(:timex_clock, previous)
    end

    # Default clock backed by the process monotonic and realtime clocks.
    module RealClock

      extend self

      # @return [Integer] nanoseconds from +CLOCK_MONOTONIC+
      def monotonic_ns
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      end

      # @return [Integer] nanoseconds from +CLOCK_REALTIME+
      def wall_ns
        Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      end

      # Sleeps the OS scheduler for up to +seconds+ (no-op when non-positive).
      #
      # @param seconds [Numeric] duration in seconds
      # @return [void]
      def sleep(seconds)
        Kernel.sleep(seconds) if seconds.positive?
      end

    end

    # Mutable monotonic/wall pair used in tests to advance time without sleeping.
    class VirtualClock

      attr_accessor :monotonic_ns, :wall_ns

      # @param monotonic_ns [Integer] starting monotonic nanoseconds
      # @param wall_ns [Integer] starting wall nanoseconds (defaults to realtime now)
      def initialize(monotonic_ns: 0, wall_ns: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond))
        @monotonic_ns = monotonic_ns
        @wall_ns = wall_ns
      end

      # Advances both monotonic and wall by +seconds+ (no sleep).
      #
      # @param seconds [Numeric] delta in seconds
      # @return [self] for chaining
      def advance(seconds)
        delta = (seconds * Clock::NS_PER_SECOND).to_i
        @monotonic_ns += delta
        @wall_ns += delta
        self
      end

      # @param seconds [Numeric] virtual sleep; advances clocks like {.advance}
      # @return [self] for chaining
      def sleep(seconds)
        advance(seconds)
      end

    end

  end
end
