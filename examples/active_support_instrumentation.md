# ActiveSupport instrumentation

Pipe TIMEx telemetry into `ActiveSupport::Notifications` so the same
subscribers that already power your `lograge` / APM stack pick up
deadline outcomes for free.

```ruby
require "active_support/notifications"
require "timex"

TIMEx.configure do |c|
  c.telemetry_adapter = TIMEx::Telemetry::Adapters::ActiveSupportNotifications.new
end

ActiveSupport::Notifications.subscribe(/\Atimex\./) do |*args|
  event   = ActiveSupport::Notifications::Event.new(*args)
  payload = event.payload

  Rails.logger.info(
    event:        event.name,
    strategy:     payload[:strategy],
    outcome:      payload[:outcome],
    deadline_ms:  payload[:deadline_ms],
    elapsed_ms:   payload[:elapsed_ms],
    error_class:  payload[:error_class],
    origin:       payload[:origin]
  )
end
```

Every `TIMEx.deadline` call publishes `timex.strategy.call` on finish;
composers add `timex.composer.two_phase` / `timex.composer.adaptive`.
With a structured logger (lograge, semantic_logger) you get one
searchable line per timed operation — strategy, outcome, and budget all
in the same record as the request that triggered them.

See [Telemetry](../docs/telemetry.md) for the full event catalogue.
