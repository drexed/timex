<div align="center">
  <img src="./src/timex-light-logo.png#gh-light-mode-only" width="200" alt="TIMEx Light Logo">
  <img src="./src/timex-dark-logo.png#gh-dark-mode-only" width="200" alt="TIMEx Dark Logo">

  ---

  Build business logic that’s powerful, predictable, and maintainable.

  [Home](https://drexed.github.io/timex) ·
  [Documentation](https://drexed.github.io/timex/getting_started) ·
  [Blog](https://drexed.github.io/timex/blog) ·
  [Changelog](./CHANGELOG.md) ·
  [Report Bug](https://github.com/drexed/timex/issues) ·
  [Request Feature](https://github.com/drexed/timex/issues) ·
  [AI Skills](https://github.com/drexed/timex/blob/main/skills) ·
  [llms.txt](https://drexed.github.io/timex/llms.txt) ·
  [llms-full.txt](https://drexed.github.io/timex/llms-full.txt)

  <img alt="Version" src="https://img.shields.io/gem/v/timex">
  <img alt="Build" src="https://github.com/drexed/timex/actions/workflows/ci.yml/badge.svg">
  <img alt="License" src="https://img.shields.io/badge/license-LGPL%20v3-blue.svg">
</div>

# TIMEx

Say goodbye to messy service objects. TIMEx helps you design business logic with clarity and consistency—build faster, debug easier, and ship with confidence.

> [!NOTE]
> [Documentation](https://drexed.github.io/timex/getting_started/) reflects the latest code on `main`. For version-specific documentation, refer to the `docs/` directory within that version's tag.

## What you get

- **Standardized task contract** — typed inputs, declared outputs, explicit halts
- **Type system** — 13 coercers, 7 validators, all pluggable
- **Built-in flow control** — `skip!` / `fail!` / `throw!` with structured metadata
- **Retries and faults** — declarative `retry_on` with configurable jitter
- **Middleware and callbacks** — wrap the lifecycle without touching `work`
- **Observability** — structured logs and telemetry, no extra instrumentation
- **Composable workflows** — chain tasks into larger processes

See the [feature comparison](https://drexed.github.io/timex/comparison/) for how TIMEx stacks up against other service-object gems.

## Requirements

- Ruby: MRI 3.3+ or a compatible JRuby/TruffleRuby release

## Installation

```sh
gem install timex
# - or -
bundle add timex
```

## Quick Example

TODO: Add docs

## Contributing

Bug reports and pull requests are welcome at <https://github.com/drexed/timex>. We're committed to fostering a welcoming, collaborative community. Please follow our [code of conduct](CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [LGPLv3 License](https://www.gnu.org/licenses/lgpl-3.0.html).
