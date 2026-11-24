# Migrating observability-robots `BUILDKITE_TOKEN_SECRET` consumers

This guide applies the general
[migration steps](../README.md#migrating-from-a-stored-token) to
observability-robots, whose jobs read a Buildkite API token from Vault as
`BUILDKITE_TOKEN_SECRET`. It describes guidance only; this repository does not
perform the rollout or provision workload identities.

## Why adding the plugin is not enough

observability-robots' `.buildkite/hooks/pre-command` is a repository hook. It
unconditionally fetches the token from Vault and separately replaces it for the
apm-server case. Repository `pre-command` hooks run **before** plugin
`pre-command` hooks, so with this plugin and
`env-var: BUILDKITE_TOKEN_SECRET`:

- the Vault reads still happen, and the job still fails if they fail;
- the plugin then overwrites `BUILDKITE_TOKEN_SECRET` for the command;
- the repository hook cannot check for a variable that the plugin exports later.

## Steps

1. **Inventory.** For each job to migrate, record the API calls, target
   pipelines, durations, and every consumer of `BUILDKITE_TOKEN_SECRET`. Confirm
   WIF [supports those endpoints](https://buildkite.com/docs/apis/workload-identity-federation/supported-endpoints)
   and that the work finishes within the
   [token lifetime](../README.md#token-lifetime).
2. **Provision.** Have an administrator create a separate Buildkite Agents
   identity, following [Administrator setup](../README.md#administrator-setup),
   with only the necessary resources and scopes.
3. **Add the plugin** to the selected jobs with
   `env-var: BUILDKITE_TOKEN_SECRET`, using the plugin version from the
   [README](../README.md#existing-buildkite_token_secret-consumers).
4. **Adjust the Vault reads.** Change the repository hook so migrated jobs skip
   both the unconditional read and the apm-server-specific replacement, for
   example by matching on a value known before the hook runs, such as
   `BUILDKITE_STEP_KEY` or a pipeline-level variable. Keep the reads that
   unmigrated consumers still need.
5. **Validate** the token exchange and the actual API operations in the
   approved environment. Confirm migrated jobs no longer read the token from
   Vault and unmigrated consumers still work.
6. **Revoke** the stored token only after every remaining consumer has been
   migrated and validated.
