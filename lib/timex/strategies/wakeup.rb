# frozen_string_literal: true

module TIMEx
  module Strategies
    # Pipe-based wakeup primitive: blocked I/O on {#read_io} unblocks when the
    # deadline fires (or {#cancel!} is called), and the {CancellationToken}
    # transitions to {#fired?}. Use to wake threads blocked in +IO.select+ on
    # resources without native deadlines.
    #
    # Each instance is **single-use**: the pipe is created lazily and closed in
    # +ensure+ after {#run}. Construct a fresh instance per operation.
    #
    # @note Accessing {#read_io} / {#write_io} before {#arm} without a constructor
    #   deadline creates the pipe but does **not** install a timer; the read end
    #   blocks until {#cancel!} unless you pass a deadline to {#initialize} or call {#arm}.
    #
    # @see CancellationToken
    # @see Base
    class Wakeup < Base

      attr_reader :token

      # @param deadline [Deadline, Numeric, Time, nil] when given, calls {#arm} immediately
      def initialize(deadline = nil)
        super()
        @token = CancellationToken.new
        @read_io = nil
        @write_io = nil
        @timer = nil
        @closed = false
        @io_mutex = Mutex.new
        arm(deadline) if deadline
      end

      # @return [::IO] readable end of the wakeup pipe (creates the pipe lazily)
      def read_io
        ensure_pipe
        @read_io
      end

      # @return [::IO] writable end used internally to signal readiness
      def write_io
        ensure_pipe
        @write_io
      end

      # @return [Boolean] +true+ after {#close}
      def closed?
        @io_mutex.synchronize { @closed }
      end

      # Arms a background timer that invokes {#cancel!} with +:timeout+ when the
      # deadline elapses.
      #
      # @param deadline [Deadline, Numeric, Time, nil]
      # @return [void]
      # @raise [TIMEx::Error] when the instance was already closed
      def arm(deadline)
        raise TIMEx::Error, "Wakeup is single-use; construct a fresh instance" if closed?

        deadline = Deadline.coerce(deadline)
        return if deadline.infinite?

        ensure_pipe
        @timer = Thread.new do
          remaining = deadline.remaining
          ::Kernel.sleep(remaining) if remaining.positive?
          fire(reason: :timeout)
        end
      end

      # Cancels observers and wakes blocked readers.
      #
      # @param reason [Symbol] opaque reason forwarded to {CancellationToken#cancel}
      # @return [Boolean, nil] result of the internal fire sequence
      def cancel!(reason: :user)
        fire(reason:)
      end

      # @return [Boolean] whether {#cancel!} / timeout has fired
      def fired?
        @token.cancelled?
      end

      # Idempotently closes pipe ends and stops the timer thread.
      #
      # @return [void]
      def close
        @timer&.kill
        @io_mutex.synchronize do
          return if @closed

          @read_io.close if @read_io && !@read_io.closed?
          @write_io.close if @write_io && !@write_io.closed?
          @closed = true
        end
      end

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object]
      # @raise [TIMEx::Error] when reused after {#close}
      def run(deadline)
        raise TIMEx::Error, "Wakeup is single-use; construct a fresh instance" if closed?

        arm(deadline) unless @timer
        yield(deadline)
      ensure
        close
      end

      private

      # @return [void]
      def ensure_pipe
        @io_mutex.synchronize do
          raise TIMEx::Error, "Wakeup is single-use; construct a fresh instance" if @closed
          return if @read_io

          @read_io, @write_io = ::IO.pipe
        end
      end

      # @param reason [Symbol]
      # @return [void]
      def fire(reason:)
        return unless @token.cancel(reason:)

        # Kill the sleeping timer if we were the first to win the race so the
        # thread doesn't dangle in `Kernel.sleep` and write to a closed pipe.
        if @timer && reason != :timeout && @timer.alive?
          begin
            @timer.kill
          rescue StandardError
            nil
          end
        end

        return unless @write_io

        begin
          @write_io.write_nonblock("!")
        rescue StandardError
          nil
        end
      end

    end
  end
end

TIMEx::Registry.register(:wakeup, TIMEx::Strategies::Wakeup)
