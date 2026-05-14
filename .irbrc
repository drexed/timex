# frozen_string_literal: true

require "pp"

require_relative "lib/timex" unless defined?(TIMEx)

def reload!
  exec("irb")
end
