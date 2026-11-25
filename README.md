# Buildkite Auth Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/plugins) that exchanges a job's
agent OIDC token for a short-lived Buildkite REST API token using
[Workload Identity Federation (WIF)](https://buildkite.com/docs/apis/workload-identity-federation),
and exports it to the job's command. No stored API token is required.

An organization administrator must first create a **Buildkite Agents** workload
identity; see [Administrator setup](#administrator-setup).

## Quick start

### Minimal

Exports the token as `BUILDKITE_API_TOKEN`:

```yaml
steps:
  - label: "Read target pipeline builds"
    key: read-target-builds
    command: |
      printf 'Authorization: Bearer %s\n' "$$BUILDKITE_API_TOKEN" |
        curl --fail --silent --show-error -H @- \
          "https://api.buildkite.com/v2/organizations/YOUR_ORG_SLUG/pipelines/TARGET_PIPELINE_SLUG/builds"
    plugins:
      - elastic/buildkite-auth#v0.1.0:
          client-id: "YOUR_WORKLOAD_IDENTITY_CLIENT_ID"
          scope: "read_builds"
```

The default `audience` is Elastic's Buildkite organization. For any other
organization or audience, also set `audience`.

`$$` defers expansion until the command runs instead of during pipeline upload;
in a checked-in script use `$BUILDKITE_API_TOKEN`. Piping the header into
`curl -H @-` keeps the token out of process arguments.

### Existing `BUILDKITE_TOKEN_SECRET` consumers

Use `env-var` to keep a legacy variable name, with every option set explicitly:

```yaml
steps:
  - label: "Read target pipeline builds"
    key: read-target-builds
    command: .buildkite/scripts/read-target-builds.sh # reads $BUILDKITE_TOKEN_SECRET
    plugins:
      - elastic/buildkite-auth#v0.1.0:
          client-id: "YOUR_WORKLOAD_IDENTITY_CLIENT_ID"
          audience: "YOUR_WORKLOAD_IDENTITY_AUDIENCE"
          scope: "read_builds"
          lifetime: 3600
          env-var: BUILDKITE_TOKEN_SECRET
```

The plugin exports only the configured variable, not `BUILDKITE_API_TOKEN` as
well. Renaming the variable does not remove existing token fetches that run
before the plugin; see [Migrating from a stored token](#migrating-from-a-stored-token).

## Configuration

The [schema](plugin.yml) rejects unknown options. The
[hook](hooks/pre-command) applies the defaults and validates values again.

### `client-id` (required, string)

The workload identity's **Client ID**. Must be non-empty. Not a secret.

### `audience` (optional, string)

The OIDC audience requested from the agent. Must exactly match the workload
identity's **OIDC audience**. Not a secret.

Default: `https://api.buildkite.com/v2/organizations/e0f3970e-3a75-4621-919f-e6c773e2bb12`
(Elastic's Buildkite organization).

### `scope` (optional, string)

Space-separated API scopes to request, for example `read_builds read_pipelines`.
Must be a subset of the identity's **Grantable Scopes**.

Default: omitted. When omitted or empty, Buildkite grants the identity's
**Default Scopes**.

### `lifetime` (optional, integer)

Requested OIDC token lifetime in seconds, from `1` to `3600`. This is not a
guaranteed API token lifetime; see [Token lifetime](#token-lifetime).

Default: `3600`.

### `env-var` (optional, string)

Name of the environment variable to export the API token as. Must match
`^[A-Za-z_][A-Za-z0-9_]*$`.

Default: `BUILDKITE_API_TOKEN`.

## Requirements

- WIF enabled for your Buildkite organization. It is currently an Enterprise
  **private preview**; contact Buildkite Support for access.
- A dedicated, administrator-created Buildkite workload identity with
  **Provider: Buildkite Agents**.
- Bash, `curl`, `jq`, and `buildkite-agent` on the agent's hook `PATH`. The
  agent must support `oidc request-token` with `--audience` and `--lifetime`,
  and `redactor add --format none`.
- Network access from the agent to the Buildkite agent API and
  `https://buildkite.com/oauth/token`, and from the command to
  `https://api.buildkite.com`. Any identity IP allowlists must permit both the
  token exchange and API usage.

## Administrator setup

The plugin does not create workload identities, grant access, or revoke old
credentials. An organization administrator configures these in
[Workload Identities](https://buildkite.com/organizations/~/workload-identities).

### Trust the source job

Create a workload identity with **Provider: Buildkite Agents** and issuer
`https://agent.buildkite.com`. Copy its **Client ID** and **OIDC audience** into
the plugin configuration.

Restrict the trust policy to the pipeline that **runs the consuming job** (the
source pipeline), its intended branch, and step. For the `read-target-builds`
step on `main`, use this OIDC subject with your organization and source
pipeline slugs:

```text
organization:YOUR_ORG_SLUG:pipeline:SOURCE_PIPELINE_SLUG:ref:refs/heads/main:commit:*:step:read-target-builds
```

In **Claims**, require the source organization's UUID:

```json
{
  "organization_id": "00000000-0000-4000-8000-000000000001"
}
```

In **Claim conditions**, also require the source pipeline's UUID, branch, and
step key:

```text
claims.pipeline_id == "00000000-0000-4000-8000-000000000002"
  && claims.build_branch == "main"
  && claims.step_key == "read-target-builds"
```

The UUIDs are placeholders. Prefer immutable IDs over slugs, which can be
renamed and reused. All Buildkite organizations share the agent issuer, so
Buildkite requires `organization_id` or `organization_slug` in **Claims**. Do
not remove that restriction or broaden the subject to every pipeline. Protect
the source pipeline's code and configuration from untrusted changes.

The subject above assumes the agent's default compound OIDC subject; do not
override it with `BUILDKITE_OIDC_TOKEN_SUBJECT_CLAIM`. The plugin does not
request optional claims such as `queue_key`, so do not require them.

### Grant access to target resources

| Setting | What it controls |
| --- | --- |
| Trust policy | Which source jobs may mint tokens. |
| Resource Access | Which target resources those tokens may access. |
| Grantable Scopes | Maximum operations tokens may request. |
| Default Scopes | Operations granted when the request omits `scope`. |

Trusting a source pipeline does not grant it access to any resources. For the
build-read example, set **Resource Access > Pipelines** to **Selected** and
select only the target pipelines whose builds the job reads; these can differ
from the source pipeline. Leave teams, clusters, and test suites at **None**
unless required.

Set **Grantable Scopes** to `read_builds`, and **Default Scopes** to
`read_builds` if requests without `scope` should work. `read_pipelines` alone
does not allow reading builds. Avoid organization-administration scopes:
resource grants do not restrict them to selected pipelines.

Set an appropriate **Maximum token lifetime** (30–3600 seconds) and review the
identity's exchange and token-usage IP allowlists. Resource access starts at
**None**, not implicit organization-wide access.

## Usage with the Docker plugin

The token is exported to the agent's job environment, not into containers.
With the [Docker plugin](https://github.com/buildkite-plugins/docker-buildkite-plugin),
pass the variable **by name** with `environment`:

```yaml
steps:
  - label: "Read target pipeline builds in Docker"
    key: read-target-builds
    command: >-
      printf 'Authorization: Bearer %s\n' "$$BUILDKITE_API_TOKEN" |
      curl --fail --silent --show-error -H @-
      "https://api.buildkite.com/v2/organizations/YOUR_ORG_SLUG/pipelines/TARGET_PIPELINE_SLUG/builds"
    plugins:
      - elastic/buildkite-auth#v0.1.0:
          client-id: "YOUR_WORKLOAD_IDENTITY_CLIENT_ID"
          scope: "read_builds"
      - docker#v5.14.0:
          image: "YOUR_IMAGE_WITH_SH_AND_CURL"
          environment:
            - BUILDKITE_API_TOKEN
```

The Docker plugin runs as the job's command, after this plugin's
`pre-command` hook, and turns `BUILDKITE_API_TOKEN` into `--env
BUILDKITE_API_TOKEN`, so Docker reads the value from the environment. Do not use
the `NAME=value` form, which places the token in the logged `docker run`
arguments. `propagate-environment: true` alone does not pass the token, because
it only includes pipeline variables, not variables exported by hooks. If you
set `env-var`, list that name instead.

## Lifecycle and limitations

### Hook order

The plugin runs in the **plugin `pre-command`** phase. It requests an OIDC
token, exchanges it at `https://buildkite.com/oauth/token`, registers the API
token with the agent's log redactor, and then exports it. The token is
available to the command, later plugin `pre-command` hooks, and later phases.

Agent and repository `pre-command` hooks run **before** plugin `pre-command`
hooks, so they cannot use the token and cannot detect that this plugin will
replace an existing variable. Any token they fetch is still fetched.

The hook fails the job on any OIDC, exchange, invalid-token, or redaction
error. It never falls back to a stored credential.

### Exchange rate limits

Buildkite allows up to 50 token exchanges per minute for each workload identity.
If several jobs start at once and hit that limit, Buildkite returns HTTP `429`
and tells the plugin how long to wait in the
`RateLimit-WorkloadIdentityTokenExchange-Reset` header. See Buildkite's
[rate limit documentation](https://buildkite.com/docs/apis/workload-identity-federation#exchange-an-oidc-token-rate-limit).

The plugin waits for that interval plus a random 1–3 seconds, then tries again
with a fresh OIDC token. It retries up to three times, with no more than five
minutes of waiting in total, including the random delays.

If the retry or wait limit is reached, or the reset header is missing, invalid,
or duplicated, the hook fails rather than guessing how long to wait. It also
fails if it cannot reliably determine the HTTP status or headers. Other HTTP
errors and network failures are not retried.

Each exchange has a 10-second connection timeout and a 30-second total timeout.
These exchange timeouts are separate from the five-minute waiting limit. The
plugin does not set a timeout for the agent's OIDC token request, so the limit
does not bound the hook's total runtime.

### Token lifetime

The plugin mints **one token per job and does not refresh it**. The token
expires no later than its OIDC token or the identity's **Maximum token
lifetime**, so it can last **less than the requested `lifetime`**, including
time already spent on the exchange. The plugin does not request an API `expires_in` or expose the
expiry. Long-running commands must finish API usage before expiry or implement
their own renewal. Each new exchange needs a **new OIDC token**; Buildkite
accepts an agent OIDC token only once.

### Supported APIs

WIF tokens work only with the
[documented REST API subset and scopes](https://buildkite.com/docs/apis/workload-identity-federation/supported-endpoints).
They do **not** work with GraphQL, Package Registries, secrets, or workload
identity management. Check every consumer's endpoints before migrating.

### Security

The `client-id` and `audience` are **not secrets** and may be committed. The
OIDC token and the **exported API token are secrets**: do not print them,
enable shell tracing around their use, pass them as command-line arguments, or
store them in artifacts. Redaction reduces accidental log exposure; it does not
stop commands in the job from reading the token.

## Migrating from a stored token

Setting `env-var: BUILDKITE_TOKEN_SECRET` lets existing scripts read the WIF
token under the old name. It does **not** stop earlier hooks from fetching the
stored token, nor revoke it. To migrate:

1. Inventory each job's API calls, target pipelines, and durations, and confirm
   WIF supports those endpoints.
2. Have an administrator create a restricted identity with only the necessary
   resources and scopes, then add the plugin to the selected jobs.
3. Remove or skip the stored-token fetches for migrated jobs, keeping those that
   unmigrated consumers still need. Account for [hook order](#hook-order).
4. Validate the API calls, then revoke the stored token only after every
   remaining consumer has been migrated.

The [observability-robots migration guide](docs/migrating-observability-robots.md)
walks through these steps for that repository's Vault-based hook.

## References

- [Buildkite Agents WIF setup](https://buildkite.com/docs/apis/workload-identity-federation/buildkite-agents)
- [Workload identity configuration and token lifetime](https://buildkite.com/docs/apis/workload-identity-federation)
- [Supported endpoints and scopes](https://buildkite.com/docs/apis/workload-identity-federation/supported-endpoints)
- [OIDC command and claims](https://buildkite.com/docs/agent/cli/reference/oidc)

## Contributing

To develop the plugin, including local checks, adding options, tests, and pull
request labels, see [CONTRIBUTING.md](CONTRIBUTING.md). Maintainers publishing
a version should follow the [release process](docs/RELEASE.md).
