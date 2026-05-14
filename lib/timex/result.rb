# frozen_string_literal: true

module TIMEx
  # Discriminated outcome from work executed under a deadline when errors are
  # captured instead of raised (+on_timeout: :result+, non-raising strategies, etc.).
  #
  # Instances are frozen at construction and support pattern matching via
  # {#deconstruct} / {#deconstruct_keys}.
  #
  # @see TIMEx.deadline
  class Result

    OK      = :ok
    TIMEOUT = :timeout
    ERROR   = :error

    attr_reader :outcome, :value, :strategy, :elapsed_ms, :error, :deadline_ms

    # @param outcome [Symbol] one of +OK+, +TIMEOUT+, or +ERROR+
    # @param value [Object, nil] success payload when +outcome == OK+
    # @param strategy [Symbol, nil] component name when known
    # @param elapsed_ms [Numeric, nil] elapsed time in ms when known
    # @param error [Exception, nil] underlying exception for timeout/error paths
    # @param deadline_ms [Numeric, nil] original budget in ms for timeout paths
    # @return [void]
    #
    # @note Freezes +self+ before returning.
    def initialize(outcome:, value: nil, strategy: nil, elapsed_ms: nil, error: nil, deadline_ms: nil) # rubocop:disable Metrics/ParameterLists
      @outcome = outcome
      @value = value
      @strategy = strategy
      @elapsed_ms = elapsed_ms
      @error = error
      @deadline_ms = deadline_ms
      freeze
    end

    # @param value [Object] success value
    # @param strategy [Symbol, nil]
    # @param elapsed_ms [Numeric, nil]
    # @return [Result] frozen OK result
    def self.ok(value, strategy: nil, elapsed_ms: nil)
      new(outcome: OK, value:, strategy:, elapsed_ms:)
    end

    # Builds a timeout result, always carrying an {Expired} in +#error+ so {#value!}
    # can re-raise with uniform metadata.
    #
    # @param strategy [Symbol, nil]
    # @param expired [Expired, nil] existing {Expired} (preferred)
    # @param elapsed_ms [Numeric, nil] used with +deadline_ms+ to synthesize {Expired} when +expired+ omitted
    # @param deadline_ms [Numeric, nil] used with +elapsed_ms+ to synthesize {Expired} when +expired+ omitted
    # @return [Result] frozen timeout result
    def self.timeout(strategy:, expired: nil, elapsed_ms: nil, deadline_ms: nil)
      expired ||= Expired.new(
        "deadline expired",
        strategy:,
        deadline_ms:,
        elapsed_ms:
      )
      new(
        outcome: TIMEOUT,
        strategy:,
        error: expired,
        elapsed_ms: elapsed_ms || expired.elapsed_ms,
        deadline_ms: deadline_ms || expired.deadline_ms
      )
    end

    # @param error [Exception]
    # @param strategy [Symbol, nil]
    # @param elapsed_ms [Numeric, nil]
    # @return [Result] frozen error result
    # @raise [ArgumentError] when +error+ is not an +Exception+
    def self.error(error, strategy: nil, elapsed_ms: nil)
      raise ArgumentError, "error must be an Exception, got #{error.class}" unless error.is_a?(Exception)

      new(outcome: ERROR, error:, strategy:, elapsed_ms:)
    end

    # @return [Boolean]
    def ok?      = @outcome == OK

    # @return [Boolean]
    def timeout? = @outcome == TIMEOUT

    # @return [Boolean]
    def error?   = @outcome == ERROR

    # Returns the success value or raises the captured exception.
    #
    # @return [Object] +@value+ when {#ok?}
    # @raise [Expired, Exception] when {#timeout?} or {#error?}
    # @raise [Error] when not OK and no +@error+ is present
    def value!
      return @value if ok?
      raise @error if @error

      raise Error, "result has no value"
    end
    alias unwrap value!

    # Returns +@value+ when the result is OK, otherwise the +default+ (or the
    # block's return value if a block is given).
    #
    # @param default [Object] fallback when not OK and no block given
    # @yieldparam result [Result] +self+ for inspecting +error+, +strategy+, etc.
    # @return [Object]
    def value_or(default = nil)
      if ok?
        @value
      else
        (block_given? ? yield(self) : default)
      end
    end
    alias unwrap_or value_or

    # @return [Array(Symbol, Object, Exception, nil)] array shape for pattern matching
    def deconstruct
      [@outcome, @value, @error]
    end

    # @param _keys [Array<Symbol>, nil] ignored; present for Ruby pattern-matching protocol
    # @return [Hash{Symbol => Object}] hash shape for pattern matching
    def deconstruct_keys(_keys)
      {
        outcome: @outcome,
        value: @value,
        error: @error,
        strategy: @strategy,
        elapsed_ms: @elapsed_ms,
        deadline_ms: @deadline_ms
      }
    end

  end
end
