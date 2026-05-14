# frozen_string_literal: true

module TIMEx
  module Composers
    # Shared mixin for composer objects that orchestrate one or more strategies.
    #
    # Composers behave like strategies: they accept +deadline:+ / +on_timeout:+,
    # expose {.name_symbol} via {NamedComponent}, and route {Expired} through
    # {TimeoutHandling}. Subclasses implement +#call+ with their own scheduling.
    #
    # @see TimeoutHandling
    # @see NamedComponent
    class Base

      include TIMEx::NamedComponent
      include TIMEx::TimeoutHandling

    end
  end
end
