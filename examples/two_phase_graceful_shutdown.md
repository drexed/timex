# Two-phase graceful shutdown

On SIGTERM, drain in-flight work cleanly; if the worker pool ignores
cancellation, escalate to a hard stop after a bounded grace window so
the orchestrator's own kill timer never has to fire.

```ruby
require "timex"

SHUTDOWN = TIMEx::Composers::TwoPhase.new(
  soft:          :cooperative, # workers honor deadline.check! between jobs
  hard:          :unsafe,      # process is exiting anyway — async-raise is acceptable
  grace:         5.0,
  hard_deadline: 2.0,
  idempotent:    true # drain just signals workers; re-running is a no-op
).freeze

shutting_down = false

Signal.trap("TERM") do
  next if shutting_down

  shutting_down = true
  Thread.new do
    SHUTDOWN.call(deadline: 30.0) do |d|
      WorkerPool.drain(deadline: d)
    end
  rescue TIMEx::Expired
    Logger.warn("forced exit after #{SHUTDOWN_DEADLINE}s")
    Process.exit!(1)
  else
    Process.exit(0)
  end
end
```

Wall-time budget:

| Phase | Window | What's happening |
| --- | --- | --- |
| Soft | 0–30s | `drain` honors `deadline.check!` between jobs |
| Grace | 30–35s | Soft worker still has time to land cleanly |
| Hard | 35–37s | `:unsafe` async-raises into the soft worker, runs the drain again |
| Backstop | 37s | `Process.exit!(1)` — orchestrator never has to SIGKILL |

`Signal.trap` work happens on the VM thread; spawning a fresh thread
keeps signal-handler restrictions (no mutex acquisition, no IO) out of
the drain path. The `shutting_down` guard makes repeated SIGTERMs a
no-op instead of starting a second drainer.

See [TwoPhase](../docs/composers/two_phase.md).
