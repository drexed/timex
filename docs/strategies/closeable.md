# Closeable

Some blocking calls only wake up when their **handle dies**. **Closeable**
wraps a resource (socket, DB connection, anything with a **`close`** that
interrupts the read) and, on expiry, **closes it** so the blocked syscall returns
with a normal IO error—no `Thread#raise` required.

**Mental model:** instead of shaking someone awake, you gently turn off the lamp
they were staring at. The room handles the interrupt for you.

## Quick example

```ruby
TIMEx::Strategies::Closeable.new(resource: socket).call(deadline: 2.0) do |io, d|
  io.read(1024)
end
```

After a timeout-driven close, treat that handle as **toast**—do not put it back
in a pool unless your pool knows how to vet dead connections.

## At a glance

| Topic | Plain English |
| --- | --- |
| CPU-heavy Ruby | Not the target—still need checkpoints for pure Ruby loops. |
| Blocking IO | Yes: closing wakes many blocking reads/writes cleanly. |
| Mutexes / shared state | Safer than async exceptions: you get predictable IO errors. |
| C extensions | Often works when the ext is just wrapping a real fd. |
| Side effect | The resource is **closed**—plan on opening a fresh one next time. |

## When it fits

- Connections you would **throw away** on timeout anyway.
- Pooled resources—pair with **`pool.remove(conn)`** (or your pool’s equivalent)
  in `ensure` so zombies never re-enter rotation.

## Real-world: a stuck Postgres query in a Rails request

You ran the perfect plan in dev; in prod the same query sometimes pins a
connection for minutes behind a missing index. **Closeable** closes the raw
socket so the blocked `PG::Connection#exec` returns with `PG::ConnectionBad`
instead of holding the request hostage, and you discard the connection so the
pool refills with a healthy one:

```ruby
def find_with_deadline(sql, deadline:)
  ActiveRecord::Base.connection_pool.with_connection do |conn|
    socket = conn.raw_connection.socket_io
    TIMEx::Strategies::Closeable.new(resource: socket).call(deadline: deadline) do |_io, _d|
      conn.exec_query(sql)
    end
  rescue PG::ConnectionBad
    ActiveRecord::Base.connection_pool.remove(conn)
    raise TIMEx::Expired.new("postgres query exceeded deadline", strategy: :closeable)
  end
end
```

The runaway query stops eating CPU on the database, the pool stays healthy,
and the controller gets a normal exception instead of a 30-second hang.
