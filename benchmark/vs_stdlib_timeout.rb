# frozen_string_literal: true

# Compares TIMEx strategies against the stdlib `Timeout` module.
#
#   bundle exec ruby benchmark/vs_stdlib_timeout.rb

require "benchmark/ips"
require "timeout"
require_relative "../lib/timex"

Benchmark.ips do |x|
  x.report("stdlib Timeout.timeout(1) {}") do
    Timeout.timeout(1) { :ok }
  end
  x.report("TIMEx.deadline(1.0, :cooperative)") do
    TIMEx.deadline(1.0) { :ok }
  end
  x.report("TIMEx.deadline(1.0, :unsafe)") do
    TIMEx.deadline(1.0, strategy: :unsafe) { :ok }
  end
  x.compare!
end
