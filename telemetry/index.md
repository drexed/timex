# Telemetry

TIMEx does not guess whether a timeout mattered in production—it tells you. Every strategy finishes with a small event (think: “who ran, for how long, and did we finish on time?”). Your app chooses where those events go: nowhere, a logger, Active Support, OpenTelemetry, or a class you write.

## TL;DR

```ruby
TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::Logger.new(Rails.logger)
end
```

`nil` (the default) means “discard quietly” via the built-in Null adapter—fine for scripts, less fun when you are on call.

## How it works (plain English)

- Most work goes through **`Telemetry.instrument`**: the adapter gets **`start`** before your block, then **`finish`** after (with **`elapsed_ms`** and **`outcome`** filled in when things go sideways).
- One-off signals use **`Telemetry.emit`**, which is implemented on **`Adapters::Base`** as “`start` then `finish`” with the same payload object.
- **`TIMEx.configure { |c| c.telemetry_adapter = … }`** requires an object that responds to **`#emit`** (every built-in adapter subclasses **`Base`**, so you get **`start` / `finish`** for free).

If you only remember one thing: **timeouts become observable data**, not a silent `raise` you hope someone logged.

## Events at a glance

| Event                         | Where it fires                                     | Notable payload keys                                               |
| ----------------------------- | -------------------------------------------------- | ------------------------------------------------------------------ |
| `strategy.call`               | Every `TIMEx.deadline` (any strategy)              | `strategy`, `deadline_ms`, `elapsed_ms`, `outcome`, `error_class`  |
| `composer.two_phase`          | `TwoPhase#call`                                    | `soft_ms`, `grace_ms`, `soft_timeout`, `outcome`                   |
| `composer.adaptive`           | `Adaptive#call`                                    | `estimate_ms`, `budget_ms`, `deadline_ms`, `elapsed_ms`, `outcome` |
| `deadline.skew_detected`      | Header parsing finds wall-clock drift              | `skew_ms`, `origin`                                                |
| `deadline.budget_clamped`     | `Deadline.in` rejected (non-finite, too big)       | `reason`, `requested_seconds`                                      |
| `rack.deadline.rejected`      | `RackMiddleware` returns `503`                     | `reason`, `depth`, `origin`                                        |
| `rack.deadline.unparseable`   | Inbound header was non-empty but malformed         | `bytesize`                                                         |
| `ractor.leak`                 | `Ractor` strategy abandoned a still-running ractor | `deadline_ms`                                                      |
| `cancellation.observer_error` | `CancellationToken` observer raised                | `error_class`                                                      |

`Hedged` does not emit telemetry today (each child attempt still emits its own `strategy.call`). Treat unknown keys as optional hints—new ones may appear.

## Common payload keys

| Key           | Type           | Plain meaning                                                     |
| ------------- | -------------- | ----------------------------------------------------------------- |
| `strategy`    | Symbol         | Which strategy ran, e.g. `:cooperative`, `:subprocess`.           |
| `deadline_ms` | Integer or nil | Budget in milliseconds; `nil` means “no fixed cap.”               |
| `elapsed_ms`  | Float          | How long wall clock actually took (added in `finish`).            |
| `outcome`     | Symbol         | `:ok`, `:timeout`, `:soft_timeout`, `:hard_timeout`, or `:error`. |
| `error_class` | String         | Only on `:error` — what blew up.                                  |

## Built-in adapters

- **`TIMEx::Telemetry::Adapters::Null`** — default; intentionally boring.
- **`TIMEx::Telemetry::Adapters::Logger.new(logger)`** — one INFO line per finish event; great for “turn it on in staging first.”
- **`TIMEx::Telemetry::Adapters::ActiveSupportNotifications`** — publishes `timex.<event>` so anything already listening to AS::N can piggyback.
- **`TIMEx::Telemetry::Adapters::OpenTelemetry`** — one span per event; marks error status when the outcome is timeout-shaped.

## Roll your own

Subclass **`TIMEx::Telemetry::Adapters::Base`**. Override **`finish`** (and optionally **`start`**) for spans; the default **`emit`** pairs them if you only need one-shot logging. Assign an instance in configuration:

```ruby
class StatsdAdapter < TIMEx::Telemetry::Adapters::Base
  def initialize(client) = (@client = client)

  def finish(event:, payload:)
    @client.timing("timex.#{event}.elapsed_ms", payload[:elapsed_ms])
    @client.increment("timex.#{event}.#{payload[:outcome]}")
  end
end

TIMEx.configure { |c| c.telemetry_adapter = StatsdAdapter.new(STATSD) }
```

Keep `finish` cheap—this runs on the hot path after work completes.

## Real-world: incident triage via Active Support Notifications

It is 2 a.m. and checkout p99 is climbing. You suspect the fraud vendor, but proving it means correlating `strategy: :io` timeouts with the vendor host. Subscribe once, page when the rate spikes:

```ruby
TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::ActiveSupportNotifications.new
end

ActiveSupport::Notifications.subscribe("timex.strategy.call") do |_name, _start, _finish, _id, payload|
  next unless payload[:outcome] == :timeout && payload[:strategy] == :io

  StatsD.increment("timex.io.timeout", tags: ["host:#{payload[:host] || "unknown"}"])
  PagerDuty.notify_throttled("io timeouts spiking: #{payload}") if Throttle.exceeded?
end
```

Now the dashboard answers “which strategy, which host, which budget?” at a glance—the same data your `rescue TIMEx::Expired` block has, but observable across the whole fleet instead of one log line per failure.
