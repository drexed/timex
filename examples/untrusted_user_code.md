# Untrusted user code

Run user-supplied Ruby under three independent ceilings: a wall-time
deadline (TIMEx), a CPU-time `rlimit`, and an address-space `rlimit`.
The subprocess strategy gives the OS the right to SIGKILL the child —
the parent's mutexes, fds, and DB pool are never touched.

```ruby
require "timex"

def run_untrusted(source, deadline: 1.0, memory_mb: 256)
  TIMEx.deadline(deadline, strategy: :subprocess, kill_after: 0.5) do
    Process.setrlimit(Process::RLIMIT_CPU,    deadline.ceil + 1)
    Process.setrlimit(Process::RLIMIT_AS,     memory_mb * 1024 * 1024)
    Process.setrlimit(Process::RLIMIT_NOFILE, 32)
    Process.setrlimit(Process::RLIMIT_NPROC,  0) # no further forks

    sandbox = Module.new
    sandbox.module_eval(source, "(untrusted)", 1)
  end
rescue TIMEx::Expired
  { error: "timeout", budget_ms: deadline.is_a?(Numeric) ? (deadline * 1000).round : nil }
end

result = run_untrusted("(1..1_000).inject(:+)", deadline: 1.0)
```

Layered defense:

- **Subprocess** is the load-bearing isolation: parent memory is not
  shared after the fork, so a runaway allocation or mutex panic stays
  in the child.
- **`RLIMIT_CPU`** is the kernel's backstop for CPU spin loops — TIMEx
  bills wall time, which doesn't fire when the child is happily
  burning a core inside a tight loop with no IO.
- **`RLIMIT_AS`** caps the address space; **`RLIMIT_NOFILE`** /
  **`RLIMIT_NPROC: 0`** stop the child from opening files or forking
  again.
- **`kill_after: 0.5`** is the SIGTERM-to-SIGKILL window — short
  because nothing the child is allowed to do warrants a graceful
  shutdown.

Real production sandboxes layer this with seccomp / Linux user
namespaces / a chrooted filesystem. TIMEx handles the *deadline* half
of the problem; the rest belongs to your security team.

See [Subprocess](../docs/strategies/subprocess.md).
