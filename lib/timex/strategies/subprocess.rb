# frozen_string_literal: true

module TIMEx
  module Strategies
    # Runs user code in a forked child and returns the marshalled result to the parent.
    #
    # @note The child inherits all open file descriptors; shared connections can
    #   corrupt the parent if reused in the child. Re-open resources in the child
    #   or close inherited FDs deliberately.
    #
    # @see Base
    class Subprocess < Base

      # Message used when the child exits without producing a marshalled result
      # (segfault, OOM, exec, etc.) so the parent can distinguish from a
      # legitimate `[:ok, nil]` return.
      EMPTY_PAYLOAD = "the child exited without producing a result"

      # Default ceiling on the marshalled child payload. A buggy or malicious
      # block can otherwise drive the parent OOM by streaming arbitrary data
      # through the pipe before the deadline fires.
      DEFAULT_MAX_PAYLOAD_BYTES = 8 * 1024 * 1024

      # @param kill_after [Numeric] seconds to wait after TERM before KILL when reaping
      # @param max_payload_bytes [Integer] hard cap on bytes read from the result pipe
      # @raise [ArgumentError] when parameters are out of range
      def initialize(kill_after: 0.5, max_payload_bytes: DEFAULT_MAX_PAYLOAD_BYTES)
        super()
        raise ArgumentError, "kill_after must be a non-negative Numeric" unless kill_after.is_a?(Numeric) && !kill_after.negative?
        raise ArgumentError, "max_payload_bytes must be a positive Integer" unless max_payload_bytes.is_a?(Integer) && max_payload_bytes.positive?

        @kill_after = kill_after
        @max_payload_bytes = max_payload_bytes
      end

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object] unmarshalled child return value
      # @raise [TIMEx::Error] when +fork+ is unavailable
      # @raise [Expired] when the parent budget expires waiting for the child
      # @raise [Exception] when the child marshals +[:error, exception]+
      def run(deadline)
        raise TIMEx::Error, "Subprocess strategy requires fork (unavailable on this platform)" unless ::Process.respond_to?(:fork)

        reader, writer = ::IO.pipe
        # Mark pipe FDs close-on-exec so they are not inherited by unrelated
        # programs started via `Process.spawn`/`exec` from this process. The
        # parent and this fork still share the pipe by design (child closes
        # reader, parent closes writer); `Marshal.load` reads only from our
        # child, not from arbitrary inherited writers.
        reader.close_on_exec = true
        writer.close_on_exec = true
        pid = begin
          ::Process.fork do
            reader.close
            # If `setpgid` raises in the child we MUST NOT proceed: the child's
            # pgid is still equal to the parent's, and `kill(-pid)` from the
            # parent would target the parent's process group. Bail out rather
            # than risk wiping the parent.
            begin
              ::Process.setpgid(0, 0) if ::Process.respond_to?(:setpgid)
            rescue StandardError
              ::Kernel.exit!(1)
            end
            run_child(writer, deadline) { yield(deadline) }
          end
        ensure
          writer.close unless writer.closed?
        end

        # Race-free pgid setup: the child also calls setpgid(0, 0), but until
        # that lands the child's pgid is the parent's. Setting it from the
        # parent and confirming success closes the window during which
        # `terminate(-pid)` would silently miss its target (or hit the
        # parent's group). We carry the outcome into terminate/reap so a
        # failed setpgid never leads to `kill(-pid)`.
        pgid_established = false
        if ::Process.respond_to?(:setpgid)
          begin
            ::Process.setpgid(pid, pid)
            pgid_established = true
          rescue Errno::EACCES
            pgid_established = true # child already setpgid'd itself
          rescue Errno::ESRCH, StandardError
            pgid_established = false
          end
        end

        completed = false
        begin
          value = wait_for_child(pid, reader, deadline, pgid_established:)
          completed = true
          value
        ensure
          reader.close unless reader.closed?
          reap_async(pid, pgid_established:) unless completed
        end
      end

      private

      def run_child(writer, deadline)
        value = yield
        ::Marshal.dump([:ok, value], writer)
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Forward every exception (including {Expired}, +SystemExit+,
        # +SignalException+, etc.) as `[:error, e]` so the parent can
        # `rescue TIMEx::Expired` directly and observe the original
        # strategy/deadline_ms metadata. `safe_dump` falls back to a plain
        # RuntimeError if a particular exception class can't be marshalled.
        safe_dump(writer, [:error, e])
      ensure
        writer.close unless writer.closed?
        ::Kernel.exit!(0)
      end

      def safe_dump(writer, payload)
        ::Marshal.dump(payload, writer)
      rescue StandardError
        fallback_dump(writer, payload)
      end

      def fallback_dump(writer, payload)
        kind, value = payload
        ::Marshal.dump([kind, RuntimeError.new(value.message)], writer)
      rescue StandardError
        nil
      end

      def wait_for_child(pid, reader, deadline, pgid_established: false)
        deadline_remaining = deadline.infinite? ? nil : deadline.remaining
        ready = ::IO.select([reader], nil, nil, deadline_remaining) # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler

        if ready.nil?
          reap_async(pid, pgid_established:)
          raise deadline.expired_error(
            strategy: :subprocess,
            message: "subprocess deadline expired"
          )
        end

        data    = drain_reader(reader, deadline)
        expired = deadline.expired?
        # Reap synchronously only if we still have budget; otherwise hand off
        # to `reap_async`. `safe_waitpid` swallows ECHILD so a concurrent
        # signal handler (or the reaper raced with our drain) cannot crash
        # the parent here.
        expired ? reap_async(pid, pgid_established:) : safe_waitpid(pid, 0)

        if data.nil? || data.empty?
          # A child reaped before flushing typically means the deadline reaper
          # killed it. Prefer Expired so callers can rescue it consistently.
          if expired
            raise deadline.expired_error(
              strategy: :subprocess,
              message: "subprocess deadline expired (no payload)"
            )
          end

          raise TIMEx::Error, EMPTY_PAYLOAD
        end

        kind, value = begin
          ::Marshal.load(data) # rubocop:disable Security/MarshalLoad
        rescue ArgumentError, TypeError => e
          # A truncated payload typically means the child was killed mid-write
          # by our deadline reaper. Surface that as Expired rather than a
          # generic Error so callers can rescue it consistently.
          if expired
            raise deadline.expired_error(
              strategy: :subprocess,
              message: "subprocess deadline expired (truncated payload)"
            )
          end

          raise TIMEx::Error, "subprocess produced unreadable payload (#{e.class}: #{e.message})"
        end
        kind == :ok ? value : raise(value)
      end

      # Reads remaining bytes from `reader` without blocking past the parent
      # deadline. If the child wrote a partial payload then crashed mid-cleanup,
      # `reader.read` (blocking) could hang forever; loop on `read_nonblock`
      # bounded by `deadline.remaining` instead. Caps the buffer at
      # `@max_payload_bytes` so a runaway child cannot OOM the parent.
      def drain_reader(reader, deadline)
        buf = +""
        cap = @max_payload_bytes
        loop do
          chunk = reader.read_nonblock(4096, exception: false)
          case chunk
          when :wait_readable
            remaining = deadline.infinite? ? nil : [deadline.remaining, 0.0].max
            return buf if remaining && remaining <= 0
            return buf unless reader.wait_readable(remaining)
          when nil # EOF
            return buf
          else
            buf << chunk
            raise TIMEx::Error, "subprocess payload exceeded #{cap} bytes" if buf.bytesize > cap
          end
        end
      end

      def terminate(pid, pgid_established: false)
        signal_target = pgid_established ? -pid : pid
        kill_signal(signal_target, "TERM")
        wait_or_kill(pid, signal_target)
      end

      # Off-thread reaper so the request thread isn't blocked by `kill_after +
      # waitpid`. We deliberately do NOT call `Process.detach` here: detaching
      # lets the kernel reap the zombie as soon as it exits, freeing the PID
      # for reuse. A subsequent `kill(KILL, pid)` could then signal an
      # unrelated freshly-spawned process owned by the same uid. By owning
      # `waitpid` ourselves we keep the zombie around until *we've* observed
      # it, so the PID cannot be recycled out from under us.
      def reap_async(pid, pgid_established: false)
        signal_target = pgid_established ? -pid : pid
        kill_signal(signal_target, "TERM")
        Thread.new { wait_or_kill(pid, signal_target) }
        nil
      end

      # Polls for the child's exit using `WNOHANG`; if it doesn't drain within
      # `@kill_after`, escalates to `KILL` and waits synchronously. Either way
      # we always own the final `waitpid`, so the PID cannot be recycled while
      # we still hold a reference to it.
      def wait_or_kill(pid, signal_target)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + @kill_after
        loop do
          reaped = safe_waitpid(pid, ::Process::WNOHANG)
          return if reaped == pid

          break if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        end
        kill_signal(signal_target, "KILL")
        safe_waitpid(pid, 0)
      end

      def safe_waitpid(pid, flags)
        ::Process.waitpid(pid, flags)
      rescue Errno::ECHILD, Errno::ESRCH
        pid # treat "already gone" as reaped so callers stop signalling
      rescue StandardError
        nil
      end

      def kill_signal(target, signal)
        ::Process.kill(signal, target)
      rescue StandardError
        # ESRCH: target already exited. EPERM: target was reaped + the PID
        # got handed to another uid before we got here (the very situation
        # `wait_or_kill` exists to prevent, but we still don't want to crash
        # the request thread). All other Errno::* swallowed for parity.
        nil
      end

    end
  end
end

TIMEx::Registry.register(:subprocess, TIMEx::Strategies::Subprocess)
