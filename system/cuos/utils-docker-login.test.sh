#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils-docker-login.sh"

# Create temp test directory
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Set up test environment
export HOME="$TEST_DIR"
export CONFIG_PATH="${TEST_DIR}/system.json"
export DOCKER_CONFIG_FILE="${TEST_DIR}/.docker/config.json"
export BASE64_CMD="base64"  # Ensure we use standard base64

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

setup() {
  rm -rf "${TEST_DIR:?}/.docker"
  rm -f "$CONFIG_PATH"
  echo '{}' > "$CONFIG_PATH"
}

# Test _b64 function
expect "_b64: simple string" "dGVzdA==" _b64 "test"
expect "_b64: empty string" "" _b64 ""
expect "_b64: special chars" "dGVzdDphYmM=" _b64 "test:abc"

# Test init_docker_config
init_docker_config "$DOCKER_CONFIG_FILE"
expect_rc "init_docker_config: creates config" 0 test -f "$DOCKER_CONFIG_FILE"
expect "init_docker_config: correct permissions" "600" stat -f "%Lp" "$DOCKER_CONFIG_FILE"
expect "init_docker_config: valid json" "{}" cat "$DOCKER_CONFIG_FILE"

# Test docker_login with invalid inputs
setup
expect_rc "docker_login: empty server" "1" docker_login "" "user" "pass" "$DOCKER_CONFIG_FILE" 2>/dev/null
expect_rc "docker_login: empty user" "1" docker_login "server" "" "pass" "$DOCKER_CONFIG_FILE" 2>/dev/null
expect_rc "docker_login: empty password" "1" docker_login "server" "user" "" "$DOCKER_CONFIG_FILE" 2>/dev/null

# Test docker_login with valid inputs
setup
init_docker_config "$DOCKER_CONFIG_FILE"
expect_rc "docker_login: valid login" "0" docker_login "registry.example.com" "testuser" "testpass" "$DOCKER_CONFIG_FILE" 2>/dev/null
expect "docker_login: check auth exists" "true" \
  jq -r --arg s "registry.example.com" 'if .auths[$s].auth then "true" else "false" end' "$DOCKER_CONFIG_FILE"

# Test load_update_registry
cat > "$CONFIG_PATH" <<EOF
{
  "update_registry": "ghcr.io/test",
  "update_registry_user": "testuser",
  "update_registry_password": "testpass"
}
EOF

expect "load_update_registry: valid config" "ghcr.io;testuser;testpass" load_update_registry "$CONFIG_PATH"

# Test load_docker_registries
cat > "$CONFIG_PATH" <<EOF
{
  "docker_registries": [
    {
      "server": "docker.io",
      "user": "user1",
      "password": "pass1"
    },
    {
      "server": "quay.io",
      "user": "user2",
      "password": "pass2"
    }
  ]
}
EOF

# Create a temp file to store output since we expect multiple lines
TEMP_OUT="$(mktemp)"
load_docker_registries "$CONFIG_PATH" > "$TEMP_OUT"

expect "load_docker_registries: first entry" "docker.io;user1;pass1" head -n 1 "$TEMP_OUT"
expect "load_docker_registries: second entry" "quay.io;user2;pass2" tail -n 1 "$TEMP_OUT"

# Test incomplete registry entry
cat > "$CONFIG_PATH" <<EOF
{
  "docker_registries": [
    {
      "server": "docker.io",
      "user": "",
      "password": "pass1"
    }
  ]
}
EOF

expect_rc "load_docker_registries: incomplete entry" "1" load_docker_registries "$CONFIG_PATH" 2>/dev/null

# Test the main functionality (script execution)
setup
cat > "$CONFIG_PATH" <<EOF
{
  "update_registry": "ghcr.io/test",
  "update_registry_user": "testuser",
  "update_registry_password": "testpass",
  "docker_registries": [
    {
      "server": "docker.io",
      "user": "user1",
      "password": "pass1"
    }
  ]
}
EOF

# Source the script to run main
"${SCRIPT_DIR}/utils-docker-login.sh" 2>/dev/null

expect "main: update registry added" "true" \
  jq -r --arg s "ghcr.io" 'if .auths[$s].auth then "true" else "false" end' "$DOCKER_CONFIG_FILE"
expect "main: docker registry added" "true" \
  jq -r --arg s "docker.io" 'if .auths[$s].auth then "true" else "false" end' "$DOCKER_CONFIG_FILE"

summary
