# Configuration

TIMEx ships with sensible defaults. When you need the whole process to
agree on strategy, clocks, telemetry, or auto-check behavior, this is the
knob panel—one `TIMEx.configure` block and you are done.

## Global defaults

```ruby
TIMEx.configure do |c|
  c.default_strategy    = :cooperative   # Symbol or callable strategy
  c.default_on_timeout  = :raise         # see table below
  c.auto_check_default  = false          # opt-in TracePoint cancellation
  c.auto_check_interval = 1_000          # TracePoint :line / :b_return events between checks
  c.telemetry_adapter   = nil            # nil → Null adapter (see Telemetry)
  c.clock               = nil            # nil → monotonic + wall from the process
  c.skew_tolerance_ms   = 250            # wall skew tolerance when parsing headers
end
```

| Attribute | What it does |
|---|---|
| `default_strategy` | Which strategy runs when you omit `strategy:` on `TIMEx.deadline`. |
| `default_on_timeout` | `:raise` (default `TIMEx::Expired`), `:raise_standard` (`TimeoutError`), `:return_nil`, `:result` (`TIMEx::Result.timeout`), or a `Proc`. Per-call `on_timeout:` wins. |
| `auto_check_default` | When `true`, every `TIMEx.deadline` acts like `auto_check: true` unless you override per call. See [Auto-check](auto_check.md). |
| `auto_check_interval` | Positive integer: count of `:line` / `:b_return` TracePoint events between deadline polls. Bigger = cheaper, slower to notice expiry. |
| `telemetry_adapter` | Object responding to **`#emit`** (subclass `Telemetry::Adapters::Base` and you get `start` / `finish` for free). `nil` → Null. |
| `clock` | Custom `#monotonic_ns` / `#wall_ns` clock for the process, or `nil` for the default. Tests usually use `TIMEx::Test.with_virtual_clock` instead. |
| `skew_tolerance_ms` | When a header uses `wall=`, drift beyond this (ms) emits telemetry—handy for chasing NTP or odd clients. |

## Tests and one-off resets

```ruby
TIMEx.reset_configuration!
```

Handy in specs so one example does not leak settings into the next.

## Real-world: one initializer, whole fleet

A typical Rails (or other long-lived Ruby) process sets telemetry once and
keeps cooperative timeouts as the default so library code stays safe:

```ruby
# config/initializers/timex.rb
TIMEx.configure do |c|
  c.default_strategy    = :cooperative
  c.telemetry_adapter   = TIMEx::Telemetry::Adapters::OpenTelemetry.new
  c.skew_tolerance_ms   = 500   # k8s nodes with loose NTP — widen before paging ops
end
```

If only a few hot paths need `auto_check: true`, leave `auto_check_default` off
and opt in per call so TracePoint cost stays localized.

## Telemetry adapters

```ruby
# Active Support Notifications
TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::ActiveSupportNotifications.new
end
ActiveSupport::Notifications.subscribe(/^timex\./) { |*args| ... }

# OpenTelemetry
TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::OpenTelemetry.new
end

# Plain Logger
TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::Logger.new(Rails.logger)
end
```

Event shapes live in [Telemetry](telemetry.md).

## Per-call overrides

Most of the same ideas can be set just for one call:

```ruby
TIMEx.deadline(2.0,
  strategy:   :unsafe,
  auto_check: true,
  on_timeout: ->(e) { Rails.logger.warn("timed out: #{e.message}"); nil }
) { work }
```

Per-call options beat global configuration for that invocation only.
