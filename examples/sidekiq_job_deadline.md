# Sidekiq job deadline

Carry the caller's deadline through Sidekiq's `enqueue → perform`
boundary with a paired client/server middleware. The job sees the
same budget the originating request had, minus queue wait time.

```ruby
require "sidekiq"
require "timex"

module TIMExSidekiq

  class Client
    include Sidekiq::ClientMiddleware
    def call(_worker_class, job, _queue, _redis_pool)
      if (d = Thread.current[:timex_deadline])
        job["timex_deadline"] = d.to_header(prefer: :wall) # wall-clock survives queue wait
      end
      yield
    end
  end

  class Server
    include Sidekiq::ServerMiddleware
    def call(_worker, job, _queue)
      Thread.current[:timex_deadline] = TIMEx::Deadline.from_header(job["timex_deadline"]) if job["timex_deadline"]
      yield
    ensure
      Thread.current[:timex_deadline] = nil
    end
  end

end

Sidekiq.configure_client { |c| c.client_middleware { |m| m.add TIMExSidekiq::Client } }
Sidekiq.configure_server do |c|
  c.client_middleware { |m| m.add TIMExSidekiq::Client }
  c.server_middleware { |m| m.add TIMExSidekiq::Server }
end

class WidgetWorker

  include Sidekiq::Job
  sidekiq_options retry: 3

  DEFAULT_BUDGET = 25.0

  def perform(id)
    deadline = Thread.current[:timex_deadline] || TIMEx::Deadline.in(DEFAULT_BUDGET)

    TIMEx.deadline(deadline) do |d|
      Widget.process(id, deadline: d)
    end
  rescue TIMEx::Expired
    self.class.perform_in(30, id) # re-enqueue with a fresh budget
  end

end
```

Why wall-clock (`prefer: :wall`) for the wire format: queue latency
can be minutes, and a `ms=...` header would still be ticking down
while the job sat in Redis. Wall-clock anchors the deadline to "this
instant in real time", which is what the originator actually meant.
The `from_header` parser re-anchors it on the worker's monotonic
clock — see [Deadline](../docs/basics/deadline.md) for the trade-off.

Sidekiq pins one job to one thread for the duration of `perform`, so
the `Thread.current` slot is safe; the `ensure` clears it before the
thread picks up the next job.
