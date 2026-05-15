# LLM calls with [RubyLLM](https://rubyllm.com/) + TIMEx

[RubyLLM](https://rubyllm.com/) is a single Ruby API over OpenAI, Anthropic,
Gemini, Ollama, and other providers. Under the hood it uses **Faraday** with
**`config.request_timeout`** mapped to **`Faraday::RequestOptions#timeout`**
(default **300** seconds in current RubyLLM)—so a stalled remote is not
literally infinite, but a Puma or Sidekiq thread can still sit blocked for
minutes unless you **tighten that knob** from your own budget.

TIMEx gives you a **`Deadline`** for the *whole* interaction (RubyLLM retries,
JSON handling, your glue code) while **`RubyLLM.context`** hands Faraday a
**per-call `request_timeout`** derived from **`deadline.remaining`**, so the
HTTP stack fails fast instead of “hanging” until the library default.

This page is **not** a RubyLLM tutorial—see their [Getting Started](https://rubyllm.com/getting-started)—and **`ruby_llm`** is not a dependency of the
`timex` gem; add it to your app’s Gemfile alongside TIMEx.

## Install

```ruby
# Gemfile
gem "timex"
gem "ruby_llm"
```

## One bounded completion

Configure provider keys once (initializer or boot), then cap each completion
with **`TIMEx.deadline`** + **`RubyLLM.context`**:

```ruby
require "timex"
require "ruby_llm"

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

TIMEx.deadline(45.0) do |deadline|
  raise deadline.expired_error(strategy: :io, message: "llm: no budget left") if deadline.remaining <= 0

  ctx = RubyLLM.context do |cfg|
    cfg.request_timeout = [deadline.remaining, 0.01].max
  end

  reply = ctx.chat(model: "gpt-4o-mini").ask("Summarize TIMEx in one sentence.")
  reply.content
end
```

- **`request_timeout`** is what RubyLLM’s Faraday stack uses for the blocking
  HTTP phase—this is the main fix for “stuck on the model forever” when you
  want a shorter wall than the gem default.
- **`TIMEx.deadline`** still applies a cooperative ceiling around the Ruby
  work: if you add loops, file IO, or extra calls, sprinkle **`deadline.check!`**
  or use **`auto_check: true`** (see [Auto-check](../docs/auto_check.md)).

## Propagate the deadline header

If this completion triggers another HTTP hop you control (RAG service, your
own API), reuse the same budget on the wire:

```ruby
TIMEx.deadline(45.0) do |deadline|
  ctx = RubyLLM.context do |cfg|
    cfg.request_timeout = [deadline.remaining, 0.01].max
  end

  hdr = TIMEx::Propagation::HttpHeader::HEADER_NAME

  ctx.chat(model: "gpt-4o-mini")
    .with_headers(hdr => deadline.to_header)
    .ask("Hello")
end
```

See [HTTP header propagation](../docs/propagation/http_header.md).

## Prefer a `TIMEx::Result` on expiry

With **`on_timeout: :result`**, a cooperative overrun returns **`TIMEx::Result`**
while a normal completion still returns the block value (here, a string).

```ruby
reply = TIMEx.deadline(45.0, on_timeout: :result) do |deadline|
  ctx = RubyLLM.context do |cfg|
    cfg.request_timeout = [deadline.remaining, 0.01].max
  end

  ctx.chat(model: "gpt-4o-mini").ask("Ping.").content
end

text =
  case reply
  when TIMEx::Result then nil # inspect reply.error / reply.timeout?
  else reply
  end
```

## Streaming

Streaming **`ask { |chunk| ... }`** still rides the same Faraday connection;
**`request_timeout`** applies to the long-lived response body read. If chunks
arrive slowly but steadily, pick a budget that matches worst-case stream length,
or split streaming into smaller TIMEx blocks—see [IO strategy](../docs/strategies/io.md)
for manual **`read`** loops.

## Retries vs one budget

RubyLLM enables Faraday **`request :retry`** for posts. A single
**`request_timeout`** does not automatically shrink between attempts; if you
need every retry to see less wall time, combine TIMEx with a Faraday stack that
reads **`Deadline`** per request (see [Faraday middleware](faraday_middleware.md))
or rebuild **`RubyLLM.context`** on each retry with a fresh
**`deadline.remaining`**.

## Raw HTTP without RubyLLM

If you call **`Net::HTTP`** directly, set **`open_timeout` / `read_timeout` /
`write_timeout`** from **`deadline.remaining`** instead of relying on TIMEx
alone—see [Net::HTTP request with deadline](net_http_request.md).
