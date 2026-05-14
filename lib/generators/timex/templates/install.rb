# frozen_string_literal: true

#
# TIMEx global defaults for this Rails app. Edit and uncomment options as needed.
# Full reference: https://drexed.github.io/timex/configuration

TIMEx.configure do |c|
  # ===========================================================================
  # Default strategy
  # ===========================================================================
  # Registry name passed to strategies when +strategy:+ is omitted on
  # +TIMEx.deadline+ (e.g. +:cooperative+, +:io+, +:unsafe+).
  #
  # c.default_strategy = :cooperative

  # ===========================================================================
  # On timeout
  # ===========================================================================
  # +:raise+, +:return_nil+, +:result+, or a +Proc+ invoked with the exception.
  #
  # c.default_on_timeout = :raise

  # ===========================================================================
  # Auto-check (TracePoint)
  # ===========================================================================
  # When +true+, +TIMEx.deadline+ behaves like +auto_check: true+ unless overridden
  # per call. +auto_check_interval+ is VM events between deadline polls.
  #
  # c.auto_check_default = false
  # c.auto_check_interval = 1_000

  # ===========================================================================
  # Telemetry
  # ===========================================================================
  # +nil+ uses the built-in null adapter. In Rails you often wire Logger or
  # Active Support Notifications — see docs/telemetry.md.
  #
  # c.telemetry_adapter = TIMEx::Telemetry::Adapters::Logger.new(Rails.logger)
  # c.telemetry_adapter = TIMEx::Telemetry::Adapters::ActiveSupportNotifications.new

  # ===========================================================================
  # Clock
  # ===========================================================================
  # Override monotonic/wall time sources (tests, virtual clocks).
  #
  # c.clock = nil

  # ===========================================================================
  # Deadline header skew
  # ===========================================================================
  # Milliseconds of tolerated wall-clock drift when parsing propagated headers.
  #
  # c.skew_tolerance_ms = 250
end
