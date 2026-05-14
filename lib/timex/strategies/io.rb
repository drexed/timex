# frozen_string_literal: true

require "socket"
require "io/wait"
require "resolv"

module TIMEx
  module Strategies
    # Deadline-aware helpers for non-blocking socket I/O and DNS resolution.
    #
    # The nested singleton methods implement reusable primitives; {#run} simply
    # yields the {Deadline} to the caller for custom protocols.
    #
    # @see Base
    class IO < Base

      # Minimum seconds passed to SO_RCVTIMEO / SO_SNDTIMEO. A packed timeval
      # of zero often means "disable timeout" on POSIX, which would leave
      # blocking reads unbounded when the remaining budget rounds to 0.
      MIN_SOCKET_TIMEOUT = 0.001

      class << self

        # Reads up to +len+ bytes using non-blocking reads bounded by +deadline+.
        #
        # @param io [::IO]
        # @param len [Integer] maximum bytes to read
        # @param deadline [Deadline, Numeric, Time, nil]
        # @return [String] data read (may be shorter than +len+)
        # @raise [Expired] when the wait exhausts the budget
        def read(io, len, deadline:)
          deadline = Deadline.coerce(deadline)
          loop do
            return io.read_nonblock(len)
          rescue ::IO::WaitReadable
            wait_for(io, :read, deadline)
          end
        end

        # Writes the full +buffer+, retrying on +IO::WaitWritable+ until done or expired.
        #
        # @param io [::IO]
        # @param buffer [String]
        # @param deadline [Deadline, Numeric, Time, nil]
        # @return [Integer] total bytes written
        # @raise [Expired] when the wait exhausts the budget
        # @raise [IOError] when +write_nonblock+ reports zero progress
        def write(io, buffer, deadline:)
          deadline = Deadline.coerce(deadline)
          total    = buffer.bytesize
          offset   = 0
          while offset < total
            begin
              # Avoid the per-iteration `byteslice` alloc on the common path
              # where we write the whole buffer in one go; only slice once we
              # know the kernel took a partial write.
              chunk = offset.zero? ? buffer : buffer.byteslice(offset, total - offset)
              n     = io.write_nonblock(chunk)
              raise ::IOError, "write_nonblock returned 0 bytes (no progress)" if n.zero?

              offset += n
            rescue ::IO::WaitWritable
              wait_for(io, :write, deadline)
            end
          end
          total
        end

        # Resolves +host+ (respecting +deadline+) and connects via the first
        # working address family. Avoids +getaddrinfo+ blocking past the
        # deadline by delegating to +Resolv+ with the remaining time.
        #
        # The returned socket also has SO_{RCV,SND}TIMEO applied to the
        # remaining deadline so that subsequent blocking reads don't outlive
        # the budget if the caller forgets to use {.read} / {.write}. Use
        # +apply_timeouts: false+ to opt out.
        #
        # @param host [String]
        # @param port [Integer]
        # @param deadline [Deadline, Numeric, Time, nil]
        # @param apply_timeouts [Boolean] when +true+, sets socket read/write timeouts
        # @return [::Socket] connected stream socket
        # @raise [SocketError] when resolution yields no addresses
        # @raise [Expired] when resolution or connect exceeds the deadline
        def connect(host, port, deadline:, apply_timeouts: true)
          deadline  = Deadline.coerce(deadline)
          addresses = resolve_host(host, deadline)
          raise ::SocketError, "could not resolve #{host}" if addresses.empty?

          last_error = nil
          addresses.each do |addr|
            sock = open_socket(addr, port, deadline)
            apply_socket_timeouts(sock, deadline:) if apply_timeouts
            return sock
          rescue Expired
            raise
          rescue StandardError => e
            last_error = e
            next
          end
          raise last_error || Errno::ECONNREFUSED.new("could not connect to #{host}:#{port}")
        end

        # Best-effort SO_{RCV,SND}TIMEO setter. The native +pack+ format for
        # +struct timeval+ differs by platform (64-bit POSIX uses two +long+
        # fields; Windows uses +DWORD+ milliseconds). When +SO_RCVTIMEO_FLOAT+
        # is exposed (Darwin, some BSDs) we prefer it because the option's
        # value is a raw +Float+, avoiding the packed-timeval mismatch.
        # Failures are swallowed so callers can rely on +wait_for+ as the
        # primary deadline guard.
        #
        # @param sock [::Socket]
        # @param deadline [Deadline, Numeric, Time, nil]
        # @return [void]
        def apply_socket_timeouts(sock, deadline:)
          deadline = Deadline.coerce(deadline)
          return if deadline.infinite?

          remaining = deadline.remaining
          return if remaining <= 0

          remaining = [remaining, MIN_SOCKET_TIMEOUT].max
          if ::Socket.const_defined?(:SO_RCVTIMEO_FLOAT) && ::Socket.const_defined?(:SO_SNDTIMEO_FLOAT)
            sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO_FLOAT, remaining)
            sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDTIMEO_FLOAT, remaining)
          else
            tv = pack_timeval(remaining)
            sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO, tv)
            sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_SNDTIMEO, tv)
          end
        rescue StandardError
          nil
        end

        private

        # @param seconds [Numeric]
        # @return [String] packed timeval or Windows DWORD milliseconds
        def pack_timeval(seconds)
          secs  = seconds.to_i
          usecs = ((seconds - secs) * 1_000_000).to_i
          if ::RUBY_PLATFORM.match?(/mswin|mingw|cygwin/)
            [(seconds * 1000).to_i].pack("L") # Windows: DWORD ms
          else
            [secs, usecs].pack("l_l_")        # POSIX: struct timeval { long, long }
          end
        end

        # Resolves +host+ with a per-call +Resolv::DNS+ configured with the
        # remaining deadline as its per-query timeout. We deliberately do NOT
        # share the +Resolv::DNS+ instance across threads: +dns.timeouts=+
        # mutates state, so two concurrent callers with different budgets
        # would race on the setter and one would observe the other's timeout.
        # +Resolv::DNS.new+ is cheap (a config parse + UDP socket on first
        # query); per-call construction also sidesteps the post-fork
        # FD-sharing problem entirely.
        #
        # @param host [String]
        # @param deadline [Deadline]
        # @return [Array<Array(Integer, String)>>] list of +[family, ip]+ tuples
        def resolve_host(host, deadline)
          if literal_ip?(host)
            family = host.include?(":") ? ::Socket::AF_INET6 : ::Socket::AF_INET
            return [[family, host]]
          end

          remaining = deadline.infinite? ? nil : deadline.remaining
          raise deadline.expired_error(strategy: :io, message: "DNS deadline expired") if remaining && remaining <= 0

          dns = ::Resolv::DNS.new
          dns.timeouts = [remaining] if remaining
          begin
            resolver = ::Resolv.new([::Resolv::Hosts.new, dns])
            resolver.getaddresses(host).map do |ip|
              [ip.include?(":") ? ::Socket::AF_INET6 : ::Socket::AF_INET, ip]
            end
          ensure
            dns.close if dns.respond_to?(:close)
          end
        rescue ::Resolv::ResolvError, ::Resolv::ResolvTimeout
          raise deadline.expired_error(strategy: :io, message: "DNS deadline expired") if remaining && deadline.expired?

          []
        end

        # @param host [String]
        # @return [Boolean]
        def literal_ip?(host)
          host.match?(::Resolv::IPv4::Regex) || host.match?(::Resolv::IPv6::Regex)
        end

        # @param addr [Array(Integer, String)] +[family, ip]+
        # @param port [Integer]
        # @param deadline [Deadline]
        # @return [::Socket]
        def open_socket(addr, port, deadline)
          family, ip = addr
          sock     = ::Socket.new(family, ::Socket::SOCK_STREAM, 0)
          sockaddr = ::Socket.sockaddr_in(port, ip)
          begin
            sock.connect_nonblock(sockaddr)
          rescue ::IO::WaitWritable
            wait_for(sock, :write, deadline)
            begin
              sock.connect_nonblock(sockaddr)
            rescue Errno::EISCONN
              # connected
            end
          end
          sock
        rescue StandardError
          sock&.close
          raise
        end

        # @param io [::IO]
        # @param direction [:read, :write]
        # @param deadline [Deadline]
        # @return [void]
        # @raise [Expired] when not ready before expiry
        def wait_for(io, direction, deadline)
          remaining = deadline.remaining
          remaining = nil if deadline.infinite?
          raise deadline.expired_error(strategy: :io, message: "IO #{direction} deadline expired") if remaining && remaining <= 0

          ready = direction == :read ? io.wait_readable(remaining) : io.wait_writable(remaining)
          return if ready

          raise deadline.expired_error(strategy: :io, message: "IO #{direction} deadline expired")
        end

      end

      protected

      # @param deadline [Deadline]
      # @yieldparam deadline [Deadline]
      # @return [Object]
      def run(deadline)
        yield(deadline)
      end

    end
  end
end

TIMEx::Registry.register(:io, TIMEx::Strategies::IO)
