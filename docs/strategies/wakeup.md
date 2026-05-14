# Wakeup

You already have an **`IO.select`** loop juggling real sockets. **Wakeup** hands
you an extra pipe—backed by a **`CancellationToken`**—so the select set can also
react when **your deadline fires**, not only when bytes arrive.

**Mental model:** add a tiny doorbell next to the mailbox. Mail still matters,
but now “time’s up” rings too.

## Quick example

```ruby
wake = TIMEx::Strategies::Wakeup.new(2.0)
begin
  ready, = ::IO.select([sock, wake.read_io], nil, nil)
  if ready.include?(wake.read_io)
    # deadline fired—handle cancellation gracefully
  end
ensure
  wake.close
end
```

Each `Wakeup` is **single-use**: always `close` in an `ensure` block, and build
a fresh instance for the next operation. The pipe and watcher thread leak if
you forget.

## At a glance

| Topic | Plain English |
| --- | --- |
| CPU-heavy Ruby | Does **not** interrupt tight loops—you still need checkpoints elsewhere. |
| Blocking IO inside `select` | Yes: **`select` returns** when the wakeup side is readable. |
| Mutexes / shared state | Gentle pattern: you choose what happens after `select` wakes. |
| Runs everywhere | Plain MRI. |
| How tight the timeout is | Millisecond-ish in practice. |
| Cost | One **pipe** plus a small **watcher thread** doing the bookkeeping. |

## Manual “ring the bell”

```ruby
wake.cancel!(reason: :user_aborted)
wake.fired?  # => true
```

Use this when **you** want to abort early—user clicked cancel, upstream told you
to stop, etc.

## Real-world: long-poll endpoint that returns 204 instead of hanging

A mobile client long-polls `/inbox/wait` for up to 25 s. You subscribe to a
Redis pub/sub channel and want `select` to wake on **either** a new message
**or** the deadline—never both clients sitting on dead sockets:

```ruby
get "/inbox/wait" do
  sub = redis.subscribe_socket("inbox:#{current_user.id}")
  wake = TIMEx::Strategies::Wakeup.new(25.0)
  begin
    ready, = ::IO.select([sub, wake.read_io], nil, nil)
    if ready.include?(wake.read_io)
      halt 204
    else
      [200, { "Content-Type" => "application/json" }, [sub.read_message]]
    end
  ensure
    wake.close
    sub.close
  end
end
```

No per-request thread killing, no `Timeout.timeout` wrapping a Redis read—the
kernel’s own `select` handles the wait and the doorbell rings on schedule.
