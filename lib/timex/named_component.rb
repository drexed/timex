# frozen_string_literal: true

module TIMEx
  # Mixin that exposes a stable snake_case symbol derived from the including
  # class name. Used for telemetry event payloads and {Result} metadata so
  # strategy and composer names stay consistent without manual registration.
  #
  # @see Strategies::Base
  # @see Composers::Base
  module NamedComponent

    def self.included(base)
      base.extend(ClassMethods)
    end

    # Class-level API for {NamedComponent}.
    module ClassMethods

      # Returns a memoized +Symbol+ derived from the class basename (e.g.
      # +"TIMEx::Strategies::Cooperative"+ → +:cooperative+).
      #
      # @return [Symbol] snake_case component name
      def name_symbol
        @name_symbol ||= (name || "anonymous").split("::").last
                         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                         .downcase
                         .to_sym
      end

    end

  end
end
