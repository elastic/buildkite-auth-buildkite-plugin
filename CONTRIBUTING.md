# Contributing

## Development

Run these Makefile targets locally before opening a PR:

- `make test` - runs the BATS unit tests
- `make plugin-lint` - validates `plugin.yml` and the README usage examples
- `make shellcheck` - lints the hook scripts

`make all` runs everything above.

## CI

`.buildkite/pipeline.yml` runs `test`, `plugin-lint`, and `shellcheck` on every push.
