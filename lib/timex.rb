# frozen_string_literal: true

module TIMEx

  Error = Class.new(StandardError)
  ConfigurationError = Class.new(Error)
  StrategyNotFoundError = Class.new(Error)

  extend self

  # Primary entrypoint: runs +block+ under +deadline_or_seconds+ using the resolved strategy.
  #
  # @param deadline_or_seconds [Deadline, Numeric, Time, nil] budget or deadline
  # @param strategy [Symbol, #call, nil] registered key, callable, or +nil+ for default
  # @param auto_check [Boolean, nil] +nil+ uses {Configuration#auto_check_default}
  # @param on_timeout [Symbol, Proc, nil] +nil+ uses {Configuration#default_on_timeout}
  # @param opts [Hash{Symbol => Object}] forwarded to the strategy +#call+
  # @yieldparam deadline [Deadline] coerced deadline passed to the inner block
  # @return [Object] strategy/composer result (including timeout handler results)
  # @raise [ArgumentError] when no block is given
  def call(deadline_or_seconds, strategy: nil, auto_check: nil, on_timeout: nil, **opts, &block)
    raise ArgumentError, "block required" unless block

    deadline = Deadline.coerce(deadline_or_seconds)
    strategy = Registry.resolve_for_call(strategy)
    cfg = config
    on_timeout ||= cfg.default_on_timeout
    auto_check = cfg.auto_check_default if auto_check.nil?
    runner =
      if auto_check
        ->(d) { TIMEx::AutoCheck.run(d) { yield(d) } }
      else
        block
      end

    strategy.call(
      deadline:,
      on_timeout:,
      **opts,
      &runner
    )
  end
  alias deadline call

end

require_relative "timex/version"
require_relative "timex/on_timeout"
require_relative "timex/named_component"
require_relative "timex/expired"
require_relative "timex/configuration"
require_relative "timex/clock"
require_relative "timex/telemetry"
require_relative "timex/deadline"
require_relative "timex/result"
require_relative "timex/cancellation_token"
require_relative "timex/registry"
require_relative "timex/timeout_handling"
require_relative "timex/strategies/base"
require_relative "timex/strategies/cooperative"
require_relative "timex/strategies/io"
require_relative "timex/strategies/unsafe"
require_relative "timex/strategies/wakeup"
require_relative "timex/strategies/closeable"
require_relative "timex/strategies/subprocess"
require_relative "timex/strategies/ractor"
require_relative "timex/composers/base"
require_relative "timex/composers/two_phase"
require_relative "timex/composers/hedged"
require_relative "timex/composers/adaptive"
require_relative "timex/auto_check"
require_relative "timex/propagation/http_header"
require_relative "timex/propagation/rack_middleware"
require_relative "timex/test/virtual_clock"

require_relative "generators/timex/install_generator" if defined?(Rails::Generators)

# Rails integration is opt-in via the install generator initializer; a Railtie
# hook is not loaded from this file to keep the core gem free of Rails deps.
