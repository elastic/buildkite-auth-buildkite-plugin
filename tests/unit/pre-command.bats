#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID="client&=id"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_AUDIENCE="my-audience"
  export MOCK_RESPONSE='{"access_token":"api-secret","expires_in":299}'
}

teardown() {
  local result=0
  unstub --allow-missing buildkite-agent || result=1
  unstub --allow-missing curl || result=1
  return "$result"
}

stub_oidc() {
  stub buildkite-agent "oidc request-token --audience my-audience --lifetime ${1:-3600} : printf '%s' assertion-secret"
}

stub_exchange() {
  local scope_arg="${1:-}"
  local command="${2:-cat > \"\$BATS_TEST_TMPDIR/assertion\"; printf '%s' \"\$MOCK_RESPONSE\"}"
  stub curl "-q --silent --show-error --fail --data-urlencode grant_type=client_credentials --data-urlencode 'client_id=client&=id' --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion@- ${scope_arg} https://buildkite.com/oauth/token : $command"
}

stub_redactor() {
  stub buildkite-agent 'redactor add --format none : cat > "$BATS_TEST_TMPDIR/redacted"; printf "%s\n" "$BUILDKITE_AGENT_REDACT_VARS_FILTER" "$BUILDKITE_AGENT_DEBUG_HTTP" > "$BATS_TEST_TMPDIR/redactor-env"'
}

@test "exports the default token after registering it for redaction" {
  stub_oidc
  stub_exchange
  stub_redactor
  run bash -c 'source "$1/hooks/pre-command"; printenv BUILDKITE_API_TOKEN' _ "$PWD"
  assert_success
  assert_output --partial "api-secret"
  [ "$(cat "$BATS_TEST_TMPDIR/redacted")" = "api-secret" ]
  [ "$(cat "$BATS_TEST_TMPDIR/assertion")" = "assertion-secret" ]
  [ "$(cat "$BATS_TEST_TMPDIR/redactor-env")" = $'false\nfalse' ]
}

@test "exports a custom token name and passes form values for URL encoding" {
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_ENV_VAR="BUILDKITE_TOKEN_SECRET"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_SCOPE="read_builds write_builds&other"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_LIFETIME=300
  stub_oidc 300
  stub_exchange "--data-urlencode 'scope=read_builds write_builds&other'"
  stub_redactor
  run bash -c 'source "$1/hooks/pre-command"; printenv BUILDKITE_TOKEN_SECRET' _ "$PWD"
  assert_success
  assert_output --partial "api-secret"
  [ "$(cat "$BATS_TEST_TMPDIR/assertion")" = "assertion-secret" ]
  [ "$(cat "$BATS_TEST_TMPDIR/redacted")" = "api-secret" ]
}

@test "fails safely when requesting an OIDC token fails or returns empty" {
  stub curl
  stub buildkite-agent \
    'oidc request-token --audience my-audience --lifetime 3600 : echo "assertion-secret api-secret" >&2; exit 1' \
    'oidc request-token --audience my-audience --lifetime 3600 : true'
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "failed to request an OIDC token"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"

  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "failed to request an OIDC token"
}

@test "fails safely on HTTP or network exchange failure" {
  stub_oidc
  stub_exchange "" 'cat >/dev/null; echo "assertion-secret api-secret" >&2; printf "%s" "$MOCK_RESPONSE"; exit 22'
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "token exchange failed"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
}

@test "rejects malformed, missing, non-string, empty and whitespace tokens without logging responses" {
  for MOCK_RESPONSE in 'not json api-secret' '{}' '{"access_token":null}' \
    '{"access_token":42}' '{"access_token":""}' '{"access_token":"api-secret\n"}' \
    '{"access_token":"api-secret"} {"access_token":"api-secret"}'; do
    export MOCK_RESPONSE
    stub_oidc
    stub_exchange
    run "$PWD/hooks/pre-command"
    assert_failure
    assert_output --partial "invalid or missing access token"
    refute_output --partial "api-secret"
    unstub buildkite-agent
    unstub curl
  done
}

@test "fails safely when redaction fails before exporting the token" {
  stub_oidc
  stub_exchange
  stub buildkite-agent 'redactor add --format none : cat >/dev/null; echo "assertion-secret api-secret" >&2; exit 1'
  run bash -c 'source "$1/hooks/pre-command"; printenv BUILDKITE_API_TOKEN' _ "$PWD"
  assert_failure
  assert_output --partial "failed to register the API token for redaction"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
}

@test "does not trace credentials when the caller enables xtrace" {
  stub_oidc
  stub_exchange
  stub buildkite-agent 'redactor add --format none : cat >/dev/null; exit 1'
  run bash -c 'set -x; source "$1/hooks/pre-command"' _ "$PWD"
  assert_failure
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
}

@test "validates client ID, output name and lifetime before requesting a token" {
  stub buildkite-agent
  stub curl
  unset BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "client-id is required"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID=client
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_ENV_VAR='bad-name'
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "invalid env-var"
  unset BUILDKITE_PLUGIN_BUILDKITE_AUTH_ENV_VAR
  for lifetime in 0 3601 -1 abc; do
    export BUILDKITE_PLUGIN_BUILDKITE_AUTH_LIFETIME="$lifetime"
    run "$PWD/hooks/pre-command"
    assert_failure
    assert_output --partial "lifetime must be"
  done
}
