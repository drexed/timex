# Tips and Tricks

Little habits that make TIMEx feel obvious in code review. None of these are
secret features—just the stuff we reach for after the first week of wiring
deadlines for real.

!!! warning "Set the client’s own timeout first"

    TIMEx caps how long *Ruby waits*. The HTTP client, DB driver, or RPC stub
    is what actually stops the IO. Always configure their native timeouts
    (`read_timeout`, `statement_timeout`, gRPC `deadline:`, etc.) — then wrap
    them in `TIMEx.deadline` to share one budget across hops.

## Real-world: one checkout flow, many IO calls

During payment capture you might read Redis, call a card gateway, then enqueue a
receipt—all under one Rack-derived deadline. Thread **`Deadline`** through plain
Ruby methods (no global timer per hop) so a slow fraud check does not leave the
card client zero time:

```ruby
def capture!(deadline:)
  fraud_client.verify!(deadline: deadline)
  charge = gateway.capture(deadline: deadline.min(2.0))
  enqueue_receipt(charge.id, deadline: deadline)
end
```

## Pass the deadline down the stack

```ruby
def fetch(deadline:)
  TIMEx::Strategies::IO.read(socket, 4096, deadline: deadline)
end

TIMEx.deadline(2.0) { |d| fetch(deadline: d) }
```

Treat **`Deadline`** like a permission slip: hand it to helpers so every layer
knows how much time is left. Nested work can shrink the budget with
**`Deadline#min`**:

```ruby
def call_external(deadline:)
  TIMEx.deadline(deadline.min(0.5)) { real_call }   # never more than 500 ms here
end
```

## Use `shield` only for cleanup

```ruby
TIMEx.deadline(1.0) do |d|
  begin
    work
  ensure
    d.shield { release_resources }
  end
end
```

**`shield`** says “do not cancel this tiny block for cooperative deadlines.”
Perfect for releasing handles; not a hiding place for more slow work.

## Let telemetry be your flight recorder

Every strategy emits a finish event with **`outcome`**, **`elapsed_ms`**,
**`strategy`**, and **`deadline_ms`**. Plug an adapter once—see
[Telemetry](telemetry.md)—and you get a straight answer to “what timed out,
where, and how long did we burn?”

## Test time without `sleep`

```ruby
around { |ex| TIMEx::Test.with_virtual_clock { ex.run } }

it "expires" do
  d = TIMEx::Deadline.in(1.0)
  TIMEx::Test.advance(2.0)
  expect(d).to be_expired
end
```

Full tour: [Testing](testing.md).

## Lint the scary rescues

```bash
bin/timex-lint app lib
```

That helper nags about **`rescue Exception`** and bare **`rescue`** inside
`TIMEx.deadline` blocks—patterns that swallow cooperative timeouts and pretend
everything succeeded.

## Useful examples

End-to-end recipes for common scenarios. Each is a single-page, self-contained snippet you can copy-paste.

| Recipe | Strategies / Composers |
|---|---|
| [LLM calls with RubyLLM + TIMEx](https://github.com/drexed/timex/blob/main/examples/ai_llm_api_deadline.md) | Faraday `request_timeout`, propagation, Result |
| [Net::HTTP request with deadline](https://github.com/drexed/timex/blob/main/examples/net_http_request.md) | IO, propagation |
| [PG query with deadline](https://github.com/drexed/timex/blob/main/examples/pg_query_with_deadline.md) | Closeable, IO |
| [Redis with deadline](https://github.com/drexed/timex/blob/main/examples/redis_with_deadline.md) | IO |
| [Faraday middleware](https://github.com/drexed/timex/blob/main/examples/faraday_middleware.md) | IO, propagation |
| [Sidekiq job deadline](https://github.com/drexed/timex/blob/main/examples/sidekiq_job_deadline.md) | Cooperative, propagation |
| [Rack request deadline](https://github.com/drexed/timex/blob/main/examples/rack_request_deadline.md) | RackMiddleware |
| [gRPC deadline propagation](https://github.com/drexed/timex/blob/main/examples/grpc_deadline_propagation.md) | Propagation |
| [CLI long-running command](https://github.com/drexed/timex/blob/main/examples/cli_long_running_command.md) | TwoPhase, Subprocess |
| [Untrusted user code](https://github.com/drexed/timex/blob/main/examples/untrusted_user_code.md) | Subprocess |
| [Hedged RPC call](https://github.com/drexed/timex/blob/main/examples/hedged_rpc_call.md) | Hedged |
| [Two-phase graceful shutdown](https://github.com/drexed/timex/blob/main/examples/two_phase_graceful_shutdown.md) | TwoPhase |
| [Adaptive timeout from history](https://github.com/drexed/timex/blob/main/examples/adaptive_timeout_from_history.md) | Adaptive |
| [Lease-based distributed job](https://github.com/drexed/timex/blob/main/examples/lease_distributed_job.md) | Lease (placeholder) |
| [OpenTelemetry spans](https://github.com/drexed/timex/blob/main/examples/opentelemetry_spans.md) | Telemetry |
| [ActiveSupport instrumentation](https://github.com/drexed/timex/blob/main/examples/active_support_instrumentation.md) | Telemetry |
| [Migrating a legacy `Timeout.timeout`](https://github.com/drexed/timex/blob/main/examples/migrating_legacy_timeout_block.md) | Cooperative, TwoPhase |
