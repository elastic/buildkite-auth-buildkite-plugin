#!/usr/bin/env bats

setup() {
    load "${BATS_PLUGIN_PATH}/load.bash"

    export BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID="client123"
    export BUILDKITE_PLUGIN_BUILDKITE_AUTH_AUDIENCE="my-audience"
}

teardown() {
    unstub buildkite-agent || true
    unstub curl || true
}

@test "exports the Buildkite API token" {
    stub buildkite-agent \
      "oidc request-token --audience my-audience --lifetime 3600 : echo 'oidc-token'" \
      "redactor add : cat > /dev/null"
    stub curl "-sS -d grant_type=client_credentials -d client_id=client123 -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d client_assertion=oidc-token https://buildkite.com/oauth/token : cat $PWD/tests/fixtures/success.json"

    run bash -c "source $PWD/hooks/pre-command && echo \"token=\$BUILDKITE_API_TOKEN\""

    assert_success
    assert_output --partial "token=bkwi_test_token"
}

@test "exports the token to a custom env var with a scope" {
    export BUILDKITE_PLUGIN_BUILDKITE_AUTH_ENV_VAR="BUILDKITE_TOKEN_SECRET"
    export BUILDKITE_PLUGIN_BUILDKITE_AUTH_SCOPE="read_builds"
    stub buildkite-agent \
      "oidc request-token --audience my-audience --lifetime 3600 : echo 'oidc-token'" \
      "redactor add : cat > /dev/null"
    stub curl "-sS -d grant_type=client_credentials -d client_id=client123 -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d client_assertion=oidc-token -d scope=read_builds https://buildkite.com/oauth/token : cat $PWD/tests/fixtures/success.json"

    run bash -c "source $PWD/hooks/pre-command && echo \"token=\$BUILDKITE_TOKEN_SECRET\""

    assert_success
    assert_output --partial "token=bkwi_test_token"
}

@test "fails when the token exchange fails" {
    stub buildkite-agent "oidc request-token --audience my-audience --lifetime 3600 : echo 'oidc-token'"
    stub curl "-sS -d grant_type=client_credentials -d client_id=client123 -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d client_assertion=oidc-token https://buildkite.com/oauth/token : cat $PWD/tests/fixtures/errors.json"

    run "$PWD/hooks/pre-command"

    assert_failure
    assert_output --partial "invalid_client"
}

@test "fails without client-id" {
    unset BUILDKITE_PLUGIN_BUILDKITE_AUTH_CLIENT_ID

    run "$PWD/hooks/pre-command"

    assert_failure
    assert_output --partial "client-id is required"
}
