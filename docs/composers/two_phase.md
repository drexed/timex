# TwoPhase

Sometimes you want the polite timeout first—*please exit at the deadline*—and
a louder option only if the code ignores you. **TwoPhase** does exactly that: it
runs a **soft** strategy (usually cooperative `check!`), gives you a **grace**
window past the primary deadline, then escalates to a **hard** strategy if the
soft path is still stuck.

**Mental model:** “ask nicely, then send the bouncer.” Good for legacy blocks
where you hope for a clean finish but still need a kill switch.

**Non‑negotiable:** pass **`idempotent: true`**. On escalation TIMEx
**`Thread#kill`s** the soft worker and runs your block **again** under the hard
strategy—the constructor raises if you skip that handshake.

## What it does

1. **Soft phase** — your block runs under the outer `deadline:` you pass to
   `#deadline` (same as a normal `TIMEx.deadline`).
2. **Grace** — TIMEx waits the soft phase's initial budget plus **`grace`**
   seconds for the worker thread to finish (when the outer deadline is finite;
   infinite outer deadlines wait forever for the soft phase). If it returns in
   time, you are done; life is good.
3. **Hard phase** — if soft work overruns that window, the soft worker is
   **`kill`ed** and the **hard** strategy runs the **same block** again under
   **`Deadline.in(hard_deadline).min(outer_deadline)`** so escalation never
   extends the caller’s budget.

Pick **soft** and **hard** like stair steps: cooperative first, subprocess or
unsafe only if you accept the sharper edges.

## Quick example

```ruby
TIMEx::Composers::TwoPhase.new(
  soft: :cooperative,   # tries clean exit via check!
  hard: :subprocess,    # OS-level backstop if soft is wedged
  grace: 0.5,
  hard_deadline: 1.0,
  idempotent: true      # required — block may run twice
).call(deadline: 2.0) { work }
```

## Real-world: preview pipeline with a hard kill

A document preview job first tries to exit cleanly (cooperative `check!` around
Ruby steps), but if a native renderer wedges, you still need the worker slot
back. **`idempotent: true`** fits when “run preview again” just overwrites a
temp file or cache key:

```ruby
TIMEx::Composers::TwoPhase.new(
  soft: :cooperative,
  hard: :subprocess,
  grace: 1.0,
  hard_deadline: 5.0,
  idempotent: true
).call(deadline: 15.0) { generate_pdf_preview!(input_path) }
```

Tune `grace` / `hard_deadline` to your P99 soft time plus how long the OS-level
child is allowed to burn before you give up entirely.

## Picking soft + hard (cheat sheet)

| Situation | Soft | Hard |
| --- | --- | --- |
| Greenfield Ruby you can edit | `:cooperative` | `:subprocess` |
| Legacy you cannot touch today | `:unsafe` | `:subprocess` |
| Tests where forks are annoying | `:cooperative` | `:unsafe` |
| Rack handler in a short-lived worker | `:cooperative` | `:unsafe` (process rotates anyway) |

If your soft block might **`rescue Exception`**, read [Cooperative](../strategies/cooperative.md)—that pattern can swallow cooperative expiry, which is exactly why TwoPhase exists.

## Telemetry

TwoPhase emits **`composer.two_phase`** so you can see how often you needed the
bouncer. Payload includes **`outcome:`**

| Outcome | Meaning |
| --- | --- |
| `:ok` | Soft phase finished in time—hard never ran. |
| `:soft_timeout` | Soft strategy raised `TIMEx::Expired` (time really ran out in the polite phase). |
| `:error` | Your block raised a normal error during the soft phase—TIMEx records it, then re-raises. |
| `:hard_timeout` | Soft work blew past **grace**, the hard phase ran, **and** it still hit `TIMEx::Expired`—time to dig into C extensions, `rescue Exception`, or a too-tight `hard_deadline`. |

Full event wiring lives in [Telemetry](../telemetry.md).
