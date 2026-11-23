# Authenticate to the Buildkite API from Buildkite

[![usages](https://img.shields.io/badge/usages-white?logo=buildkite&logoColor=blue)](https://github.com/search?q=elastic%2Fbuildkite-auth+%28path%3A.buildkite%29&type=code)

This is an opinionated plugin to get a short-lived Buildkite REST API token from a Buildkite job using [Buildkite Workload Identity Federation](https://buildkite.com/docs/apis/workload-identity-federation), instead of a long-lived `BUILDKITE_TOKEN` stored in Vault.

The plugin requests an OIDC token for the job with `buildkite-agent oidc request-token`, exchanges it at `https://buildkite.com/oauth/token` for an API token, and exports it as an environment variable. The token is redacted from the logs and unset in the `pre-exit` hook.

## Prerequisites

A [workload identity](https://buildkite.com/organizations/~/workload-identities) with the **Buildkite Agents** provider must exist and trust the pipeline running the plugin. Its trust policy, resource access and grantable scopes decide what the token can do. The **Client ID** and **OIDC audience** aren't secrets.

## Properties

| Name        | Description                                                                                                       | Required | Default                                     |
|-------------|-------------------------------------------------------------------------------------------------------------------|----------|---------------------------------------------|
| `client-id` | The workload identity's Client ID.                                                                                | `true`   |                                             |
| `audience`  | The workload identity's OIDC audience.                                                                            | `false`  | The `elastic` Buildkite organization audience |
| `scope`     | Space-separated scopes to request. Must be a subset of the grantable scopes. Defaults to the identity's default scopes. | `false`  |                                             |
| `lifetime`  | Lifetime of the OIDC token in seconds, which caps the API token lifetime (max `3600`).                            | `false`  | `3600`                                      |
| `env-var`   | Name of the environment variable the API token is exported to.                                                    | `false`  | `BUILDKITE_API_TOKEN`                       |

## Usage

```yml
steps:
  - command: |
      curl -sSf -H "Authorization: Bearer $$BUILDKITE_API_TOKEN" https://api.buildkite.com/v2/access-token
    plugins:
      - elastic/buildkite-auth#v0.1.0:
          client-id: "01a207bc-0000-0000-0000-000000000000"
          scope: "read_builds"
```

To replace an existing `BUILDKITE_TOKEN_SECRET` read from Vault without changing the scripts that use it:

```yml
steps:
  - command: .buildkite/scripts/download-signed-artifacts.sh
    plugins:
      - elastic/buildkite-auth#v0.1.0:
          client-id: "01a207bc-0000-0000-0000-000000000000"
          env-var: "BUILDKITE_TOKEN_SECRET"
```

## Limitations

- Workload identity federation only supports [a subset of the REST API](https://buildkite.com/docs/apis/workload-identity-federation/supported-endpoints). GraphQL isn't supported.
- The token can't outlive the OIDC token, so it lasts at most one hour. Longer steps need to request a new token.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local development and testing instructions.
