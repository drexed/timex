# Comparison

Picking a timeout story is less scary when you line the options up next to each other. This page is a cheat sheet: stdlib `Timeout`, common async timeouts, and TIMEx—without pretending they are the same tool.

## At a glance

| Concern                      | ⏱️ stdlib `Timeout`              | ⚡ `Async::Task#with_timeout`   | ⏰ TIMEx                                          |
| ---------------------------- | -------------------------------- | ------------------------------- | ------------------------------------------------- |
| 🧭 Default strategy          | Async exception (`Thread#raise`) | Fiber-scheduler aware           | Cooperative checkpoint                            |
| 🛡️ Safe for shared state     | ❌ No                            | ✅ Yes (inside the fiber model) | ✅ Yes                                            |
| 🖥️ Interrupts CPU-bound work | ⚠️ Yes (risky)                   | ❌ No                           | 🔧 Opt-in (`auto_check`, `Subprocess`, …)         |
| 💿 Interrupts blocking IO    | ✅ Yes (often)                   | ✅ Yes                          | ✅ Yes (`IO` strategy)                            |
| 🔌 Per-syscall IO timeouts   | ❌ No                            | 🔧 Indirect                     | ✅ Yes (`IO.read` / `write` / `connect`)          |
| 🌐 Cross-host propagation    | ❌ No                            | ❌ No                           | ✅ `X-TIMEx-Deadline` header                      |
| 🧩 Pluggable strategies      | ❌ No                            | ❌ No                           | ✅ Registry + companion gems                      |
| 📊 Telemetry                 | ❌ No                            | 🔧 Some                         | ✅ Active Support / OpenTelemetry / Logger / Null |
| ⏳ Grace + escalation        | ❌ No                            | 🔧 Manual                       | ✅ `TwoPhase` composer                            |
| 🎯 Hedged execution          | ❌ No                            | ❌ No                           | ✅ `Hedged` composer                              |
| 📈 Adaptive timeout          | ❌ No                            | ❌ No                           | ✅ `Adaptive` composer                            |

Native timeouts beat *all* of these

Before stdlib `Timeout`, `Async`, **or** TIMEx, set the timeout your client already ships with — `Net::HTTP#read_timeout`, `redis-rb` `:read_timeout`, `pg` `statement_timeout`, gRPC per-call `deadline:`, etc. Those run inside the driver and actually stop the IO. Use TIMEx to coordinate a *budget across* those native timeouts, not to replace them.

## When stdlib is still fine

- Throwaway scripts where “good enough” beats “provably safe”.
- A single block of pure Ruby you have read end-to-end and you accept async interruption there.
- Places you have already audited for mutexes, half-written buffers, and `rescue Exception` swallowing timeouts.

## When TIMEx is the happier path

- Library code that should be safe for strangers to call.
- Multi-tier systems where one budget should flow through the whole tree.
- Work stuck in C extensions that ignore Ruby interrupts.
- Teams whose current plan B is “kill the worker and hope”.
