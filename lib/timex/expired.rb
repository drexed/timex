# frozen_string_literal: true

module TIMEx

  # Raised when a deadline elapses while a strategy is executing user work.
  #
  # Strategies catch {Expired}, record telemetry, then dispatch through
  # {TimeoutHandling} according to +on_timeout:+.
  #
  # @note Inherits from +Exception+ (not +StandardError+), so +rescue+ without a
  #   type and most +rescue StandardError+ handlers will **not** catch this.
  #   Rescue +TIMEx::Expired+ explicitly when you wrap raw strategy code. For
  #   +StandardError+-compatible behavior use +on_timeout: :raise_standard+,
  #   which raises {TimeoutError} with this exception as +#cause+.
  #
  # @see TimeoutError
  # @see TIMEx.deadline
  class Expired < Exception

    attr_reader :strategy, :deadline_ms, :elapsed_ms

    # @param message [String] human-readable reason (default is generic)
    # @param strategy [Symbol, nil] strategy name symbol when known
    # @param deadline_ms [Float, Integer, nil] remaining budget in ms when expired
    # @param elapsed_ms [Float, Integer, nil] elapsed time in ms when expired
    def initialize(message = "deadline expired", strategy: nil, deadline_ms: nil, elapsed_ms: nil)
      super(message)
      @strategy = strategy
      @deadline_ms = deadline_ms
      @elapsed_ms = elapsed_ms
    end

  end

  # +StandardError+ raised when a deadline expires and the caller opted into
  # +on_timeout: :raise_standard+.
  #
  # Carries the same +strategy+, +deadline_ms+, and +elapsed_ms+ readers as
  # {Expired}, plus +#original+ pointing at the source {Expired} for inspection
  # or re-raise.
  #
  # @see Expired
  # @see TIMEx.deadline
  class TimeoutError < StandardError

    attr_reader :strategy, :deadline_ms, :elapsed_ms, :original

    # Builds a {TimeoutError} from an {Expired}, preserving message and metrics.
    #
    # @param expired [Expired] the deadline exception to wrap
    # @return [TimeoutError] new error with +#original+ set to +expired+
    def self.from(expired)
      new(
        expired.message,
        strategy: expired.strategy,
        deadline_ms: expired.deadline_ms,
        elapsed_ms: expired.elapsed_ms,
        original: expired
      )
    end

    # @param message [String] human-readable reason
    # @param strategy [Symbol, nil] strategy name symbol when known
    # @param deadline_ms [Float, Integer, nil] remaining budget in ms when expired
    # @param elapsed_ms [Float, Integer, nil] elapsed time in ms when expired
    # @param original [Expired, nil] the underlying {Expired} when created via {.from}
    def initialize(message = "deadline expired", strategy: nil, deadline_ms: nil, elapsed_ms: nil, original: nil)
      super(message)
      @strategy = strategy
      @deadline_ms = deadline_ms
      @elapsed_ms = elapsed_ms
      @original = original
    end

  end

end
