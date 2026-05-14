# HTTP header propagation

Your browser (or service A) decides: *“I will wait at most two seconds for this whole adventure.”* **HTTP header propagation** is how that decision hops onto the next HTTP call so service B does not keep grinding after the caller already gave up. One budget, many hops—less wasted work downstream.

Think of **`X-TIMEx-Deadline`** as a sticky note on the request: “share this `Deadline` with everyone downstream.” TIMEx knows how to read it, write it, and watch the clock when wall time and local time disagree a little.

## Why a header?

Without a shared signal, every microservice invents its own timeout. You end up with five nested timers that do not talk to each other. A header keeps the story linear: **one remaining budget** travels with the request.

## Wire format

```text
X-TIMEx-Deadline: ms=1837;origin=svcA;depth=2
X-TIMEx-Deadline: wall=2026-05-12T19:01:00.123Z;origin=svcA
```

| Piece          | Plain English                                                                                                                |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `ms=N`         | Milliseconds left, anchored on **monotonic** time—great inside one data center.                                              |
| `wall=ISO8601` | Absolute stop time on the wall clock—handy when boxes are loosely synced and you still want a shared “stop at this instant.” |
| `origin=name`  | Optional label for who started the budget (handy in logs).                                                                   |
| `depth=N`      | How many hops this budget has traveled; TIMEx bumps it when you propagate again.                                             |

More on building and reading `Deadline` values: [Deadline](https://drexed.github.io/timex/basics/deadline/index.md).

## Server side (Rack)

Most apps use [Rack middleware](https://drexed.github.io/timex/propagation/rack/index.md) so every request automatically parses the header. If you are wiring something custom, the parsed value also lives under `TIMEx::Propagation::RackMiddleware::ENV_KEY` (`"timex.deadline"`).

```ruby
use TIMEx::Propagation::RackMiddleware

# Later, for example in a controller:
deadline = request.env["timex.deadline"]
TIMEx.deadline(deadline) { call_downstream(deadline) }
```

## Client side (outgoing calls)

Build a header map, **inject** the deadline, send the request—no magic.

```ruby
headers = {}
TIMEx::Propagation::HttpHeader.inject(headers, deadline)
http.get(url, headers)
```

**`prefer:`** — same knob as `Deadline#to_header`. Default is `:remaining` (`ms=…`). Pass `prefer: :wall` when you want a wall-clock header instead.

If you already have a string-keyed header hash from another client library, you can parse it with `TIMEx::Propagation::HttpHeader.from_headers(headers)`.

## Real-world: gateway → auth → inventory

Picture an API gateway that gives each request a 2.5 s end-to-end budget. It parses or creates a `Deadline`, forwards the header to an auth service, then to inventory—each hop reads the same remaining slice instead of starting a fresh 2.5 s timer per HTTP call:

```ruby
# Gateway: attach shared budget to every downstream Net::HTTP / Faraday call
headers = { "Authorization" => "Bearer …" }
TIMEx::Propagation::HttpHeader.inject(headers, deadline)
auth_response = http.post("/auth/verify", body, headers)

TIMEx::Propagation::HttpHeader.inject(headers, deadline) # same object, less ms left
stock_response = http.get("/inventory/sku/#{sku}", headers)
```

If the client already sent `X-TIMEx-Deadline`, parse it with `Deadline.from_header` first and **`min`** it with your gateway ceiling so neither side over-promises.

## Skew guard (wall clock)

When the header uses `wall=`, TIMEx compares the sender’s idea of “now” to yours. If the gap is bigger than **`skew_tolerance_ms`** (default **250** in [Configuration](https://drexed.github.io/timex/configuration/index.md)), TIMEx emits a **`deadline.skew_detected`** telemetry event so you can spot bad NTP, drunk laptops, or hostile clocks before users do.
