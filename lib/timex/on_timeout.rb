# frozen_string_literal: true

module TIMEx

  # Canonical set of symbol modes accepted by +on_timeout:+ on {TIMEx.deadline} and
  # related APIs, plus {Configuration#default_on_timeout=}.
  #
  # Kept in one place so validation, documentation, and {TimeoutHandling} stay
  # aligned.
  #
  # @see Configuration#default_on_timeout=
  # @see TimeoutHandling#handle_timeout
  ON_TIMEOUT_SYMBOLS = %i[raise raise_standard return_nil result].freeze

end
