# IO

Sometimes the slow part is not “my Ruby loop”—it is **one stubborn `read` or `write`**. This strategy times the **syscall-shaped work**, not the whole block by magic.

**Mental model:** you set a kitchen timer on the *one dish* on the stove, not on the entire dinner party.

## Quick example

```ruby
TIMEx::Strategies::IO.read(socket, 4096, deadline: 2.0)
TIMEx::Strategies::IO.write(socket, buffer, deadline: 2.0)
sock = TIMEx::Strategies::IO.connect("example.com", 443, deadline: 2.0)
# `connect` already sets SO_RCVTIMEO/SO_SNDTIMEO from the deadline.
# Pass `apply_timeouts: false` to opt out, or call this helper yourself
# to refresh the kernel timeouts after a long pause:
TIMEx::Strategies::IO.apply_socket_timeouts(sock, deadline: 2.0)
```

Under the hood: **`IO.select`** plus **`read_nonblock`** / **`write_nonblock`**. When time is up you get **`TIMEx::Expired`** with **`strategy: :io`** and the original **`deadline_ms`** baked into the error—handy for logs.

## At a glance

| Topic                    | Plain English                                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| CPU-heavy Ruby           | Not this tool’s job—use [Cooperative](https://drexed.github.io/timex/strategies/cooperative/index.md) and `check!`. |
| Blocking IO              | Yes: the operation can bail with a clean timeout story.                                                             |
| Mutexes and shared state | Safer than yanking threads: you get errno-style flow, not surprise `raise`.                                         |
| Runs everywhere          | Plain MRI—no fork, no Ractors.                                                                                      |
| How tight the timeout is | Roughly microsecond-scale scheduling around the poll loop.                                                          |
| Nesting                  | Compose deadlines with **`min`** when you stack limits.                                                             |

## When *not* to use this exact helper

If you live on **Async / Falcon**, the fiber scheduler already cooperates with `read` / `write` / `IO.select`. Let the scheduler handle wait time and use `Cooperative` (or a future companion gem like `timex-async`) so you are not fighting the runtime twice.

## Real-world: outbound webhook with one shared budget

A webhook fan-out has to **connect, send, and read an ack** under one deadline. Splitting the budget by syscall keeps a slow TLS handshake from eating all of read time, and `connect` automatically applies SO_RCVTIMEO / SO_SNDTIMEO so the kernel honors the same number—no half-open socket trick keeps us blocked past the budget:

```ruby
def deliver_webhook(endpoint, payload, deadline:)
  uri = URI(endpoint)
  TIMEx.deadline(deadline) do |d|
    sock = TIMEx::Strategies::IO.connect(uri.host, uri.port, deadline: d)
    TIMEx::Strategies::IO.write(sock, http_request(uri, payload), deadline: d)
    TIMEx::Strategies::IO.read(sock, 4096, deadline: d)
  ensure
    sock&.close
  end
end
```

If the receiver is flaky, you get `TIMEx::Expired` with **`strategy: :io`** and the original budget in the log line—much friendlier than `Net::HTTP`’s opaque `Net::OpenTimeout`/`ReadTimeout` split.
