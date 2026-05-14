# frozen_string_literal: true

module TIMEx
  # Copy-on-write registry of named strategies.
  #
  # Reads are lock-free against the frozen backing hash; writes synchronize and
  # replace the hash atomically. Suited for boot-time registration and per-call
  # resolution on the hot path.
  #
  # @see TIMEx.deadline
  # @see Registry.resolve_for_call
  module Registry

    @strategies = {}.freeze
    @write_mutex = Mutex.new
    @default_selector = nil
    @cached_default = nil
    @cached_default_key = nil

    extend self

    # @param name [Symbol, String] registration key
    # @param strategy [#call] callable strategy object
    # @return [void]
    # @raise [ArgumentError] when +strategy+ does not respond to +#call+
    def register(name, strategy)
      raise ArgumentError, "strategy must respond to :call, got #{strategy.inspect}" unless strategy.respond_to?(:call)

      @write_mutex.synchronize do
        @strategies = @strategies.merge(name.to_sym => strategy).freeze
        invalidate_default_cache
      end
    end

    # @param name [Symbol, String]
    # @return [#call]
    # @raise [StrategyNotFoundError] when unknown
    def fetch(name)
      sym = name.to_sym
      strategies = @strategies
      strategies.fetch(sym) do
        raise StrategyNotFoundError, "no strategy registered as #{name.inspect}; " \
                                     "available: #{strategies.keys.inspect}"
      end
    end

    # @return [Array<Symbol>] known registration keys (snapshot)
    def known
      @strategies.keys
    end

    # Resolves a symbol to a registered strategy; passes callables through; +nil+ stays +nil+.
    #
    # @param strategy_or_name [Symbol, #call, nil]
    # @return [#call, nil]
    # @raise [StrategyNotFoundError] when a symbol names an unknown strategy
    def resolve(strategy_or_name)
      case strategy_or_name
      when Symbol then fetch(strategy_or_name)
      when nil then nil
      else strategy_or_name
      end
    end

    # Resolves the callable used by {TIMEx.deadline}: the configured default when
    # +strategy+ is +nil+, a registered entry when it is a {Symbol}, otherwise
    # the object must respond to +#call+ (strategy class or instance).
    #
    # @param strategy [Symbol, #call, nil]
    # @return [#call]
    # @raise [StrategyNotFoundError] when +strategy+ names an unknown registration
    # @raise [ArgumentError] when +strategy+ is neither +nil+, a {Symbol}, nor +#call+-able
    def resolve_for_call(strategy)
      case strategy
      when nil then select_default
      when Symbol then fetch(strategy)
      else
        if strategy.respond_to?(:call)
          strategy
        else
          raise ArgumentError,
            "strategy must be a Symbol, Class, or instance responding to " \
            "#call, got #{strategy.inspect}"
        end
      end
    end

    # Installs or returns the optional default-strategy selector block.
    #
    # @yieldreturn [Symbol, nil] strategy key to resolve, or +nil+ to fall through to config
    # @return [Proc, nil] current selector when called without a block
    def default_selector(&block)
      if block
        @write_mutex.synchronize do
          @default_selector = block
          invalidate_default_cache
        end
      end
      @default_selector
    end

    # Resolves {TIMEx.config} default strategy with optional selector and caching.
    #
    # @return [#call]
    #
    # @note Hot path: caches static {Configuration#default_strategy} resolutions; a
    #   configured selector disables the cache because results may vary per call.
    def select_default
      if @default_selector
        sym = @default_selector.call
        return fetch(sym) if sym
      end

      key = TIMEx.config.default_strategy
      return @cached_default if key == @cached_default_key && @cached_default

      resolved = fetch(key)
      @cached_default_key = key
      @cached_default = resolved
      resolved
    end

    private

    # @return [void]
    def invalidate_default_cache
      @cached_default = nil
      @cached_default_key = nil
    end

  end
end
