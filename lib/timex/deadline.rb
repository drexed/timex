# frozen_string_literal: true

require "time"

module TIMEx

  # Immutable deadline: an absolute monotonic expiry (+monotonic_ns+), optional
  # wall alignment (+wall_ns+), and propagation metadata (+origin+, +depth+).
  #
  # Construct via {.in}, {.at_wall}, {.infinite}, {.coerce}, or {.from_header};
  # compare and narrow with {#min}. Instances are frozen at construction.
  #
  # @see Clock
  # @see Expired
  class Deadline

    HEADER_NAME = "X-TIMEx-Deadline"
    DEFAULT_SKEW_TOLERANCE_MS = 250
    MAX_HEADER_BYTESIZE = 256
    MAX_MS_VALUE = 365 * 24 * 60 * 60 * 1000 # 1 year, prevents overflow attacks
    # Upper bound for {.in} in seconds, aligned with {MAX_MS_VALUE} / 1000 so
    # numeric budgets cannot exceed what untrusted headers can express.
    MAX_BUDGET_SECONDS = MAX_MS_VALUE / 1000.0
    MAX_DEPTH = 64
    ORIGIN_MAX_BYTESIZE = 64
    ORIGIN_PATTERN = /\A[A-Za-z0-9_.-]+\z/
    # Tight cap on iso8601 timestamp length to bound the cost of Rational
    # math in `check_wall_skew`. A canonical TIMEx-emitted stamp is 24 chars
    # (`YYYY-MM-DDTHH:MM:SS.sssZ`); 40 leaves room for offset variants.
    MAX_ISO8601_BYTESIZE = 40

    class << self

      # Builds a relative deadline from now using the active {Clock}.
      #
      # @param seconds [Numeric, nil] duration in seconds; +nil+ means {.infinite}
      # @return [Deadline] finite deadline, or {.infinite} when out of range / non-finite
      def in(seconds)
        return infinite if seconds.nil?

        if seconds.is_a?(Numeric)
          return demoted_to_infinite(seconds, reason: :non_finite) if seconds.respond_to?(:finite?) && !seconds.finite?
          return demoted_to_infinite(seconds, reason: :over_max_budget) if seconds > MAX_BUDGET_SECONDS
        end

        product = seconds * Clock::NS_PER_SECOND
        return demoted_to_infinite(seconds, reason: :float_overflow) if product.is_a?(Float) && !product.finite?

        delta_ns = product.to_i
        new(
          monotonic_ns: Clock.monotonic_ns + delta_ns,
          wall_ns: Clock.wall_ns + delta_ns,
          initial_ns: delta_ns
        )
      end

      # Builds a deadline that expires when wall clock reaches +time+ (nanosecond precision).
      #
      # @param time [Time] target wall time (uses +tv_sec+ / +tv_nsec+)
      # @return [Deadline]
      def at_wall(time)
        wall_now = Clock.wall_ns
        target_wall = (time.tv_sec * Clock::NS_PER_SECOND) + time.tv_nsec
        delta = target_wall - wall_now
        new(
          monotonic_ns: Clock.monotonic_ns + delta,
          wall_ns: target_wall,
          initial_ns: delta
        )
      end

      # @return [Deadline] shared infinite sentinel ({INFINITE})
      def infinite
        INFINITE
      end

      # Normalizes user input into a {Deadline}.
      #
      # @param value [Deadline, Numeric, Time, nil, Object] existing deadline, seconds, wall +Time+, +nil+ for infinite, etc.
      # @return [Deadline]
      # @raise [ArgumentError] when +value+ cannot be interpreted (e.g. bare Symbol)
      def coerce(value)
        case value
        when Deadline then value
        when Numeric then self.in(value)
        when Time then at_wall(value)
        when nil then infinite
        when Symbol
          raise ArgumentError, "cannot coerce #{value.inspect} into a Deadline " \
                               "(did you mean strategy: #{value.inspect}?)"
        else
          raise ArgumentError, "cannot coerce #{value.inspect} into a Deadline"
        end
      end

      # Parses the wire-format deadline header into a {Deadline}, or +nil+ when
      # malformed, oversized, ambiguous, or rejected for security policy.
      #
      # @param str [String, nil] raw header value (see {HEADER_NAME})
      # @param skew_tolerance_ms [Numeric, nil] override; defaults to {TIMEx.config}
      # @return [Deadline, nil] parsed deadline, or +nil+ on any validation failure
      #
      # @note Rejects combined +ms+ and +wall+ fields, duplicate keys, negative depth,
      #   and oversized payloads. Skew detection emits telemetry but does not mutate
      #   the parsed deadline.
      def from_header(str, skew_tolerance_ms: nil)
        skew_tolerance_ms ||= TIMEx.config.skew_tolerance_ms
        return nil if str.nil? || str.empty? || str.bytesize > MAX_HEADER_BYTESIZE

        parts = parse_header_pairs(str)
        return nil if parts.nil? || parts.empty?

        # Reject ambiguous payloads up front: an attacker who can append to a
        # trusted upstream's header could otherwise smuggle `ms=99999` next to
        # `wall=` to extend the budget, or supply both and rely on parser
        # precedence. Either is a single, well-defined field.
        return nil if parts.key?("ms") && parts.key?("wall")

        depth = parts["depth"] && Integer(parts["depth"], 10, exception: false)
        # Reject explicitly negative depth so client bugs don't silently coerce
        # to 0 and bypass `max_depth` ceilings on the receiver.
        return nil if depth&.negative?

        depth = depth.clamp(0, MAX_DEPTH) if depth
        origin = sanitize_origin(parts["origin"])

        if parts.key?("ms")
          ms = parts["ms"]
          # Even for `ms=inf` we attach origin/depth so middleware can enforce
          # `max_depth` on infinite-budget propagations. Returning the shared
          # sentinel here would drop those, allowing depth-limit bypass.
          if ms == "inf"
            return infinite if origin.nil? && depth.nil?

            return new(
              monotonic_ns: Float::INFINITY,
              wall_ns: nil,
              origin:,
              depth: depth || 0,
              infinite: true
            )
          end

          ms_value = Float(ms, exception: false)
          return nil if ms_value.nil? || !ms_value.finite? || ms_value.negative? || ms_value > MAX_MS_VALUE

          self.in(ms_value / 1000.0).with_meta(origin:, depth:)
        elsif parts.key?("wall")
          wall_raw = parts["wall"]
          return nil if wall_raw.bytesize > MAX_ISO8601_BYTESIZE

          wall_time = Time.iso8601(wall_raw)
          d = at_wall(wall_time)
          check_wall_skew(d, parts, skew_tolerance_ms)
          d.with_meta(origin:, depth:)
        end
      rescue ArgumentError, TypeError, RangeError
        nil
      end

      private

      # Returns `nil` on duplicate keys so smuggled values like
      # `ms=10;ms=99999` are rejected outright instead of silently
      # last-write-wins.
      def parse_header_pairs(str)
        acc = {}
        str.split(";").each do |kv|
          k, v = kv.strip.split("=", 2)
          next if k.nil? || k.empty? || v.nil?

          return nil if acc.key?(k)

          acc[k] = v
        end
        acc
      end

      def demoted_to_infinite(seconds, reason:)
        TIMEx::Telemetry.emit(
          event: "deadline.budget_clamped",
          reason:,
          requested_seconds: seconds.is_a?(Float) ? seconds : seconds.to_f
        )
        infinite
      end

      def sanitize_origin(value)
        return nil if value.nil? || value.empty?
        return nil if value.bytesize > ORIGIN_MAX_BYTESIZE
        return nil unless ORIGIN_PATTERN.match?(value)

        value
      end

      # Compares the upstream's "issued at" timestamp (`now`) against the local
      # wall clock to detect cross-host clock drift. Without `now=` no real
      # skew can be computed, so the guard is a no-op. This emits a telemetry
      # event but does NOT modify the deadline; clamping a propagated wall
      # deadline based on local clock drift would silently extend or shrink
      # the upstream's contract. Operators should react via the telemetry
      # signal (e.g. fix NTP) instead.
      def check_wall_skew(deadline, parts, skew_tolerance_ms)
        now_raw = parts["now"]
        return unless now_raw
        return if now_raw.bytesize > MAX_ISO8601_BYTESIZE

        # Avoid `Time#to_r * NS_PER_SECOND`: `Rational` allocations dominate
        # this hot path. `tv_sec`/`tv_nsec` give us nanosecond precision
        # without arbitrary-precision math.
        t = Time.iso8601(now_raw)
        upstream_now_ns = (t.tv_sec * Clock::NS_PER_SECOND) + t.tv_nsec
        skew_ms = ((Clock.wall_ns - upstream_now_ns).abs / 1_000_000.0)
        return unless skew_ms > skew_tolerance_ms && deadline.remaining.positive?

        TIMEx::Telemetry.emit(
          event: "deadline.skew_detected",
          skew_ms:,
          origin: parts["origin"]
        )
      rescue ArgumentError
        nil
      end

    end

    # Eagerly initialized after the class is defined (see bottom of file) so
    # concurrent first-callers can't race to construct two distinct sentinels.
    INFINITE = nil # placeholder; overwritten below

    attr_reader :monotonic_ns, :wall_ns, :origin, :depth, :initial_ns

    # Creates a frozen deadline. Callers typically use {.in}, {.at_wall}, or {.infinite}.
    #
    # @param monotonic_ns [Integer, Float] absolute monotonic ns at expiration
    # @param wall_ns [Integer, nil] absolute wall ns at expiration
    # @param origin [String, nil] human-readable identifier (already sanitized)
    # @param depth [Integer, nil] propagation hop count (0 .. {MAX_DEPTH})
    # @param infinite [Boolean] true only for the {.infinite} sentinel
    # @param initial_ns [Integer, Float, nil] original budget in nanoseconds at
    #   construction time. Captured so {Expired#deadline_ms} can report the
    #   *budget* (positive, stable) rather than ad-hoc post-expiry math.
    # @return [void]
    #
    # @note The instance is frozen before returning to the caller.
    def initialize(monotonic_ns:, wall_ns: nil, origin: nil, depth: 0, infinite: false, initial_ns: nil) # rubocop:disable Metrics/ParameterLists
      @monotonic_ns = monotonic_ns
      @wall_ns = wall_ns
      @origin = origin
      @depth = depth || 0
      @infinite = infinite
      @initial_ns = initial_ns
      freeze
    end

    # Original budget in milliseconds, or +nil+ for infinite deadlines or when
    # no budget was captured at construction.
    #
    # @return [Float, nil] positive budget in ms when known
    def initial_ms
      return nil if infinite? || @initial_ns.nil?

      @initial_ns / 1_000_000.0
    end

    # Returns a copy with updated propagation metadata (+origin+, +depth+).
    #
    # @param origin [String, nil] new origin (sanitized); +nil+ keeps existing
    # @param depth [Integer, nil] new depth; +nil+ keeps existing
    # @return [Deadline] new frozen instance sharing the same expiry instants
    def with_meta(origin: nil, depth: nil)
      self.class.new(
        monotonic_ns: @monotonic_ns,
        wall_ns: @wall_ns,
        origin: (origin && self.class.send(:sanitize_origin, origin)) || @origin,
        depth: depth || @depth,
        infinite: @infinite,
        initial_ns: @initial_ns
      )
    end

    # @return [Boolean] +true+ when this deadline never fires
    def infinite?
      @infinite || @monotonic_ns == Float::INFINITY
    end

    # @return [Float, Integer] nanoseconds remaining before expiry; +Float::INFINITY+ when infinite
    def remaining_ns
      return Float::INFINITY if infinite?

      @monotonic_ns - Clock.monotonic_ns
    end

    # @return [Float] seconds remaining; +Float::INFINITY+ when infinite
    def remaining
      r = remaining_ns
      return Float::INFINITY if infinite_remaining_float?(r)

      r / Clock::NS_PER_SECOND.to_f
    end

    # @return [Float] milliseconds remaining; +Float::INFINITY+ when infinite
    def remaining_ms
      r = remaining_ns
      return Float::INFINITY if infinite_remaining_float?(r)

      r / 1_000_000.0
    end

    # @return [Boolean] +true+ when already past the monotonic expiry (never +true+ when infinite)
    #
    # @note Returns +false+ while {#shield} is active on the current thread.
    def expired?
      return false if infinite?
      return false if Thread.current.thread_variable_get(:timex_shielded)

      remaining_ns <= 0
    end

    # Raises {Expired} when {#expired?} on this thread.
    #
    # @param strategy [Symbol, nil] strategy name for telemetry-style metadata
    # @return [void]
    # @raise [Expired] when past deadline
    def check!(strategy: nil)
      return unless expired?

      raise expired_error(strategy:)
    end

    # Builds an {Expired} that consistently reports the *original* budget as
    # `deadline_ms` (positive) and the overshoot/elapsed-past as `elapsed_ms`.
    # Strategies should use this instead of constructing `Expired` ad-hoc to
    # keep `deadline_ms` semantics uniform across the codebase.
    #
    # @param strategy [Symbol, nil] strategy that caught the expiration
    # @param message [String] human-readable message
    # @return [Expired]
    def expired_error(strategy: nil, message: "deadline expired")
      remaining = remaining_ms
      overshoot =
        if infinite_remaining_float?(remaining)
          nil
        else
          (-remaining).round
        end
      Expired.new(
        message,
        strategy:,
        deadline_ms: initial_ms&.round,
        elapsed_ms: overshoot
      )
    end

    # Earliest-expiring of +self+ and +other+ (finite vs infinite handled).
    #
    # @param other [Deadline, Numeric, Time, nil] coerced via {.coerce}
    # @return [Deadline]
    def min(other)
      return self if other.nil?

      other = self.class.coerce(other)
      return other if infinite?
      return self if other.infinite?

      @monotonic_ns <= other.monotonic_ns ? self : other
    end

    # Temporarily disables {#expired?} for the current thread (all fibers).
    #
    # @yield work that must not observe expiry checks
    # @return [Object] the block's return value
    #
    # @note Child threads are not shielded; call {#shield} in each thread that
    #   should ignore expiry for nested work.
    def shield
      previous = Thread.current.thread_variable_get(:timex_shielded)
      Thread.current.thread_variable_set(:timex_shielded, true)
      yield
    ensure
      Thread.current.thread_variable_set(:timex_shielded, previous)
    end

    # Serializes this deadline for the +X-TIMEx-Deadline+ header.
    #
    # @param prefer [:remaining, :wall] emit +ms=+ remaining budget or +wall=+ absolute wall target
    # @return [String] wire form (no leading header name)
    def to_header(prefer: :remaining)
      buf = +""
      if infinite?
        buf << "ms=inf"
        # Bare `ms=inf` round-trips to the shared {Deadline.infinite} sentinel
        # (see {.from_header}). Append metadata only when present.
        if @origin || !@depth.zero?
          buf << ";origin=" << @origin if @origin
          buf << ";depth=" << (@depth + 1).clamp(0, MAX_DEPTH).to_s
        end
        return buf
      end
      if prefer == :wall && @wall_ns
        buf << "wall=" << ns_to_iso8601(@wall_ns)
        buf << ";now=" << ns_to_iso8601(Clock.wall_ns)
      else
        buf << "ms=" << remaining_ms.round.to_s
      end
      buf << ";origin=" << @origin if @origin
      buf << ";depth=" << (@depth + 1).clamp(0, MAX_DEPTH).to_s
      buf
    end

    # @param other [Object]
    # @return [Boolean] +true+ when monotonic instant, wall, and propagation metadata match
    #
    # @note Requires +wall_ns+ parity so {#to_header}+(+prefer: :wall+) cannot diverge for equal instances.
    def ==(other)
      other.is_a?(Deadline) &&
        other.monotonic_ns == monotonic_ns &&
        other.wall_ns == wall_ns &&
        other.origin == origin &&
        other.depth == depth
    end
    alias eql? ==

    # @return [Integer] hash of monotonic instant and metadata
    def hash
      [@monotonic_ns, @wall_ns, @origin, @depth].hash
    end

    # @param other [Object]
    # @return [Boolean] +true+ when +other+ is a {Deadline} with the same monotonic expiry
    def same_instant?(other)
      other.is_a?(Deadline) && other.monotonic_ns == monotonic_ns
    end

    # @return [String] short debug representation
    def inspect
      "#<TIMEx::Deadline remaining=#{infinite? ? 'inf' : "#{remaining_ms.round}ms"} origin=#{@origin.inspect}>"
    end

    private

    def infinite_remaining_float?(ns)
      ns.is_a?(Float) && ns.infinite?
    end

    def ns_to_iso8601(ns)
      Time.at(ns / Clock::NS_PER_SECOND, ns % Clock::NS_PER_SECOND, :nsec).utc.iso8601(3)
    end

  end

  Deadline.send(:remove_const, :INFINITE)
  Deadline.const_set(
    :INFINITE,
    Deadline.new(monotonic_ns: Float::INFINITY, wall_ns: nil, infinite: true).freeze
  )

end
