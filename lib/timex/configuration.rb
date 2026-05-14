# frozen_string_literal: true

require "monitor"
require_relative "on_timeout"

module TIMEx

  # Mutable process-wide defaults for {TIMEx.deadline}, propagation, telemetry, and
  # clock selection.
  #
  # Read through {TIMEx.configuration}; updates should go through {TIMEx.configure}
  # so in-flight callers never observe a half-mutated instance.
  #
  # @see TIMEx.configure
  # @see TIMEx.configuration
  class Configuration

    attr_reader :default_strategy, :default_on_timeout, :auto_check_default,
      :auto_check_interval, :telemetry_adapter, :clock, :skew_tolerance_ms

    # Builds defaults aligned with conservative production behavior.
    #
    # @return [void]
    def initialize
      @default_strategy = :cooperative
      @default_on_timeout = :raise
      @auto_check_default = false
      @auto_check_interval = 1000
      @telemetry_adapter = nil
      @clock = nil
      @skew_tolerance_ms = Deadline::DEFAULT_SKEW_TOLERANCE_MS
    end

    # @param value [Symbol, #call] registered strategy key or callable strategy
    # @return [Symbol, #call] the assigned strategy
    # @raise [ConfigurationError] when +value+ is neither a Symbol nor callable
    def default_strategy=(value)
      raise ConfigurationError, "default_strategy must be a Symbol or strategy class" unless value.is_a?(Symbol) || value.respond_to?(:call)

      @default_strategy = value
    end

    # @param value [Symbol, Proc] one of {ON_TIMEOUT_SYMBOLS} or a custom Proc
    # @return [Symbol, Proc] the assigned handler
    # @raise [ConfigurationError] when +value+ is not allowed
    def default_on_timeout=(value)
      unless ON_TIMEOUT_SYMBOLS.include?(value) || value.is_a?(Proc)
        raise ConfigurationError,
          "default_on_timeout must be one of #{ON_TIMEOUT_SYMBOLS.inspect} or a Proc"
      end

      @default_on_timeout = value
    end

    # @param value [Boolean]
    # @return [Boolean]
    # @raise [ConfigurationError] when not strictly +true+ or +false+
    def auto_check_default=(value)
      raise ConfigurationError, "auto_check_default must be true or false" unless [true, false].include?(value)

      @auto_check_default = value
    end

    # @param value [Integer] milliseconds between automatic deadline checks
    # @return [Integer]
    # @raise [ConfigurationError] when not a positive Integer
    def auto_check_interval=(value)
      raise ConfigurationError, "auto_check_interval must be a positive Integer" unless value.is_a?(Integer) && value.positive?

      @auto_check_interval = value
    end

    # @param value [#emit, nil] adapter object or +nil+ to fall back to global default
    # @return [#emit, nil]
    # @raise [ConfigurationError] when non-+nil+ and missing +#emit+
    def telemetry_adapter=(value)
      raise ConfigurationError, "telemetry_adapter must respond to :emit" if value && !value.respond_to?(:emit)

      @telemetry_adapter = value
    end

    # @param value [nil, #monotonic_ns, #wall_ns] process-wide clock override
    # @return [nil, Object]
    # @raise [ConfigurationError] when non-+nil+ and missing required methods
    def clock=(value)
      ok = value.nil? || (value.respond_to?(:monotonic_ns) && value.respond_to?(:wall_ns))
      raise ConfigurationError, "clock must respond to :monotonic_ns and :wall_ns" unless ok

      @clock = value
    end

    # @param value [Numeric] wall skew tolerance used when parsing propagated deadlines
    # @return [Numeric]
    # @raise [ConfigurationError] when negative or non-numeric
    def skew_tolerance_ms=(value)
      raise ConfigurationError, "skew_tolerance_ms must be a non-negative Numeric" unless value.is_a?(Numeric) && !value.negative?

      @skew_tolerance_ms = value
    end

    # Duplicates mutable Array/Hash fields after +dup+ so nested configuration
    # cannot leak mutations across snapshots.
    #
    # @note Current fields are primitives; this is defensive for future container fields.
    #
    # @return [void]
    def initialize_copy(source)
      super
      instance_variables.each do |iv|
        val = instance_variable_get(iv)
        instance_variable_set(iv, val.dup) if val.is_a?(Array) || val.is_a?(Hash)
      end
    end

  end

  class << self

    CONFIG_MUTEX = Monitor.new
    private_constant :CONFIG_MUTEX

    # Returns the process-wide {Configuration}, constructing it once under +CONFIG_MUTEX+.
    #
    # @return [Configuration]
    def configuration
      @configuration || CONFIG_MUTEX.synchronize { @configuration ||= Configuration.new }
    end
    alias config configuration

    # Yields a duplicated {Configuration}, then atomically publishes it when the
    # outermost block completes without raising.
    #
    # Nested +configure+ calls mutate the same draft and only the outermost swap
    # commits, keeping re-entrant initialization safe.
    #
    # @yieldparam draft [Configuration] mutable copy to adjust
    # @return [Object] the block's return value
    # @raise [ArgumentError] when no block is given
    def configure
      raise ArgumentError, "TIMEx.configure requires a block" unless block_given?

      CONFIG_MUTEX.synchronize do
        outer = @configure_draft.nil?
        @configure_draft ||= configuration.dup
        begin
          yield @configure_draft
          @configuration = @configure_draft if outer
        ensure
          @configure_draft = nil if outer
        end
      end
    end

    # Replaces the configuration with a fresh {Configuration} under the mutex.
    #
    # @return [void]
    def reset_configuration!
      CONFIG_MUTEX.synchronize { @configuration = Configuration.new }
    end

  end

end
