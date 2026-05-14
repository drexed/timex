# OpenTelemetry spans

Wire TIMEx events into OTel so every timed operation becomes a span
that joins the surrounding request trace.

```ruby
require "opentelemetry/sdk"
require "timex"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "checkout"
  c.use_all # auto-instrumentation: rack, net_http, redis, pg, ...
end

TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::OpenTelemetry.new
end

TIMEx.deadline(2.0) do |d|
  Fraud::Client.verify!(deadline: d.min(0.5))
  Gateway.capture!(deadline: d)
end
```

Each finish emits a `timex.strategy.call` span with attributes
`strategy`, `deadline_ms`, `elapsed_ms`, and `outcome`; spans are
marked with `status: error` when the outcome is `:timeout`,
`:soft_timeout`, or `:hard_timeout`. Composers add their own spans —
`composer.two_phase` with `outcome: :soft_timeout` is gold for
spotting which subsystem keeps tripping the grace window.

Because the adapter uses the active OTel context, TIMEx spans nest
inside whatever Rack / Sidekiq span auto-instrumentation already
opened. No manual propagation required.

See [Telemetry](../docs/telemetry.md).
