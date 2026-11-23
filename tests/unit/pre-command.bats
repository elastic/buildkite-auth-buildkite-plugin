#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"
  export TEST_DIR="$BATS_TEST_TMPDIR"
  export PATH="$TEST_DIR:$PATH"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID="client&=id"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_AUDIENCE="my-audience"
  export MOCK_OIDC="assertion-secret"
  export MOCK_RESPONSE='{"access_token":"api-secret","expires_in":299}'
  cat > "$TEST_DIR/buildkite-agent" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "oidc request-token" ]]; then
  printf '%s\n' "$@" > "$TEST_DIR/oidc-args"
  if [[ "${MOCK_OIDC_FAIL:-}" == 1 ]]; then
    echo "assertion-secret api-secret" >&2
    exit 1
  fi
  printf '%s' "$MOCK_OIDC"
elif [[ "$1 $2" == "redactor add" ]]; then
  printf '%s\n' "$@" > "$TEST_DIR/redactor-args"
  printf '%s\n' "$BUILDKITE_AGENT_REDACT_VARS_FILTER" "$BUILDKITE_AGENT_DEBUG_HTTP" > "$TEST_DIR/redactor-env"
  cat > "$TEST_DIR/redacted"
  if [[ "${MOCK_REDACTOR_FAIL:-}" == 1 ]]; then
    echo "assertion-secret api-secret" >&2
    exit 1
  fi
else
  exit 1
fi
EOF
  cat > "$TEST_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_DIR/curl-args"
cat > "$TEST_DIR/assertion"
if [[ "${MOCK_CURL_FAIL:-}" == 1 ]]; then
  echo "assertion-secret api-secret" >&2
  printf '%s' "$MOCK_RESPONSE"
  exit 22
fi
printf '%s' "$MOCK_RESPONSE"
EOF
  chmod +x "$TEST_DIR/buildkite-agent" "$TEST_DIR/curl"
}

@test "exports the default token after registering it for redaction" {
  run bash -c 'source "$1/hooks/pre-command"; printenv BUILDKITE_API_TOKEN' _ "$PWD"
  assert_success
  assert_output --partial "api-secret"
  [ "$(cat "$TEST_DIR/redacted")" = "api-secret" ]
  [ "$(cat "$TEST_DIR/assertion")" = "assertion-secret" ]
  grep -Fxq -- '--format' "$TEST_DIR/redactor-args"
  grep -Fxq -- 'none' "$TEST_DIR/redactor-args"
  [ "$(cat "$TEST_DIR/redactor-env")" = $'false\nfalse' ]
  [ "$(tail -1 "$TEST_DIR/oidc-args")" = "3600" ]
}

@test "exports a custom token name and passes form values for URL encoding" {
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_ENV_VAR="BUILDKITE_TOKEN_SECRET"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_SCOPE="read_builds write_builds&other"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_LIFETIME=300
  run bash -c 'source "$1/hooks/pre-command"; printenv BUILDKITE_TOKEN_SECRET' _ "$PWD"
  assert_success
  assert_output --partial "api-secret"
  grep -Fxq -- 'client_id=client&=id' "$TEST_DIR/curl-args"
  grep -Fxq -- 'scope=read_builds write_builds&other' "$TEST_DIR/curl-args"
  [ "$(grep -cFx -- '--data-urlencode' "$TEST_DIR/curl-args")" -eq 5 ]
  grep -Fxq -- 'client_assertion@-' "$TEST_DIR/curl-args"
  [ "$(tail -1 "$TEST_DIR/oidc-args")" = "300" ]
}

@test "fails safely when requesting an OIDC token fails or returns empty" {
  export MOCK_OIDC_FAIL=1
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "failed to request an OIDC token"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
  [ ! -e "$TEST_DIR/curl-args" ]

  unset MOCK_OIDC_FAIL
  export MOCK_OIDC=""
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "failed to request an OIDC token"
}

@test "fails safely on HTTP or network exchange failure" {
  export MOCK_CURL_FAIL=1
  run "$PWD/hooks/pre-command"
  assert_failure
  assert_output --partial "token exchange failed"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
  [ ! -e "$TEST_DIR/redacted" ]
}

@test "rejects malformed, missing, non-string, empty and whitespace tokens without logging responses" {
  for MOCK_RESPONSE in 'not json api-secret' '{}' '{"access_token":null}' \
    '{"access_token":42}' '{"access_token":""}' '{"access_token":"api-secret\n"}' \
    '{"access_token":"api-secret"} {"access_token":"api-secret"}'; do
    export MOCK_RESPONSE
    run "$PWD/hooks/pre-command"
    assert_failure
    assert_output --partial "invalid or missing access token"
    refute_output --partial "api-secret"
    [ ! -e "$TEST_DIR/redacted" ]
  done
}

@test "fails safely when redaction fails before exporting the token" {
  export MOCK_REDACTOR_FAIL=1
  run bash -c 'source "$1/hooks/pre-command"; printenv BUILDKITE_API_TOKEN' _ "$PWD"
  assert_failure
  assert_output --partial "failed to register the API token for redaction"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
}

@test "does not trace credentials when the caller enables xtrace" {
  export MOCK_REDACTOR_FAIL=1
  run bash -c 'set -x; source "$1/hooks/pre-command"' _ "$PWD"
  assert_failure
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
}

@test "validates client ID, output name and lifetime before requesting a token" {
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
  [ ! -e "$TEST_DIR/oidc-args" ]
}
