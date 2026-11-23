# AGENTS.md

Guidance for AI coding agents working in this repository. Human contributors
should read [CONTRIBUTING.md](CONTRIBUTING.md); users should read the
[README](README.md).

## Project

A Buildkite plugin (`elastic/buildkite-auth`) that exchanges a job's agent OIDC
token for a short-lived Buildkite REST API token via Workload Identity
Federation and exports it to the job command. It is a single Bash hook.

- `plugin.yml` — configuration schema (`additionalProperties: false`).
- `hooks/pre-command` — all runtime logic.
- `tests/unit/pre-command.bats` — BATS tests with stubbed `buildkite-agent`
  and `curl`.

## Commands

Docker with Docker Compose is required.

```sh
make all          # run everything below; must pass before a PR
make test         # BATS unit tests
make plugin-lint  # buildkite/plugin-linter
make shellcheck   # ShellCheck on hooks/
```

## Rules

- **Never leak secrets.** The OIDC token, exchange response, and API token must
  never be printed, traced, passed as command-line arguments, or included in
  error output. Keep `set +x` and `set -euo pipefail`; pass secrets via stdin.
- Register the token with `buildkite-agent redactor add` before exporting it.
  Fail closed on every error; never fall back to a stored credential.
- For any option change, update `plugin.yml`, the hook (defaults **and**
  validation), BATS tests, and the README **Configuration** table together.
  Options map to `BUILDKITE_PLUGIN_BUILDKITE_AUTH_<OPTION>` (upper-case, `-` →
  `_`).
- Failure-path tests must assert the `buildkite-auth:` error message and
  `refute_output` any secret values. Stubs must match exact arguments.
- Keep runtime dependencies to Bash, `curl`, `jq`, and `buildkite-agent`.
- Keep user documentation in `README.md` and contributor documentation in
  `CONTRIBUTING.md`.
- Do not hand-edit README plugin version references; a workflow bumps them
  after release.
- Do not change the live E2E step in `.buildkite/default-pipeline.yml` or the
  `BUILDKITE_WIF_CLIENT_ID` without maintainer approval.

## Pull requests

Every PR needs exactly one `changelog:*` label (see `docs/RELEASE.md`). Use
`changelog:breaking` for removed/renamed options, changed defaults, or a
changed exported variable.
