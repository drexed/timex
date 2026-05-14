# Cancellation Token

Sometimes you need a **loud “stop, please”** flag that many threads can read, and
a few friendly callbacks when the flag flips. That is
**`TIMEx::CancellationToken`**: a thread-safe, one-shot cancel switch with
observer hooks.

Composers like **`Hedged`**, plus the **`Wakeup`** strategy,
use this under the hood. You can also use it directly when **your** code owns
the lifecycle and you want the same “cancel + reason” vocabulary.

## Quick example

```ruby
token = TIMEx::CancellationToken.new

token.on_cancel do |reason|
  release_resources(reason)
end

# Somewhere else in the app
token.cancel(reason: :user_aborted)
token.cancelled? # => true
token.reason     # => :user_aborted
```

## Rules of the road

| Behavior | Plain English |
| --- | --- |
| Observers registered **after** cancel | They still run—TIMEx does not leave new listeners hanging. |
| Second `cancel` | **Idempotent:** returns `false`, does not spam callbacks again. |
| `reason` | Optional symbol or object so teardown code knows *why* life ended. |

Think of it as a tiny pub/sub for “we are done here,” without inventing your own
mutex soup.

## When to reach for it

- You are threading cancellation through **your** layers and want one shared
  object.
- You are composing TIMEx pieces and need the same semantics the built-in
  strategies expect.

If you only need “stop this TIMEx block,” a **`Deadline`** plus `check!` is
usually simpler—tokens shine when cancellation is **orthogonal** to the time
budget.

## Real-world: user clicks “Cancel export”

A CSV export streams rows into S3. A producer thread reads from the DB while
an uploader thread pushes parts. When the user hits **Cancel** in the UI, the
controller flips one token—both threads notice on their next loop iteration,
and the `on_cancel` hook logs *why* so support has a trail:

```ruby
token = TIMEx::CancellationToken.new
token.on_cancel { |reason| Rails.logger.info("export aborted: #{reason}") }

producer = Thread.new do
  User.find_each(batch_size: 500) do |user|
    break if token.cancelled?
    queue << UserExportRow.from(user)
  end
end

uploader = Thread.new do
  multipart = S3.start_multipart(bucket: "exports", key: export_id)
  until token.cancelled? || queue.empty?
    multipart.upload_part(queue.pop)
  end
  token.cancelled? ? multipart.abort : multipart.complete
end

# In the controller action that handles DELETE /exports/:id
token.cancel(reason: :user_aborted)
```

Two unrelated threads, one switch, predictable teardown—no `Thread#kill`,
no half-uploaded zombie part lingering in S3.
