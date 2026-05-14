# PG query with a deadline

Postgres has a server-side `statement_timeout`. Pair it with
`Closeable` so a stuck query unblocks the Ruby thread even when the
server is slow to honor cancellation, and discard the connection so
the pool refills with a healthy one.

```ruby
require "active_record"
require "timex"

def find_with_deadline(sql, deadline:)
  ActiveRecord::Base.connection_pool.with_connection do |conn|
    raw = conn.raw_connection
    ms  = deadline.remaining_ms.round
    raise deadline.expired_error(strategy: :io, message: "pg: budget exhausted") if ms <= 0

    raw.exec("SET LOCAL statement_timeout = #{ms}")

    TIMEx::Strategies::Closeable
      .new(resource: raw, close_method: :cancel)
      .call(deadline: deadline) { |c, _| c.exec(sql) }
  rescue PG::QueryCanceled, PG::ConnectionBad
    ActiveRecord::Base.connection_pool.remove(conn)
    raise deadline.expired_error(strategy: :closeable, message: "pg: query exceeded deadline")
  end
end

TIMEx.deadline(1.5) { |d| find_with_deadline("SELECT pg_sleep(10)", deadline: d) }
```

Why both layers:

- `statement_timeout` is the canonical server-side stop and is enough
  in the happy path.
- `Closeable` calls `PGconn#cancel` from a watcher thread when the
  deadline elapses — the server sometimes takes its time honoring
  the timeout (e.g. inside a long C call inside the planner), and
  `cancel` shoves it along.
- The connection is *evicted* from the pool after cancellation: a
  query that was cancelled mid-stream can leave the wire protocol in
  a state the pool isn't equipped to recover.

See [Closeable](../docs/strategies/closeable.md).
