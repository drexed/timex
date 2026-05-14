# Cooperative

This is TIMEx’s **default** strategy: you promise to peek at the clock now and then, and TIMEx promises not to surprise you with magic interrupts.

**Mental model:** a hike where *you* choose every safe rest stop. The trail (`deadline.check!`) is where you look at your watch. If you never stop, nobody pulls you off the path—you just might finish late.

## Quick example

```ruby
TIMEx.deadline(2.0) do |d|
  rows.each do |row|
    d.check!
    process(row)
  end
end
```

`TIMEx.deadline` hands you a **`Deadline`** as `d`. Sprinkle **`check!`** inside loops you own. When time is up, the next `check!` raises **`TIMEx::Expired`**. The strategy also runs a final `check!` after your block returns, so a long non-cooperative tail still surfaces as `Expired` instead of silently overrunning.

## At a glance

| Topic                         | Plain English                                                                                                                                                                           |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPU-heavy work                | Only stops at your **`check!`** calls (or turn on [auto-check](https://drexed.github.io/timex/auto_check/index.md) if you cannot edit the loop).                                        |
| Blocking IO                   | Does **not** cut off a stuck `read`—reach for [IO](https://drexed.github.io/timex/strategies/io/index.md) or [Closeable](https://drexed.github.io/timex/strategies/closeable/index.md). |
| Mutexes and shared state      | Friendly: no random thread exceptions mid-update.                                                                                                                                       |
| Runs everywhere               | MRI, no extra gems—this is the boring portable choice.                                                                                                                                  |
| How “tight” the timeout feels | As fine as you make your checkpoints.                                                                                                                                                   |
| Nesting                       | Yes—combine budgets with **`Deadline#min`**.                                                                                                                                            |
| Runtime cost                  | Basically free between checkpoints.                                                                                                                                                     |

## One sharp edge: `rescue Exception`

**`TIMEx::Expired`** subclasses **`Exception`**, not **`StandardError`**, so a normal `rescue => e` will **not** swallow it. Good.

A wide `rescue Exception` **will** catch it on purpose. If legacy code might do that, wrap the work in **[TwoPhase](https://drexed.github.io/timex/composers/two_phase/index.md)** so a cooperative phase still gets a hard backstop:

```ruby
TIMEx::Composers::TwoPhase.new(
  soft: :cooperative, hard: :unsafe, grace: 0.5, hard_deadline: 1.0,
  idempotent: true
).call(deadline: 2.0) { legacy_block }
```

`bin/timex-lint` nags about bare `rescue` and `rescue Exception` inside `TIMEx.deadline` blocks—listen to it.

## Real-world: nightly Sidekiq export that yields before SIGTERM

Sidekiq workers get ~25 s of grace on shutdown. A nightly export that walks `User.find_each` in batches needs to finish a batch and **stop** before the grace window closes—otherwise the worker dies mid-upload and tomorrow’s job re-processes the same rows. `check!` between batches is enough:

```ruby
class NightlyExportJob
  include Sidekiq::Job

  def perform(export_id)
    TIMEx.deadline(20.0) do |deadline|
      User.find_each(batch_size: 500) do |user|
        deadline.check!
        ExportRow.upsert(user.attributes, export_id: export_id)
      end
    end
  rescue TIMEx::Expired
    NightlyExportJob.perform_in(1.minute, export_id)
  end
end
```

The `check!` lands at safe places (between rows, no half-written upsert), and the rescue re-enqueues so progress resumes cleanly on the next worker.
