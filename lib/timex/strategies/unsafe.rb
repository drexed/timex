# frozen_string_literal: true

module TIMEx
  module Strategies
    # Watchdog thread that raises {Expired} into the caller via +Thread#raise+
    # after the deadline. **Unsafe**: does not stop CPU work; can leave shared
    # state inconsistent if the block is not written for asynchronous exceptions.
    #
    # @note Prefer {Cooperative}, {IO}, {Closeable}, or {Subprocess} unless you
    #   explicitly accept these semantics.
    #
    # @see Base
    class Unsafe < Base

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object]
      # @raise [Expired] from the watcher thread when time elapses before completion
      def run(deadline)
        return yield(deadline) if deadline.infinite?

        target = Thread.current
        state  = { block_done: false, mutex: Mutex.new }
        watcher = Thread.new do
          remaining = deadline.remaining
          ::Kernel.sleep(remaining) if remaining.positive?
          state[:mutex].synchronize do
            next if state[:block_done]
            next unless target.alive?

            target.raise(
              deadline.expired_error(
                strategy: :unsafe,
                message: "unsafe deadline expired"
              )
            )
          end
        end
        begin
          yield(deadline)
        ensure
          state[:mutex].synchronize { state[:block_done] = true }
          watcher.kill if watcher.alive?
          watcher.join(0.1)
        end
      end

    end
  end
end

TIMEx::Registry.register(:unsafe, TIMEx::Strategies::Unsafe)
