# Authenticate to the Buildkite API from Buildkite

Buildkite plugin that exchanges a job's OIDC token for a short-lived Buildkite
REST API token using [Workload Identity Federation (WIF)](https://buildkite.com/docs/apis/workload-identity-federation).
It exports the token for the job's command, without requiring a stored API token.

**No plugin release exists yet.** The example pins the existing implementation
commit, not a release tag. Review and pin an approved commit before adoption;
do not assume an illustrative version such as `v1.0.0` has been published.

## Prerequisites

- WIF enabled for your Buildkite organization. It is currently an Enterprise
  **private preview**; contact Buildkite Support for access.
- A separate, administrator-created **Buildkite Agents** workload identity,
  configured as described below. An existing AWS or Google authentication
  identity is not a substitute.
- An agent with Bash, `curl`, `jq`, and `buildkite-agent` on its hook PATH.
  The agent must support `oidc request-token` with `--audience` and `--lifetime`,
  and `redactor add --format none`.
- Network access from the agent to the Buildkite agent API and
  `https://buildkite.com/oauth/token`, and from the consuming command to
  `https://api.buildkite.com`. Configured IP allowlists must permit both token
  exchange and API usage.

## Administrator setup

The plugin does not create workload identities, grant access, or revoke old
credentials. An organization administrator must configure these independently in
[Workload Identities](https://buildkite.com/organizations/~/workload-identities).

### Trust the source job

Create a new workload identity with **Provider: Buildkite Agents**.
Set the issuer to `https://agent.buildkite.com`, and copy the identity's
**Client ID** and **OIDC audience** for plugin configuration.

Restrict the trust policy to the pipeline that **runs the consuming job** (the
source pipeline), its intended branch, and step. For the `read-target-builds`
step on `main`, use this OIDC subject with your source organization's and
pipeline's slugs substituted:

```text
organization:YOUR_ORG_SLUG:pipeline:SOURCE_PIPELINE_SLUG:ref:refs/heads/main:commit:*:step:read-target-builds
```

In **Claims**, require the actual source organization's UUID:

```json
{
  "organization_id": "00000000-0000-4000-8000-000000000001"
}
```

In **Claim conditions**, additionally require the source pipeline's UUID,
branch, and step key:

```text
claims.pipeline_id == "00000000-0000-4000-8000-000000000002"
  && claims.build_branch == "main"
  && claims.step_key == "read-target-builds"
```

The UUIDs above are placeholders. Prefer immutable IDs over slugs in claim
checks; slugs can be renamed and reused. All Buildkite organizations share the
agent issuer, so Buildkite requires `organization_id` or `organization_slug` in
**Claims**. Do not remove that organization restriction or broaden the subject
to every pipeline. Protect the source pipeline's code and configuration from
untrusted changes.

The example assumes the agent's default compound OIDC subject; do not override
it through `BUILDKITE_OIDC_TOKEN_SUBJECT_CLAIM`. This plugin does not request
optional claims such as `queue_key`, so do not require them in this policy.

### Grant access to target resources

Trust and resource access answer different questions:

| Setting | What it controls |
| --- | --- |
| Trust policy | Which source jobs may mint tokens. |
| Resource Access | Which target resources those tokens may access. |
| Grantable Scopes | Maximum operations tokens may request. |
| Default Scopes | Operations granted when the request omits `scope`. |

For the REST build-read example below, set **Resource Access > Pipelines** to
**Selected**, and select only the target pipeline(s) whose builds the job needs
to read. These can differ from the source pipeline in the trust policy.
Trusting a source pipeline does not automatically grant it resource access.
Leave teams, clusters, and test suites at **None** unless separately required.

Set **Grantable Scopes** to `read_builds`. Set **Default Scopes** to
`read_builds` if requests without an explicit scope should work; the example
requests it explicitly. `read_pipelines` alone is not sufficient for this build
read. Avoid organization-administration scopes: resource grants do not restrict
those scopes to selected pipelines.

Set an appropriate **Maximum token lifetime** (30-3600 seconds), and consider
the identity's exchange and token-usage IP allowlists. Save the identity;
resource access starts at **None**, not implicit organization-wide access.

## Usage

Run this step in the trusted source pipeline on `main`. Replace the client ID,
audience, organization slug, and target pipeline slug. The explicit `audience`
overrides the Elastic-specific default and must exactly match the workload
identity's configured audience.

```yaml
steps:
  - label: "Read target pipeline builds"
    key: read-target-builds
    command: |
      curl --fail --silent --show-error \
        -H "Authorization: Bearer $$BUILDKITE_TOKEN_SECRET" \
        "https://api.buildkite.com/v2/organizations/YOUR_ORG_SLUG/pipelines/TARGET_PIPELINE_SLUG/builds"
    plugins:
      - elastic/buildkite-auth#v0.1.0:
          client-id: "YOUR_WORKLOAD_IDENTITY_CLIENT_ID"
          audience: "YOUR_WORKLOAD_IDENTITY_AUDIENCE"
          scope: "read_builds"
          lifetime: 3600
          env-var: BUILDKITE_TOKEN_SECRET
```

`$$` defers variable expansion until the job command runs instead of expanding
it during pipeline upload. In a checked-in shell script, use the normal
`$BUILDKITE_TOKEN_SECRET` form. Omit `env-var` to export `BUILDKITE_API_TOKEN`
instead. The plugin exports only the configured variable, not both names.

## Configuration

The [plugin schema](plugin.yml) defines the accepted options; runtime defaults
and validation are in [hooks/pre-command](hooks/pre-command).

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `client-id` | Yes | None | Non-empty workload identity Client ID. |
| `audience` | No | `https://api.buildkite.com/v2/organizations/e0f3970e-3a75-4621-919f-e6c773e2bb12` | OIDC audience for Elastic's Buildkite organization. Override for any identity with a different audience, including identities in another organization. |
| `scope` | No | Omitted | Space-separated requested API scopes, restricted to the identity's grantable scopes. When empty or omitted, Buildkite uses the identity's default scopes. |
| `lifetime` | No | `3600` | Requested OIDC token lifetime in seconds, an integer from 1 to 3600. Not a guaranteed API token lifetime. |
| `env-var` | No | `BUILDKITE_API_TOKEN` | Export destination; must match `^[A-Za-z_][A-Za-z0-9_]*$`. Use `BUILDKITE_TOKEN_SECRET` for existing consumers of that name. |

Unknown configuration keys are rejected by the schema.

## Lifecycle and limitations

The plugin runs at **plugin `pre-command`**, requests one OIDC token, exchanges
it once at `https://buildkite.com/oauth/token`, registers the returned API token
with the agent redactor, and exports it into the job command's environment.
It fails the hook on OIDC, exchange, invalid-token, or redaction-registration
failure rather than deliberately falling back to a stored credential.

It mints **one API token per job at pre-command and does not refresh it**.
The token expires no later than its OIDC token or the identity's maximum token
lifetime. Consequently, its actual lifetime can be **less than the requested
3600 seconds**, including time spent exchanging it. The plugin does not send
an API `expires_in` request or expose the response's expiry as an output.
Long-running commands must finish API usage before expiry or use a separately
implemented renewal mechanism. Every fresh exchange, including a retry, needs a
**new OIDC token**; Buildkite accepts an agent OIDC token only once.

WIF supports only the [documented REST API subset and scopes](https://buildkite.com/docs/apis/workload-identity-federation/supported-endpoints),
not every endpoint a personal token can access. It does not support GraphQL,
Package Registries, secrets, or workload identity management. Check every
consumer's endpoints before migrating.

The **client ID and audience are non-secret** and may be committed in pipeline
configuration. The OIDC assertion and **exported API token are sensitive**.
Do not print them, enable shell tracing around their use, or place them in
artifacts. Redaction reduces accidental log exposure; it does not prevent
commands in the job from reading the exported token.

## Migrating `BUILDKITE_TOKEN_SECRET` consumers

Setting `env-var: BUILDKITE_TOKEN_SECRET` lets an existing script read the WIF
token under its existing variable name. It does **not** by itself eliminate
Vault access or revoke the old API token.

In particular, observability-robots' `.buildkite/hooks/pre-command`
unconditionally fetches a token from Vault **before plugin pre-command**, and
separately replaces it in the apm-server case. Adding this plugin alone still
performs those reads and still depends on them succeeding, even though the
plugin subsequently replaces the environment variable for the command.

1. Inventory the intended jobs' API calls, target pipelines, durations, and
   existing token consumers. Verify WIF supports those endpoints and grant only
   the necessary resources and scopes.
2. Have an administrator create and restrict the separate Buildkite Agents
   identity. Add the plugin to selected jobs with
   `env-var: BUILDKITE_TOKEN_SECRET`.
3. Deliberately adjust the existing Vault reads for migrated jobs, including
   the unconditional read and the apm-server-specific replacement. Preserve
   reads needed by other consumers until those consumers are independently
   inventoried and migrated. Account for repository and plugin hook order;
   do not rely on a variable exported later to skip an earlier hook.
4. Validate exchanges and actual API operations in the approved environment,
   confirm no migrated job still reads Vault for this token, and confirm
   unmigrated consumers still work. Only revoke the old stored credential
   after the migration and all remaining dependencies have been validated.

This repository provides the plugin and migration guidance, not a production
rollout or workload identity provisioning.

## End-to-end test

The default Buildkite pipeline includes a live test on `main`. It loads
`elastic/buildkite-auth` at the build commit, exchanges an agent OIDC token,
and uses the resulting API token to list Test Engine suites. The non-secret
`BUILDKITE_WIF_CLIENT_ID` is set in `.buildkite/pipeline.yml`.

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

## References and contributing

- [Buildkite Agents WIF setup](https://buildkite.com/docs/apis/workload-identity-federation/buildkite-agents)
- [Workload identity configuration and token lifetime](https://buildkite.com/docs/apis/workload-identity-federation)
- [OIDC command and claims](https://buildkite.com/docs/agent/cli/reference/oidc)
- [Contributing and local checks](CONTRIBUTING.md)
- [Release process](docs/RELEASE.md)
