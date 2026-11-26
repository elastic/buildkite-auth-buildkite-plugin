#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID="client&=id"
  export BUILDKITE_PLUGIN_BUILDKITE_AUTH_AUDIENCE="my-audience"
  export MOCK_RESPONSE='{"access_token":"api-secret","expires_in":299}'
  stub sleep
}

teardown() {
  local result=0
  unstub --allow-missing buildkite-agent || result=1
  unstub --allow-missing curl || result=1
  unstub --allow-missing sleep || result=1
  return "$result"
}

stub_oidc() {
  stub buildkite-agent "oidc request-token --audience my-audience --lifetime ${1:-3600} : printf '%s' '${2:-assertion-secret}'"
}

stub_exchange() {
  local scope_arg="${1:-}"
  local command="${2:-cat > \"\$BATS_TEST_TMPDIR/assertion\"; printf 'HTTP/2 200\r\nContent-Type: application/json\r\n\r\n%s\n200' \"\$MOCK_RESPONSE\"}"
  stub curl "-q --silent --show-error --fail --connect-timeout 10 --max-time 30 --dump-header - --write-out '\\n%{http_code}' --data-urlencode grant_type=client_credentials --data-urlencode 'client_id=client&=id' --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode client_assertion@- ${scope_arg} https://buildkite.com/oauth/token : $command"
}

stub_http_exchange() {
  local status="$1" headers="${2:-}" assertion_file="${3:-assertion}"
  local curl_status=0
  if (( status >= 400 )); then
    curl_status=22
  fi
  stub_exchange "" "cat > \"\$BATS_TEST_TMPDIR/$assertion_file\"; printf 'HTTP/2 $status\r\n%b\r\n%s\n$status' '$headers' \"\$MOCK_RESPONSE\"; exit $curl_status"
}

stub_waits() {
  local random_values index=0 reset wait
  read -r -a random_values <<< "$(bash -c 'RANDOM=123; echo "$RANDOM $RANDOM $RANDOM"')"
  for reset in "$@"; do
    wait=$((reset + 1 + random_values[index] % 3))
    stub sleep "$wait : echo '$wait' >> \"\$BATS_TEST_TMPDIR/waits\""
    index=$((index + 1))
  done
}

run_retry_hook() {
  run bash -c 'RANDOM=123; source "$1/hooks/pre-command"' _ "$PWD"
}

assert_safe_failure() {
  assert_failure
  assert_output --partial "buildkite-auth: $1"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
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

@test "retries 429 with case-insensitive reset header, jitter and a fresh assertion" {
  stub_oidc 3600 assertion-secret-first
  stub_http_exchange 429 'rAtElImIt-WoRkLoAdIdEnTiTyToKeNeXcHaNgE-ReSeT: \t000008 \t\r\n' assertion-first
  stub_waits 8
  stub_oidc 3600 assertion-secret-second
  stub_http_exchange 200 'Content-Type: application/json\r\n' assertion-second
  stub_redactor

  run_retry_hook
  assert_success
  assert_output --partial "buildkite-auth: token exchange rate limited; retrying in"
  refute_output --partial "assertion-secret"
  refute_output --partial "api-secret"
  [ "$(cat "$BATS_TEST_TMPDIR/assertion-first")" = assertion-secret-first ]
  [ "$(cat "$BATS_TEST_TMPDIR/assertion-second")" = assertion-secret-second ]
  [ "$(cat "$BATS_TEST_TMPDIR/redacted")" = api-secret ]
  local wait
  wait="$(cat "$BATS_TEST_TMPDIR/waits")"
  (( wait >= 9 && wait <= 11 ))
}

@test "allows zero reset and succeeds on the third retry" {
  local attempt
  for attempt in 1 2 3; do
    stub_oidc
    stub_http_exchange 429 'RateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n'
  done
  stub_waits 0 0 0
  stub_oidc
  stub_exchange
  stub_redactor
  run_retry_hook
  assert_success
  refute_output --partial "api-secret"
}

@test "fails after three retries without another wait or assertion" {
  local attempt
  for attempt in 1 2 3 4; do
    stub_oidc
    stub_http_exchange 429 'RateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n'
  done
  stub_waits 0 0 0
  run_retry_hook
  assert_safe_failure "token exchange rate-limit retry budget exhausted"
}

@test "rejects missing, malformed and duplicate reset headers without waiting" {
  local headers
  for headers in 'Other-Header: 1\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset:\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: -1\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: +1\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: 1.5\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: 1e2\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: assertion-secret api-secret\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: 1 2\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: 1\r\nratelimit-workloadidentitytokenexchange-reset: 1\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset: 1\r\nRateLimit-WorkloadIdentityTokenExchange-Reset:\r\n' \
    'RateLimit-WorkloadIdentityTokenExchange-Reset:\r\nRateLimit-WorkloadIdentityTokenExchange-Reset: 1\r\n'; do
    stub_oidc
    stub_http_exchange 429 "$headers"
    run_retry_hook
    assert_safe_failure "token exchange rate limit has a missing or invalid reset header"
    unstub buildkite-agent
    unstub curl
  done
}

@test "rejects waits beyond the budget including huge integers without overflow" {
  local reset
  for reset in 300 301 999999999999999999999999999999999999; do
    stub_oidc
    stub_http_exchange 429 "RateLimit-WorkloadIdentityTokenExchange-Reset: $reset\r\n"
    run_retry_hook
    assert_safe_failure "token exchange rate-limit wait budget exceeded"
    unstub buildkite-agent
    unstub curl
  done
}

@test "enforces cumulative waiting including jitter" {
  stub_oidc
  stub_http_exchange 429 'RateLimit-WorkloadIdentityTokenExchange-Reset: 150\r\n'
  stub_waits 150
  stub_oidc
  stub_http_exchange 429 'RateLimit-WorkloadIdentityTokenExchange-Reset: 150\r\n'
  run_retry_hook
  assert_safe_failure "token exchange rate-limit wait budget exceeded"
}

@test "allows exactly 300 seconds of waiting including jitter" {
  local random_value reset
  random_value="$(bash -c 'RANDOM=123; echo "$RANDOM"')"
  reset=$((300 - 1 - random_value % 3))
  stub_oidc
  stub_http_exchange 429 "RateLimit-WorkloadIdentityTokenExchange-Reset: $reset\r\n"
  stub_waits "$reset"
  stub_oidc
  stub_exchange
  stub_redactor
  run_retry_hook
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/waits")" = 300 ]
  refute_output --partial "api-secret"
}

@test "does not retry other HTTP failures" {
  local status
  for status in 400 401 403 500 503; do
    stub_oidc
    stub_http_exchange "$status" 'RateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n'
    run_retry_hook
    assert_safe_failure "token exchange failed"
    unstub buildkite-agent
    unstub curl
  done
}

@test "does not retry a transport failure even when a 429 was received" {
  stub_oidc
  stub_exchange "" "cat >/dev/null; printf 'HTTP/2 429\r\nRateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n\r\n\n429'; exit 56"
  run_retry_hook
  assert_safe_failure "token exchange failed"
}

@test "fails safely without retrying when the token exchange times out" {
  stub_oidc
  stub_exchange "" "cat >/dev/null; echo 'assertion-secret api-secret' >&2; printf 'HTTP/2 429\r\nRateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n\r\n\n429'; exit 28"
  run_retry_hook
  assert_safe_failure "token exchange failed"
}

@test "fails safely when HTTP status or final headers cannot be determined" {
  local response
  for response in 'assertion-secret api-secret' \
    'HTTP/2 429\r\n\r\n\n000' \
    'HTTP/2 429\r\n\r\n\napi-secret' \
    'HTTP/2 200\r\n\r\n\n429' \
    'HTTP/2 429\n429'; do
    export MOCK_HTTP_RESPONSE="$response"
    stub_oidc
    stub_exchange "" 'cat >/dev/null; printf "%b" "$MOCK_HTTP_RESPONSE"; exit 22'
    run_retry_hook
    assert_safe_failure "token exchange"
    unstub buildkite-agent
    unstub curl
  done
}

@test "uses the final header block after proxy and informational responses" {
  stub_oidc
  stub_exchange "" "cat >/dev/null; printf 'HTTP/1.1 200 Connection established\r\nRateLimit-WorkloadIdentityTokenExchange-Reset: 999\r\n\r\nHTTP/1.1 100 Continue\r\n\r\nHTTP/2 429\r\nRateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n\r\n\n429'; exit 22"
  stub_waits 0
  stub_oidc
  stub_exchange
  stub_redactor
  run_retry_hook
  assert_success
  refute_output --partial "api-secret"
}

@test "does not use a reset header from an earlier response block" {
  stub_oidc
  stub_exchange "" "cat >/dev/null; printf 'HTTP/1.1 200 Connection established\r\nRateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n\r\nHTTP/2 429\r\n\r\n\n429'; exit 22"
  run_retry_hook
  assert_safe_failure "token exchange rate limit has a missing or invalid reset header"
}

@test "fails safely if requesting a fresh assertion fails" {
  stub_oidc
  stub_http_exchange 429 'RateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n'
  stub_waits 0
  stub buildkite-agent 'oidc request-token --audience my-audience --lifetime 3600 : echo "assertion-secret api-secret" >&2; exit 1'
  run_retry_hook
  assert_safe_failure "failed to request an OIDC token"
}

@test "fails safely if the rate-limit wait fails" {
  local random_value wait
  random_value="$(bash -c 'RANDOM=123; echo "$RANDOM"')"
  wait=$((1 + random_value % 3))
  stub_oidc
  stub_http_exchange 429 'RateLimit-WorkloadIdentityTokenExchange-Reset: 0\r\n'
  stub sleep "$wait : echo 'assertion-secret api-secret' >&2; exit 1"
  run_retry_hook
  assert_safe_failure "token exchange rate-limit wait failed"
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
