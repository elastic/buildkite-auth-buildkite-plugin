# Contributing

This guide is for people changing the plugin. For using it in a pipeline, see
the [README](README.md).

## Repository layout

| Path | Purpose |
| --- | --- |
| [`plugin.yml`](plugin.yml) | Plugin metadata and the configuration JSON schema. Buildkite validates user configuration against it. |
| [`hooks/pre-command`](hooks/pre-command) | The only hook. Applies defaults, validates input, requests the OIDC token, exchanges it, registers the API token for redaction, and exports it. |
| [`tests/unit/pre-command.bats`](tests/unit/pre-command.bats) | BATS unit tests that stub `buildkite-agent` and `curl`. |
| [`.buildkite/`](.buildkite) | CI: `pipeline.yml` uploads `default-pipeline.yml`, which runs the checks and the live end-to-end test. |
| [`Makefile`](Makefile), [`docker-compose.yml`](docker-compose.yml), [`Dockerfile`](Dockerfile) | Local and CI check runners. |
| [`.github/`](.github) | Labels, release-drafter, and required-label workflows. |
| [`docs/RELEASE.md`](docs/RELEASE.md) | Release process for maintainers. |

## Local checks

Requirements: Docker with Docker Compose.

```sh
make all          # everything below
make test         # BATS unit tests (buildkite/plugin-tester)
make plugin-lint  # buildkite/plugin-linter against plugin.yml and README
make shellcheck   # ShellCheck on hooks/
```

The same targets run in the Buildkite pipeline. Run `make all` before opening a
pull request.

## Adding or changing a configuration option

Buildkite passes each option to the hook as
`BUILDKITE_PLUGIN_BUILDKITE_AUTH_<OPTION>`, upper-cased with `-` replaced by
`_` (for example, `env-var` becomes `BUILDKITE_PLUGIN_BUILDKITE_AUTH_ENV_VAR`).
Keep these in sync for every option change:

1. **Schema** — add or update the property in [`plugin.yml`](plugin.yml) with
   the tightest type and constraints possible. Keep
   `additionalProperties: false`; add to `required` only for mandatory options.
2. **Hook** — read the variable in [`hooks/pre-command`](hooks/pre-command) with
   an explicit default, and validate it in the hook as well. The hook must not
   rely on schema validation alone.
3. **Tests** — add BATS cases in
   [`tests/unit/pre-command.bats`](tests/unit/pre-command.bats) for the new
   behaviour and its invalid inputs. Update the `stub_oidc`/`stub_exchange`
   expectations if the `buildkite-agent` or `curl` arguments change.
4. **Docs** — update the option's entry in the README **Configuration**
   section (type, required/optional, default, and constraints) and, if
   relevant, **Quick start**, **Lifecycle and limitations**, or
   **Administrator setup**. Keep plugin references in README examples as
   `elastic/buildkite-auth#vX.Y.Z` so the release workflow can bump them.

Changing a default, removing or renaming an option, or changing the exported
variable is a breaking change (`changelog:breaking`).

## Implementation guidelines

The hook handles credentials, so keep changes conservative:

- Keep `set +x` and `set -euo pipefail` at the top. Never echo, log, or trace
  the OIDC token, exchange response, or API token, including in error paths.
  Suppress stderr from commands that may include them.
- Pass secrets via stdin (as with `client_assertion@-` and the redactor), not
  command-line arguments, and `unset` intermediate values when done.
- Register the API token with `buildkite-agent redactor add` **before**
  exporting it. Fail the hook on any error; never fall back to a stored token.
- Prefix error messages with `buildkite-auth:` and write them to stderr.
- Keep runtime dependencies to Bash, `curl`, `jq`, and `buildkite-agent`; update
  `requirements` in `plugin.yml` and the README prerequisites if that changes.
- Each exchange needs a fresh OIDC token; Buildkite accepts it only once.

## Writing tests

Tests use [bats-mock](https://github.com/buildkite-plugins/bats-mock) stubs
from the `buildkite/plugin-tester` image; no network or real agent is used.

- Stubs must match the exact arguments the hook passes. `teardown` calls
  `unstub`, so unexpected or missing calls fail the test.
- Use `source` in a subshell (see the existing export tests) when asserting on
  exported variables; run the hook directly for failure cases.
- For every failure path, assert the error message **and** use
  `refute_output` to prove secrets are not leaked.

## End-to-end test

The default Buildkite pipeline includes a live test on `main`
(`e2e-buildkite-auth` in [`.buildkite/default-pipeline.yml`](.buildkite/default-pipeline.yml)).
It loads `elastic/buildkite-auth` at the build commit, exchanges an agent OIDC
token, and uses the resulting API token to list Test Engine suites. The
non-secret `BUILDKITE_WIF_CLIENT_ID` is set in `.buildkite/pipeline.yml`.

Before enabling it, create a Buildkite pipeline for this repository and have an
administrator configure a separate Buildkite Agents workload identity. Restrict
its trust to that pipeline, `refs/heads/main`, and step `e2e-buildkite-auth`,
including the organization and pipeline ID claims. Grant `read_suites` and
access to the intended test suites. The identity's audience must match the
plugin's Elastic default. Enable the test only in a protected pipeline whose
`main` branch is trusted. The list can be empty when no suites are granted, so a
successful request alone does not prove access to a particular suite.

The test does not run on pull requests or other branches. A skipped step is not
evidence that a live exchange succeeded.

## Pull requests

- Every pull request needs **exactly one** `changelog:*` label; the
  `required-labels` workflow enforces this. The label drives the release notes
  and version bump; see the table in [docs/RELEASE.md](docs/RELEASE.md#changelog-labels).
- Labels are defined in [`.github/labels.yml`](.github/labels.yml). Keep it in
  sync with [`.github/release-drafter.yml`](.github/release-drafter.yml).
- Do not edit the plugin version references in the README by hand; the
  `bump-readme-version` workflow updates them after a release.

## Releasing

Maintainers publish releases from the release-drafter draft. See
[docs/RELEASE.md](docs/RELEASE.md).
