# Authenticate to the Buildkite API from Buildkite

Buildkite plugin to get a short-lived Buildkite REST API token using Workload Identity Federation.

```yaml
steps:
  - command: 'curl -H "Authorization: Bearer $$BUILDKITE_API_TOKEN" https://api.buildkite.com/v2/access-token'
    plugins:
      - elastic/buildkite-auth#v1.0.0:
          client-id: "YOUR_WORKLOAD_IDENTITY_CLIENT_ID"
          audience: "YOUR_WORKLOAD_IDENTITY_AUDIENCE"
```

The default audience is specific to Elastic's Buildkite organization; set `audience` to the workload identity's audience when using another organization. The optional `lifetime` is the OIDC token lifetime in seconds (default 3600, maximum 3600). The API token may expire sooner, and is not automatically refreshed. Set `env-var: BUILDKITE_TOKEN_SECRET` for scripts that expect that variable, and `scope` to request space-separated scopes.
