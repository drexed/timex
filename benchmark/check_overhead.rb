# frozen_string_literal: true

# Microbench for the cooperative path. Verifies the README claim:
#   * Deadline#check! no-op cost in the < 100ns range
#   * TIMEx.deadline cold path under a microsecond
#
#   bundle exec ruby benchmark/check_overhead.rb

require "benchmark/ips"
require_relative "../lib/timex"

deadline = TIMEx::Deadline.in(60.0)

Benchmark.ips do |x|
  x.report("Deadline#check! (no-op)") { deadline.check! }
  x.report("TIMEx.deadline(1.0) {}") { TIMEx.deadline(1.0) { :ok } }
  x.report("TIMEx::Deadline.in(1)") { TIMEx::Deadline.in(1.0) }
  x.compare!
end
