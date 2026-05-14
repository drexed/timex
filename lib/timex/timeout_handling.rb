# frozen_string_literal: true

module TIMEx
  # Shared +on_timeout:+ dispatcher included by strategies and composers.
  #
  # Centralizes semantics for +:raise+, +:raise_standard+, +:return_nil+,
  # +:result+, and custom +Proc+ handlers so layers cannot drift.
  #
  # @see ON_TIMEOUT_SYMBOLS
  # @see Expired
  # @see Result.timeout
  module TimeoutHandling

    private

    # Dispatches an {Expired} according to +on_timeout+.
    #
    # @param on_timeout [Symbol, Proc] mode or custom handler
    # @param expired [Expired] the deadline exception
    # @return [Object, nil] handler return value; may raise
    # @raise [Expired] when +on_timeout == :raise+
    # @raise [TimeoutError] when +on_timeout == :raise_standard+
    # @raise [ArgumentError] when +on_timeout+ is unknown
    def handle_timeout(on_timeout, expired)
      case on_timeout
      when :raise then raise expired
      when :raise_standard then raise TimeoutError.from(expired)
      when :return_nil then nil
      when :result then Result.timeout(strategy: self.class.name_symbol, expired:)
      when Proc then on_timeout.call(expired)
      else
        raise ArgumentError,
          "unknown on_timeout: #{on_timeout.inspect} " \
          "(expected one of #{ON_TIMEOUT_SYMBOLS.inspect}, or a Proc)"
      end
    end

  end
end
