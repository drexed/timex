# frozen_string_literal: true

module TIMEx
  module Strategies
    # Invokes +close_method+ on a watchdog thread after the deadline so blocking
    # I/O surfaces as +IOError+ / +EBADF+ / +EPIPE+ (etc.), then maps those to
    # {Expired} when the close was timer-driven.
    #
    # @note +close_method+ runs **concurrently** with the user block. It must be
    #   safe to call while the block uses the resource; avoid mutual deadlocks on
    #   the same mutex.
    #
    # @see Base
    class Closeable < Base

      # @param resource [Object] object receiving +close_method+
      # @param close_method [Symbol] method name invoked to unblock I/O
      def initialize(resource:, close_method: :close)
        super()
        @resource     = resource
        @close_method = close_method
      end

      protected

      # @param deadline [Deadline]
      # @yieldparam resource [Object] the configured resource
      # @yieldparam deadline [Deadline]
      # @return [Object]
      # @raise [Expired] when I/O errors follow a timer-driven close
      def run(deadline)
        return yield(@resource, deadline) if deadline.infinite?

        state = { closed_by_timer: false, block_done: false, mutex: Mutex.new }
        timer = Thread.new do
          remaining = deadline.remaining
          ::Kernel.sleep(remaining) if remaining.positive?
          # We claim the right to close under the mutex, but invoke
          # `close_method` OUTSIDE it. A blocking `close` implementation
          # would otherwise hold the mutex while the user's block reaches
          # its ensure clause (which also acquires the mutex), causing
          # deadlock.
          should_close = state[:mutex].synchronize do
            next false if state[:block_done]

            state[:closed_by_timer] = true
            true
          end
          if should_close
            begin
              @resource.public_send(@close_method)
            rescue StandardError
              nil
            end
          end
        end
        begin
          yield(@resource, deadline)
        rescue IOError,
               Errno::EBADF, Errno::EPIPE, Errno::ECONNRESET,
               Errno::ENOTCONN, Errno::ESHUTDOWN => e
          raise unless state[:closed_by_timer]

          raise deadline.expired_error(
            strategy: :closeable,
            message: "closeable deadline expired (#{e.class})"
          )
        ensure
          state[:mutex].synchronize { state[:block_done] = true }
          if timer.alive?
            timer.kill
            timer.join(0.1)
          end
        end
      end

    end
  end
end

TIMEx::Registry.register(:closeable, TIMEx::Strategies::Closeable)
