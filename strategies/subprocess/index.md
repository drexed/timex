# Subprocess

Need a **hard stop** on work you did not write—C extensions, wild plugins, “who knows what this gem does”? Fork a child, run the scary block there, and if time runs out send **SIGTERM**, then **SIGKILL** after **`kill_after`** (default half a second).

**Mental model:** you rent a disposable workshop for one job. If the job goes sideways, you torch the lease—not your living room.

## Quick example

```ruby
TIMEx.deadline(2.0, strategy: :subprocess) { c_extension_call }
```

The child’s return value is **`Marshal`**’d back through a pipe. Parent and child are different processes—**no shared memory** after the fork.

## At a glance

| Topic                     | Plain English                                                      |
| ------------------------- | ------------------------------------------------------------------ |
| CPU-heavy work            | Yes—**hard kill** when the deadline wins.                          |
| Blocking IO               | Yes—the whole child goes away.                                     |
| Mutexes / shared state    | Safe in the parent: the risky work never touched parent locks.     |
| Where it runs             | **Unix** only today—no `fork` on Windows or JRuby.                 |
| How chunky the timeout is | Millisecond-ish; expect **~10–50 ms** startup tax per fresh fork.  |
| Return values             | Must be **`Marshal`**-able (or push results through fds yourself). |

## Caveats (read once, sleep well)

- **Marshal** means “simple data out.” Fancy live objects usually need a different design.
- DB pools, sockets, threads: whatever existed **before** the fork is copied in a weird sibling state. **Reconnect and reopen** inside the child block if you touch the network.

## Roadmap note

A **pre-forked pool** to dodge per-call fork cost is on the wish list. For early releases, each call spins up a **new** child—plan capacity accordingly.

## Real-world: ImageMagick conversion that occasionally wedges

User-uploaded SVGs sometimes drive **`mini_magick`** (and the underlying ImageMagick C ext) into a CPU spin or a memory blow-up. Cooperative `check!` cannot reach inside the C call—but a child process can be killed by the OS:

```ruby
def thumbnail_for(blob_path, deadline: 10.0)
  TIMEx.deadline(deadline, strategy: :subprocess, kill_after: 1.0) do
    image = MiniMagick::Image.open(blob_path)
    image.resize "256x256"
    image.format "png"
    image.to_blob # Marshalled back through the pipe
  end
rescue TIMEx::Expired
  PlaceholderImage.png_bytes
end
```

The Sidekiq worker slot comes back even when ImageMagick refuses to. Just remember: the child does not share your DB pool—`to_blob` is fine because it returns plain bytes, but anything you want back must be `Marshal`-able.
