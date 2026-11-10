#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/entrypoint.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 2
  }
}

need grep
need ssh-keygen

WORKDIR="$(mktemp -d -t debian-ssh-frp-entrypoint-test.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

ssh-keygen -q -t ed25519 -N '' -C debian-ssh-frp-test -f "${WORKDIR}/id_ed25519"
PUBLIC_KEY="$(cat "${WORKDIR}/id_ed25519.pub")"

export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
export DEBIAN_SSH_HOME="${WORKDIR}/home"
export DEBIAN_SSH_READY_KEY="${DEBIAN_SSH_HOME}/.ssh/ssh_ready_ed25519_key"
export DEBIAN_SSH_HOST_KEY="${DEBIAN_SSH_HOME}/.ssh/dropbear_ed25519_host_key"
export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${WORKDIR}/public-health"
export DEBIAN_SSH_LOCAL_DIAG_DIR="${WORKDIR}/diag"
export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/startup-error.txt"
export DEBIAN_SSH_PERSISTENCE_PATH="${WORKDIR}/persistent-state"
export DEBIAN_FRP_STATE_DIR="${WORKDIR}/frp-state"
export DEBIAN_FRP_CONFIG_FILE="${DEBIAN_FRP_STATE_DIR}/frpc.toml"
export DEBIAN_FRP_TOKEN_FILE="${DEBIAN_FRP_STATE_DIR}/server_token"
export DEBIAN_FRP_ADMIN_CURL_CONFIG="${DEBIAN_FRP_STATE_DIR}/admin-curl.conf"
export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/persisted-config"
export DEBIAN_FRP_LOG_FILE="${WORKDIR}/frpc.log"
export DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES=32768
export DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS=10
export DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS="ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256"

# shellcheck source=../entrypoint.sh
. "${ENTRYPOINT}"

process_running "$$"
if process_running ""; then
  echo "error: empty process identifier was treated as running" >&2
  exit 1
fi
if process_running "999999999"; then
  echo "error: missing process was treated as running" >&2
  exit 1
fi
(
  HEALTH_PID="$$"
  SSHD_PID=""
  FRPC_PID=""
  DEBIAN_SSH_DEBUG_FILE="${WORKDIR}/process-debug.txt"
  write_debug_snapshot
  grep -Fq "health_pid=$$" "${DEBIAN_SSH_DEBUG_FILE}"
  grep -Fq "pid=$$ " "${DEBIAN_SSH_DEBUG_FILE}"
)

(
  unset DEBIAN_FRP_STATE_DIR
  unset DEBIAN_SSH_PERSISTED_CONFIG_DIR
  export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
  # shellcheck source=../entrypoint.sh
  . "${ENTRYPOINT}"
  test "${DEBIAN_FRP_STATE_DIR}" = "/state/app-data/.enclava/frp"
  test "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}" = "/state/app-data/.enclava/debian-ssh-frp/config"
)

(
  unset DEBIAN_FRP_LOG_FILE
  unset DEBIAN_SSH_READY_MARKER
  export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
  # shellcheck source=../entrypoint.sh
  . "${ENTRYPOINT}"
  test "${DEBIAN_FRP_LOG_FILE}" = "${DEBIAN_FRP_STATE_DIR}/frpc.log"
  test "${DEBIAN_SSH_READY_MARKER}" = "${DEBIAN_FRP_STATE_DIR}/ready-seen"
)

mkdir -p "${DEBIAN_SSH_HOME}/.ssh" "${DEBIAN_SSH_HOME}/health" "${DEBIAN_FRP_STATE_DIR}" "${DEBIAN_SSH_PERSISTENCE_PATH}"
chmod 700 "${DEBIAN_SSH_HOME}" "${DEBIAN_SSH_HOME}/.ssh" "${DEBIAN_FRP_STATE_DIR}"

export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_SERVER_ADDR,FRP_SERVER_PORT,FRP_AUTH_TOKEN,FRP_PROXY_NAME,FRP_PROXY_TYPE,FRP_REMOTE_PORT,FRP_LOCAL_ADDR,FRP_LOCAL_PORT,FRP_TUNNEL_CREDENTIAL_ID,FRP_TUNNEL_SECRET,FRP_PUBLIC_HOST,DEBIAN_SSH_AUTHORIZED_KEYS"
test "$(required_config_keys)" = "FRP_SERVER_ADDR FRP_SERVER_PORT FRP_AUTH_TOKEN FRP_PROXY_NAME FRP_PROXY_TYPE FRP_REMOTE_PORT FRP_LOCAL_ADDR FRP_LOCAL_PORT FRP_TUNNEL_CREDENTIAL_ID FRP_TUNNEL_SECRET FRP_PUBLIC_HOST DEBIAN_SSH_AUTHORIZED_KEYS"

(
  profile_home="${WORKDIR}/profile-home"
  mkdir -p "${profile_home}"
  export DEBIAN_SSH_HOME="${profile_home}"
  ensure_default_profile
  grep -Fq "/home/user is persistent and backed by /state/app-data." "${profile_home}/.profile"
  ! grep -Fq "Welcome to Enclava Debian SSH." "${profile_home}/.profile"

  printf 'export CUSTOM_PROFILE=1\n' >"${profile_home}/.profile"
  ensure_default_profile
  grep -qxF "export CUSTOM_PROFILE=1" "${profile_home}/.profile"

  cat >"${profile_home}/.profile" <<'EOF'
echo "Welcome to Enclava Debian SSH."
echo
echo "Persistent data lives in /state."
echo "The root filesystem is platform-managed and may show Kata implementation details."
EOF
  ensure_default_profile
  grep -Fq "/home/user is persistent and backed by /state/app-data." "${profile_home}/.profile"
  ! grep -Fq "Persistent data lives in /state." "${profile_home}/.profile"
)

(
  live_dir="${WORKDIR}/live-preferred/.enclava/config"
  persisted_dir="${WORKDIR}/live-preferred-persisted"
  mkdir -p "${live_dir}" "${persisted_dir}"
  touch "${live_dir%/config}/luks-ready"
  export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_AUTH_TOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${live_dir}"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${persisted_dir}"
  export DEBIAN_SSH_CONFIG_WAIT_SECONDS=1
  unset FRP_AUTH_TOKEN DEBIAN_SSH_AUTHORIZED_KEYS
  printf '%s\n' live-token >"${live_dir}/FRP_AUTH_TOKEN"
  printf '%s\n' "${PUBLIC_KEY}" >"${live_dir}/DEBIAN_SSH_AUTHORIZED_KEYS"
  printf '%s\n' persisted-token >"${persisted_dir}/FRP_AUTH_TOKEN"
  printf '%s\n' persisted-key >"${persisted_dir}/DEBIAN_SSH_AUTHORIZED_KEYS"
  chmod 600 "${persisted_dir}"/*
  wait_for_config
  test -z "${FRP_AUTH_TOKEN:-}"
  load_cap_config
  test "${FRP_AUTH_TOKEN}" = live-token
  test "${DEBIAN_SSH_AUTHORIZED_KEYS}" = "${PUBLIC_KEY}"
)

(
  split_a="${WORKDIR}/split-a/.enclava/config"
  split_b="${WORKDIR}/split-b/.enclava/config"
  mkdir -p "${split_a}" "${split_b}"
  touch "${split_a%/config}/luks-ready" "${split_b%/config}/luks-ready"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${split_a} ${split_b}"
  export DEBIAN_SSH_CONFIG_WAIT_SECONDS=1
  for key in $(required_config_keys); do
    unset "${key}"
  done
  printf '%s\n' relay.enclava.me >"${split_a}/FRP_SERVER_ADDR"
  printf '%s\n' wrong.example.com >"${split_b}/FRP_SERVER_ADDR"
  printf '%s\n' 20000 >"${split_a}/FRP_SERVER_PORT"
  printf '%s\n' bootstrap-token-for-test >"${split_a}/FRP_AUTH_TOKEN"
  printf '%s\n' qa-shell >"${split_a}/FRP_PROXY_NAME"
  printf '%s\n' tcp >"${split_a}/FRP_PROXY_TYPE"
  printf '%s\n' 22001 >"${split_a}/FRP_REMOTE_PORT"
  printf '%s\n' 127.0.0.1 >"${split_a}/FRP_LOCAL_ADDR"
  printf '%s\n' 2222 >"${split_a}/FRP_LOCAL_PORT"
  printf '%s\n' cred_123 >"${split_a}/FRP_TUNNEL_CREDENTIAL_ID"
  printf '%s\n' credential-secret-for-test >"${split_a}/FRP_TUNNEL_SECRET"
  printf '%s\n' relay.enclava.me >"${split_a}/FRP_PUBLIC_HOST"
  printf '%s\n' "${PUBLIC_KEY}" >"${split_b}/DEBIAN_SSH_AUTHORIZED_KEYS"
  wait_for_config
  load_cap_config
  test "${FRP_SERVER_ADDR}" = "relay.enclava.me"
  test "${FRP_REMOTE_PORT}" = "22001"
  test "${DEBIAN_SSH_AUTHORIZED_KEYS}" = "${PUBLIC_KEY}"
)

(
  debug_file="${WORKDIR}/missing-config-debug.txt"
  split_a="${WORKDIR}/missing-a/.enclava/config"
  split_b="${WORKDIR}/missing-b/.enclava/config"
  mkdir -p "${split_a}" "${split_b}"
  touch "${split_a%/config}/luks-ready" "${split_b%/config}/luks-ready"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${split_a} ${split_b}"
  export DEBIAN_SSH_DEBUG_FILE="${debug_file}"
  export DEBIAN_SSH_CONFIG_WAIT_SECONDS=1
  for key in $(required_config_keys); do
    unset "${key}"
  done
  printf '%s\n' relay.enclava.me >"${split_a}/FRP_SERVER_ADDR"
  printf '%s\n' "${PUBLIC_KEY}" >"${split_b}/DEBIAN_SSH_AUTHORIZED_KEYS"
  if wait_for_config 2>"${WORKDIR}/missing-config.err"; then
    echo "error: incomplete config was accepted" >&2
    exit 1
  fi
  grep -Fq "reason=config_timeout" "${debug_file}"
  grep -Fq "dir[1]=${split_a}" "${debug_file}"
  grep -Fq "dir[1].ready=yes" "${debug_file}"
  grep -Fq "dir[2]=${split_b}" "${debug_file}"
  grep -Fq "dir[2].ready=yes" "${debug_file}"
  grep -Fq "key=FRP_AUTH_TOKEN env=missing" "${debug_file}"
  grep -Fq "key=FRP_AUTH_TOKEN dir[1].file=missing readable=no nonempty=no" "${debug_file}"
  grep -Fq "key=DEBIAN_SSH_AUTHORIZED_KEYS dir[2].file=type=regular file" "${debug_file}"
  grep -Fq "CAP config was not ready after 1s" "${WORKDIR}/missing-config.err"
)

(
  persisted_dir="${WORKDIR}/delayed-persisted-config"
  live_dir="${WORKDIR}/delayed-live/.enclava/config"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${live_dir}"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${persisted_dir}"
  export DEBIAN_SSH_CONFIG_WAIT_SECONDS=3
  for key in $(required_config_keys); do
    unset "${key}"
  done
  (
    sleep 1
    mkdir -p "${persisted_dir}"
    chmod 700 "${persisted_dir}"
    printf '%s\n' relay.enclava.me >"${persisted_dir}/FRP_SERVER_ADDR"
    printf '%s\n' 20000 >"${persisted_dir}/FRP_SERVER_PORT"
    printf '%s\n' persisted-token-for-test >"${persisted_dir}/FRP_AUTH_TOKEN"
    printf '%s\n' persisted-shell >"${persisted_dir}/FRP_PROXY_NAME"
    printf '%s\n' tcp >"${persisted_dir}/FRP_PROXY_TYPE"
    printf '%s\n' 22003 >"${persisted_dir}/FRP_REMOTE_PORT"
    printf '%s\n' 127.0.0.1 >"${persisted_dir}/FRP_LOCAL_ADDR"
    printf '%s\n' 2222 >"${persisted_dir}/FRP_LOCAL_PORT"
    printf '%s\n' persisted-credential >"${persisted_dir}/FRP_TUNNEL_CREDENTIAL_ID"
    printf '%s\n' persisted-secret-for-test >"${persisted_dir}/FRP_TUNNEL_SECRET"
    printf '%s\n' relay.enclava.me >"${persisted_dir}/FRP_PUBLIC_HOST"
    printf '%s\n' "${PUBLIC_KEY}" >"${persisted_dir}/DEBIAN_SSH_AUTHORIZED_KEYS"
    chmod 600 "${persisted_dir}"/*
  ) &
  persisted_writer_pid="$!"
  wait_for_config
  wait "${persisted_writer_pid}"
  test "${FRP_AUTH_TOKEN}" = "persisted-token-for-test"
  test "${FRP_REMOTE_PORT}" = "22003"
  test "${DEBIAN_SSH_AUTHORIZED_KEYS}" = "${PUBLIC_KEY}"
)

export FRP_SERVER_ADDR="relay.enclava.me"
export FRP_SERVER_PORT="20000"
export FRP_AUTH_TOKEN="bootstrap-token-for-test"
export FRP_PROXY_NAME="qa-shell"
export FRP_PROXY_TYPE="tcp"
export FRP_REMOTE_PORT="22001"
export FRP_LOCAL_ADDR="127.0.0.1"
export FRP_LOCAL_PORT="2222"
export FRP_TUNNEL_CREDENTIAL_ID="cred_123"
export FRP_TUNNEL_SECRET="credential-secret-for-test"
export FRP_PUBLIC_HOST="relay.enclava.me"
export ENCLAVA_ORG_ID="org_test"
export ENCLAVA_APP_ID="app_test"
export ENCLAVA_DEPLOYMENT_ID="dep_test"

render_frpc_config
grep -q 'auth.additionalScopes = \["HeartBeats", "NewWorkConns"\]' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q '^loginFailExit = false$' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q '^webServer.addr = "127.0.0.1"$' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q '^webServer.port = 7400$' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q '^webServer.user = "enclava"$' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q '^webServer.password = "credential-secret-for-test"$' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q 'metadatas.enclava_tunnel_credential_id = "cred_123"' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q 'metadatas.enclava_tunnel_secret = "credential-secret-for-test"' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q 'metadatas.enclava_org_id = "org_test"' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q 'localIP = "127.0.0.1"' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q 'localPort = 2222' "${DEBIAN_FRP_CONFIG_FILE}"
grep -q 'remotePort = 22001' "${DEBIAN_FRP_CONFIG_FILE}"
test "$(cat "${DEBIAN_FRP_TOKEN_FILE}")" = "bootstrap-token-for-test"
test "$(stat -c "%a" "${DEBIAN_FRP_TOKEN_FILE}")" = "600"
test "$(cat "${DEBIAN_FRP_ADMIN_CURL_CONFIG}")" = 'user = "enclava:credential-secret-for-test"'
test "$(stat -c "%a" "${DEBIAN_FRP_ADMIN_CURL_CONFIG}")" = "600"
test "$(stat -c "%a" "${DEBIAN_FRP_CONFIG_FILE}")" = "600"
test ! -e "${DEBIAN_SSH_HOME}/.config/frp/frpc.toml"
test "$(stat -c "%a" "${DEBIAN_FRP_STATE_DIR}")" = "700"
grep -qx 'transport.tls.enable = true' "${DEBIAN_FRP_CONFIG_FILE}"
test "$(grep -c '^transport.tls.enable = ' "${DEBIAN_FRP_CONFIG_FILE}")" = "1"
grep -qx 'type = "tcp"' "${DEBIAN_FRP_CONFIG_FILE}"
grep -qx 'localIP = "127.0.0.1"' "${DEBIAN_FRP_CONFIG_FILE}"

assert_render_rejects() {
  label="$1"
  pattern="$2"
  err="${WORKDIR}/reject-${label}.err"
  before_cfg="$(cksum "${DEBIAN_FRP_CONFIG_FILE}")"
  before_tok="$(cksum "${DEBIAN_FRP_TOKEN_FILE}")"
  before_curl="$(cksum "${DEBIAN_FRP_ADMIN_CURL_CONFIG}")"
  if render_frpc_config 2>"${err}"; then
    echo "error: ${label} was accepted" >&2
    exit 1
  fi
  test "${before_cfg}" = "$(cksum "${DEBIAN_FRP_CONFIG_FILE}")"
  test "${before_tok}" = "$(cksum "${DEBIAN_FRP_TOKEN_FILE}")"
  test "${before_curl}" = "$(cksum "${DEBIAN_FRP_ADMIN_CURL_CONFIG}")"
  test "$(grep -c '^\[\[proxies\]\]$' "${DEBIAN_FRP_CONFIG_FILE}")" = "1"
  grep -q "${pattern}" "${err}"
  grep -qx 'transport.tls.enable = true' "${DEBIAN_FRP_CONFIG_FILE}"
  if grep -q 'enable = false' "${DEBIAN_FRP_CONFIG_FILE}"; then
    echo "error: ${label} wrote tls disable into frpc.toml" >&2
    exit 1
  fi
}

FRP_TLS_ENABLE=false
assert_render_rejects tls-false "TLS cannot be disabled"
unset FRP_TLS_ENABLE

saved_name="${FRP_PROXY_NAME}"
FRP_PROXY_NAME="$(printf 'qa-shell"\n[[proxies]]\nname = "evil')"
assert_render_rejects proxy-inject "FRP_PROXY_NAME must be a single"
FRP_PROXY_NAME="${saved_name}"

saved_secret="${FRP_TUNNEL_SECRET}"
FRP_TUNNEL_SECRET='secret"injected'
assert_render_rejects secret-inject "FRP_TUNNEL_SECRET must be a single safe token"
FRP_TUNNEL_SECRET="${saved_secret}"

saved_type="${FRP_PROXY_TYPE}"
FRP_PROXY_TYPE="$(printf 'tcp"\n[[proxies]]\nname = "evil')"
assert_render_rejects type-inject "FRP_PROXY_TYPE must be tcp"
FRP_PROXY_TYPE="${saved_type}"

saved_addr="${FRP_LOCAL_ADDR}"
FRP_LOCAL_ADDR="10.0.0.1"
assert_render_rejects local-addr "FRP_LOCAL_ADDR must be 127.0.0.1"
FRP_LOCAL_ADDR="${saved_addr}"

saved_org="${ENCLAVA_ORG_ID}"
ENCLAVA_ORG_ID="$(printf 'org\n[[proxies]]')"
assert_render_rejects org-inject "ENCLAVA_ORG_ID must be a single"
ENCLAVA_ORG_ID="${saved_org}"

saved_token="${FRP_AUTH_TOKEN}"
FRP_AUTH_TOKEN="$(printf 'token\ninjected')"
assert_render_rejects token-newline "FRP_AUTH_TOKEN must be a single token without whitespace"
# Quote and backslash match frp::validate_single_token. They must land in
# the token file only, never in frpc.toml or the admin curl config.
quoted_token="$(printf '%s' "abc'def\"ghi\\bar")"
FRP_AUTH_TOKEN="$quoted_token"
render_frpc_config
test "$(cat "${DEBIAN_FRP_TOKEN_FILE}")" = "$quoted_token"
if grep -F "$quoted_token" "${DEBIAN_FRP_CONFIG_FILE}" "${DEBIAN_FRP_ADMIN_CURL_CONFIG}"; then
  echo "error: login token was interpolated into frpc config" >&2
  exit 1
fi
grep -F "auth.tokenSource.file.path = \"${DEBIAN_FRP_TOKEN_FILE}\"" "${DEBIAN_FRP_CONFIG_FILE}"
grep -qx 'transport.tls.enable = true' "${DEBIAN_FRP_CONFIG_FILE}"
test "$(grep -c '^\[\[proxies\]\]$' "${DEBIAN_FRP_CONFIG_FILE}")" = "1"
FRP_AUTH_TOKEN='bootstrap+token/with=pads'
render_frpc_config
test "$(cat "${DEBIAN_FRP_TOKEN_FILE}")" = "bootstrap+token/with=pads"
grep -qx 'transport.tls.enable = true' "${DEBIAN_FRP_CONFIG_FILE}"
FRP_AUTH_TOKEN="${saved_token}"
render_frpc_config
test "$(cat "${DEBIAN_FRP_TOKEN_FILE}")" = "bootstrap-token-for-test"
grep -q 'name = "qa-shell"' "${DEBIAN_FRP_CONFIG_FILE}"

if validate_host FRP_PUBLIC_HOST "$(printf 'relay.enclava.me\nevil.example')" 2>"${WORKDIR}/multiline-host.err"; then
  echo "error: multiline FRP host was accepted" >&2
  exit 1
fi
grep -q "FRP_PUBLIC_HOST must be a single line" "${WORKDIR}/multiline-host.err"

if validate_secret_path DEBIAN_FRP_TOKEN_FILE "/state/app-data/.enclava/frp/server_token"; then
  :
else
  echo "error: default token path was rejected" >&2
  exit 1
fi
if validate_secret_path DEBIAN_FRP_TOKEN_FILE "/state/app-data/.enclava/../../etc/passwd"; then
  echo "error: token path traversal was accepted" >&2
  exit 1
fi

MOCK_BIN="${WORKDIR}/mock-bin"
mkdir -p "${MOCK_BIN}"
cat >"${MOCK_BIN}/dropbearkey" <<'EOF'
#!/bin/sh
# Mock dropbearkey: -t writes a fresh "key"; -y validates only keys this mock wrote.
f=""
prev=""
for a in "$@"; do
  [ "$prev" = "-f" ] && f="$a"
  prev="$a"
done
case " $* " in
  *" -t "*)
    printf 'mock-dropbear-key\n' >"$f"
    exit 0
    ;;
  *" -y "*)
    [ "$(cat "$f" 2>/dev/null)" = "mock-dropbear-key" ]
    exit $?
    ;;
esac
exit 2
EOF
chmod 755 "${MOCK_BIN}/dropbearkey"

cat >"${MOCK_BIN}/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *telnet://*) printf '%s' "${MOCK_FRP_PUBLIC_BANNER:-}" ;;
  *) printf '%s\n' "${MOCK_FRP_STATUS_JSON}" ;;
esac
EOF
chmod 755 "${MOCK_BIN}/curl"
PATH="${MOCK_BIN}:${PATH}" MOCK_FRP_STATUS_JSON='{"tcp":[{"name":"qa-shell","status":"running"}]}' frp_proxy_ready
if PATH="${MOCK_BIN}:${PATH}" MOCK_FRP_STATUS_JSON='{"tcp":[{"name":"qa-shell","status":"login fail"}]}' frp_proxy_ready; then
  echo "error: failed FRP registration was treated as ready" >&2
  exit 1
fi
PATH="${MOCK_BIN}:${PATH}" MOCK_FRP_PUBLIC_BANNER='SSH-2.0-test' frp_public_ssh_ready
if PATH="${MOCK_BIN}:${PATH}" MOCK_FRP_PUBLIC_BANNER='HTTP/1.1' frp_public_ssh_ready; then
  echo "error: non-SSH public endpoint was treated as ready" >&2
  exit 1
fi

FRP_PUBLIC_HOST="invalid-host"
if render_frpc_config 2>"${WORKDIR}/invalid-host.err"; then
  echo "error: invalid FRP_PUBLIC_HOST was accepted" >&2
  exit 1
fi
grep -q "FRP_PUBLIC_HOST must be a DNS host" "${WORKDIR}/invalid-host.err"
FRP_PUBLIC_HOST="relay.enclava.me"

DEBIAN_SSH_AUTHORIZED_KEYS=""
if write_authorized_keys 2>"${WORKDIR}/missing.err"; then
  echo "error: empty authorized keys were accepted" >&2
  exit 1
fi
grep -q "at least one valid public key" "${WORKDIR}/missing.err"

DEBIAN_SSH_AUTHORIZED_KEYS="-----BEGIN OPENSSH PRIVATE KEY-----"
if write_authorized_keys 2>"${WORKDIR}/private.err"; then
  echo "error: private key material was accepted" >&2
  exit 1
fi
grep -q "public keys, not private keys" "${WORKDIR}/private.err"

DEBIAN_SSH_AUTHORIZED_KEYS="ssh-dss AAAAB3NzaC1kc3MAAACBbad"
if write_authorized_keys 2>"${WORKDIR}/algorithm.err"; then
  echo "error: unsupported SSH key algorithm was accepted" >&2
  exit 1
fi
grep -q "unsupported SSH public key algorithm" "${WORKDIR}/algorithm.err"

DEBIAN_SSH_AUTHORIZED_KEYS="$(printf '# comment\n%s\n%s\n' "${PUBLIC_KEY}" "${PUBLIC_KEY}")"
write_authorized_keys
grep -qxF "${PUBLIC_KEY}" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys"
test "$(grep -cF "${PUBLIC_KEY}" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys")" = "1"
test "$(stat -c "%a" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys")" = "600"

SYNC_MOCK_BIN="${WORKDIR}/sync-mock-bin"
SYNC_MOCK_LOG="${WORKDIR}/sync-mock.log"
mkdir -p "${SYNC_MOCK_BIN}"
cat >"${SYNC_MOCK_BIN}/sync" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYNC_MOCK_LOG"
EOF
chmod 755 "${SYNC_MOCK_BIN}/sync"

PATH="${SYNC_MOCK_BIN}:${PATH}" SYNC_MOCK_LOG="${SYNC_MOCK_LOG}" persist_config
test "$(cat "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN")" = "bootstrap-token-for-test"
test "$(stat -c "%a" "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}")" = "700"
test "$(stat -c "%a" "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN")" = "600"
grep -Fxq -- "-f ${DEBIAN_SSH_PERSISTENCE_PATH}" "${SYNC_MOCK_LOG}"

WRAPPER_CHILD_READY="${WORKDIR}/wrapper-child-ready"
WRAPPER_CHILD_STOPPED="${WORKDIR}/wrapper-child-stopped"
WRAPPER_SYNC_LOG="${WORKDIR}/wrapper-sync.log"
(
  export PATH="${SYNC_MOCK_BIN}:${PATH}"
  export SYNC_MOCK_LOG="${WRAPPER_SYNC_LOG}"
  start_wrapped_child() {
    trap 'printf stopped >"${WRAPPER_CHILD_STOPPED}"; exit 0' INT TERM
    printf ready >"${WRAPPER_CHILD_READY}"
    while :; do sleep 1; done
  }
  run_restart_wrapper
) &
wrapper_pid="$!"
for _ in {1..50}; do
  [[ -f "${WRAPPER_CHILD_READY}" ]] && break
  sleep 0.1
done
test -f "${WRAPPER_CHILD_READY}"
kill -TERM "${wrapper_pid}"
for _ in {1..50}; do
  ! kill -0 "${wrapper_pid}" 2>/dev/null && break
  sleep 0.1
done
if kill -0 "${wrapper_pid}" 2>/dev/null; then
  kill -KILL "${wrapper_pid}" 2>/dev/null || true
  echo "error: restart wrapper did not stop after SIGTERM" >&2
  exit 1
fi
wait "${wrapper_pid}"
test -f "${WRAPPER_CHILD_STOPPED}"
grep -Fxq -- "-f ${DEBIAN_SSH_PERSISTENCE_PATH}" "${WRAPPER_SYNC_LOG}"

if (
  unset FRP_AUTH_TOKEN
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/incomplete-persisted-config"
  persist_config
); then
  echo "error: incomplete config was reported as durably persisted" >&2
  exit 1
fi

mkdir -p "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}"
# A sibling the tenant already uses must survive publish. The old fixed
# stage name lived here and was chmod'd and truncated.
mkdir -p "${WORKDIR}/.enclava-health-stage"
printf 'tenant-secret\n' >"${WORKDIR}/.enclava-health-stage/ssh.txt"
printf 'other\n' >"${WORKDIR}/.enclava-health-stage/notes.txt"
chmod 755 "${WORKDIR}/.enclava-health-stage"
stage_mode="$(stat -c %a "${WORKDIR}/.enclava-health-stage")"
publish_ready
test "$(cat "${WORKDIR}/.enclava-health-stage/ssh.txt")" = "tenant-secret"
test "$(cat "${WORKDIR}/.enclava-health-stage/notes.txt")" = "other"
test "$(stat -c %a "${WORKDIR}/.enclava-health-stage")" = "${stage_mode}"
if find "${WORKDIR}" -maxdepth 1 -name '.enclava-health-stage.*' -print | grep -q .; then
  echo "error: health publish stage was left beside the public root" >&2
  exit 1
fi
test "$(cat "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/ssh.txt")" = "ssh -p 22001 user@relay.enclava.me"
test "$(cat "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/frp-url.txt")" = "tcp://relay.enclava.me:22001"
test "$(cat "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/healthz")" = "ok"
test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/ssh.txt.tmp"
test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/frp-url.txt.tmp"
test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/healthz.tmp"
published_names="$(cd "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}" && find . -mindepth 1 -print | sed 's|^\./||' | sort | tr '\n' ' ')"
test "${published_names}" = "frp-url.txt healthz ssh.txt "

if (
  export DEBIAN_SSH_WRAPPED=1
  export DEBIAN_SSH_HOME="${WORKDIR}/wrapped-home"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${WORKDIR}/wrapped-home/diag/startup-error.txt"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${WORKDIR}/wrapped-home/health"
  fail "wrapped failure test"
); then
  echo "error: wrapped failure did not exit non-zero" >&2
  exit 1
fi
test "$(cat "${WORKDIR}/wrapped-home/diag/startup-error.txt")" = "wrapped failure test"
test ! -e "${WORKDIR}/wrapped-home/health/startup-error.txt"

if grep -q "lio@beast" "${ENTRYPOINT}"; then
  echo "error: committed support key is still present in entrypoint" >&2
  exit 1
fi

# A required key removed from ready customer config is not resurrected from
# the persisted copy. The customer channel is authoritative once the
# customer-required key is visible in a ready config dir, so an absent managed
# key was deleted and load_persisted_config must refuse to restore it.
(
  cap_dir="${WORKDIR}/live-config/.enclava/config"
  mkdir -p "${cap_dir}"
  touch "${cap_dir%/config}/luks-ready"
  printf '%s\n' live-token >"${cap_dir}/FRP_AUTH_TOKEN"
  printf '%s\n' "${PUBLIC_KEY}" >"${cap_dir}/DEBIAN_SSH_AUTHORIZED_KEYS"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${cap_dir}"
  export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_AUTH_TOKEN,DEBIAN_SSH_AUTHORIZED_KEYS,FRP_EXTRA_MANAGED"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/stale-persisted-config"
  mkdir -p "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  printf '%s\n' stale-token >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN"
  printf '%s\n' "${PUBLIC_KEY}" >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/DEBIAN_SSH_AUTHORIZED_KEYS"
  printf '%s\n' stale-managed >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_EXTRA_MANAGED"
  unset FRP_AUTH_TOKEN DEBIAN_SSH_AUTHORIZED_KEYS FRP_EXTRA_MANAGED
  load_cap_config || true
  test "${FRP_AUTH_TOKEN}" = "live-token"
  if load_persisted_config; then
    echo "error: deleted required key was resurrected from persisted config" >&2
    exit 1
  fi
  test -z "${FRP_EXTRA_MANAGED:-}"
)

# A customer who deletes DEBIAN_SSH_AUTHORIZED_KEYS from a ready
# .enclava/config dir revokes SSH access: the .ready delivery sentinel (or the
# luks-ready marker) stays behind, so the persisted copy must not resurrect
# the removed key.
(
  cap_dir="${WORKDIR}/deleted-ssh-key/.enclava/config"
  mkdir -p "${cap_dir}"
  touch "${cap_dir%/config}/luks-ready" "${cap_dir}/.ready"
  printf '%s\n' live-token >"${cap_dir}/FRP_AUTH_TOKEN"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${cap_dir}"
  export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_AUTH_TOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/deleted-key-persisted"
  mkdir -p "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  printf '%s\n' live-token >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN"
  printf '%s\n' "${PUBLIC_KEY}" >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/DEBIAN_SSH_AUTHORIZED_KEYS"
  unset FRP_AUTH_TOKEN DEBIAN_SSH_AUTHORIZED_KEYS
  load_cap_config || true
  test "${FRP_AUTH_TOKEN}" = "live-token"
  if load_persisted_config; then
    echo "error: deleted DEBIAN_SSH_AUTHORIZED_KEYS was resurrected from persisted config" >&2
    exit 1
  fi
  test -z "${DEBIAN_SSH_AUTHORIZED_KEYS:-}"
)

# Emptying the key file instead of deleting it is the same revocation: an
# empty delivered file is not a delivered key, and the persisted copy must
# still not fill it back in.
(
  cap_dir="${WORKDIR}/emptied-ssh-key/.enclava/config"
  mkdir -p "${cap_dir}"
  touch "${cap_dir%/config}/luks-ready" "${cap_dir}/.ready"
  printf '%s\n' live-token >"${cap_dir}/FRP_AUTH_TOKEN"
  : >"${cap_dir}/DEBIAN_SSH_AUTHORIZED_KEYS"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${cap_dir}"
  export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_AUTH_TOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/emptied-key-persisted"
  mkdir -p "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  printf '%s\n' live-token >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN"
  printf '%s\n' "${PUBLIC_KEY}" >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/DEBIAN_SSH_AUTHORIZED_KEYS"
  unset FRP_AUTH_TOKEN DEBIAN_SSH_AUTHORIZED_KEYS
  load_cap_config || true
  test "${FRP_AUTH_TOKEN}" = "live-token"
  if load_persisted_config; then
    echo "error: emptied DEBIAN_SSH_AUTHORIZED_KEYS was resurrected from persisted config" >&2
    exit 1
  fi
  test -z "${DEBIAN_SSH_AUTHORIZED_KEYS:-}"
)

# A ready managed-only dir (FRP keys, no customer channel) must not prove
# deletion: the persisted fallback still bridges pod replacement before the
# customer config is re-delivered, and live managed values win over the
# persisted copy.
(
  managed_dir="${WORKDIR}/managed-config/config"
  mkdir -p "${managed_dir}"
  touch "${managed_dir}/.ready"
  printf '%s\n' managed-token >"${managed_dir}/FRP_AUTH_TOKEN"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${managed_dir} ${WORKDIR}/customer-config/config"
  export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_AUTH_TOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/split-persisted-config"
  mkdir -p "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  printf '%s\n' stale-token >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN"
  printf '%s\n' "${PUBLIC_KEY}" >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/DEBIAN_SSH_AUTHORIZED_KEYS"
  unset FRP_AUTH_TOKEN DEBIAN_SSH_AUTHORIZED_KEYS
  load_persisted_config
  test "${FRP_AUTH_TOKEN}" = "managed-token"
  test "${DEBIAN_SSH_AUTHORIZED_KEYS}" = "${PUBLIC_KEY}"
)

# When a live config dir is ready, its values win over the persisted copy even
# when load_persisted_config runs before load_cap_config (the wait_for_config
# ordering).
(
  cap_dir="${WORKDIR}/live-override/.enclava/config"
  mkdir -p "${cap_dir}"
  touch "${cap_dir%/config}/luks-ready"
  printf '%s\n' live-token >"${cap_dir}/FRP_AUTH_TOKEN"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${cap_dir}"
  export ENCLAVA_REQUIRED_CONFIG_KEYS="FRP_AUTH_TOKEN"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${WORKDIR}/stale-override-config"
  mkdir -p "${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  printf '%s\n' stale-token >"${DEBIAN_SSH_PERSISTED_CONFIG_DIR}/FRP_AUTH_TOKEN"
  unset FRP_AUTH_TOKEN
  load_persisted_config
  test "${FRP_AUTH_TOKEN}" = "live-token"
)

# A missing key on a normal first boot generates quietly: no "invalid"
# log line, no sidecar.
(
  fresh_home="${WORKDIR}/fresh-ready-home"
  export DEBIAN_SSH_HOME="${fresh_home}"
  export DEBIAN_SSH_READY_KEY="${fresh_home}/.ssh/ssh_ready_ed25519_key"
  mkdir -p "${fresh_home}/.ssh"
  chmod 700 "${fresh_home}" "${fresh_home}/.ssh"
  prepare_ssh_ready_key 2>"${WORKDIR}/fresh-ready.err"
  ssh-keygen -y -f "${DEBIAN_SSH_READY_KEY}" >/dev/null 2>&1
  test ! -e "${DEBIAN_SSH_READY_KEY}.corrupt"
  ! grep -Fq "invalid" "${WORKDIR}/fresh-ready.err"
)

(
  fresh_host_home="${WORKDIR}/fresh-host-home"
  export DEBIAN_SSH_HOME="${fresh_host_home}"
  export DEBIAN_SSH_HOST_KEY="${fresh_host_home}/.ssh/dropbear_ed25519_host_key"
  mkdir -p "${fresh_host_home}/.ssh"
  chmod 700 "${fresh_host_home}" "${fresh_host_home}/.ssh"
  PATH="${MOCK_BIN}:${PATH}" ensure_dropbear_host_key 2>"${WORKDIR}/fresh-host.err"
  test "$(cat "${DEBIAN_SSH_HOST_KEY}")" = "mock-dropbear-key"
  test ! -e "${DEBIAN_SSH_HOST_KEY}.corrupt"
  ! grep -Fq "invalid" "${WORKDIR}/fresh-host.err"
)

# The first preserved corrupt copy wins: a later corruption (e.g. an
# interrupted regeneration) never overwrites the original sidecar bytes.
(
  twice_home="${WORKDIR}/twice-ready-home"
  export DEBIAN_SSH_HOME="${twice_home}"
  export DEBIAN_SSH_READY_KEY="${twice_home}/.ssh/ssh_ready_ed25519_key"
  mkdir -p "${twice_home}/.ssh"
  chmod 700 "${twice_home}" "${twice_home}/.ssh"
  printf 'first-corrupt-bytes\n' >"${DEBIAN_SSH_READY_KEY}"
  prepare_ssh_ready_key 2>/dev/null
  ssh-keygen -y -f "${DEBIAN_SSH_READY_KEY}" >/dev/null 2>&1
  test "$(cat "${DEBIAN_SSH_READY_KEY}.corrupt")" = "first-corrupt-bytes"
  printf 'second-corrupt-bytes\n' >"${DEBIAN_SSH_READY_KEY}"
  prepare_ssh_ready_key 2>/dev/null
  ssh-keygen -y -f "${DEBIAN_SSH_READY_KEY}" >/dev/null 2>&1
  test "$(cat "${DEBIAN_SSH_READY_KEY}.corrupt")" = "first-corrupt-bytes"
)

# A corrupt persistent readiness key is regenerated (and the bad copy kept)
# instead of crashing the entrypoint forever (#132).
(
  corrupt_home="${WORKDIR}/corrupt-ready-home"
  export DEBIAN_SSH_HOME="${corrupt_home}"
  export DEBIAN_SSH_READY_KEY="${corrupt_home}/.ssh/ssh_ready_ed25519_key"
  mkdir -p "${corrupt_home}/.ssh"
  chmod 700 "${corrupt_home}" "${corrupt_home}/.ssh"
  printf 'corrupt-private-key-bytes\n' >"${DEBIAN_SSH_READY_KEY}"
  prepare_ssh_ready_key
  ssh-keygen -y -f "${DEBIAN_SSH_READY_KEY}" >/dev/null 2>&1
  test "$(cat "${DEBIAN_SSH_READY_KEY}.corrupt")" = "corrupt-private-key-bytes"
  grep -qxF "$(cat "${DEBIAN_SSH_READY_KEY}.pub")" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys"
)

# A valid persistent readiness key is kept as-is (no regeneration churn).
(
  keep_home="${WORKDIR}/keep-ready-home"
  export DEBIAN_SSH_HOME="${keep_home}"
  export DEBIAN_SSH_READY_KEY="${keep_home}/.ssh/ssh_ready_ed25519_key"
  mkdir -p "${keep_home}/.ssh"
  chmod 700 "${keep_home}" "${keep_home}/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C keep-test -f "${DEBIAN_SSH_READY_KEY}"
  before="$(cat "${DEBIAN_SSH_READY_KEY}")"
  prepare_ssh_ready_key
  test "$(cat "${DEBIAN_SSH_READY_KEY}")" = "${before}"
  test ! -e "${DEBIAN_SSH_READY_KEY}.corrupt"
)

# A corrupt persistent dropbear host key is regenerated (and kept aside).
(
  corrupt_host_home="${WORKDIR}/corrupt-host-home"
  export DEBIAN_SSH_HOME="${corrupt_host_home}"
  export DEBIAN_SSH_HOST_KEY="${corrupt_host_home}/.ssh/dropbear_ed25519_host_key"
  mkdir -p "${corrupt_host_home}/.ssh"
  chmod 700 "${corrupt_host_home}" "${corrupt_host_home}/.ssh"
  printf 'corrupt-host-key-bytes\n' >"${DEBIAN_SSH_HOST_KEY}"
  PATH="${MOCK_BIN}:${PATH}" ensure_dropbear_host_key
  test "$(cat "${DEBIAN_SSH_HOST_KEY}")" = "mock-dropbear-key"
  test "$(cat "${DEBIAN_SSH_HOST_KEY}.corrupt")" = "corrupt-host-key-bytes"
)

# The restart wrapper gives up after the configured budget of consecutive
# never-ready startup failures instead of restarting forever. The temporary
# frp state dir has no ready marker, so every child counts.
(
  export DEBIAN_SSH_RESTART_DELAY_SECONDS=0
  export DEBIAN_SSH_MAX_RESTARTS=3
  rm -f "${DEBIAN_SSH_READY_MARKER}"
  start_wrapped_child() { exit 1; }
  run_restart_wrapper
) 2>"${WORKDIR}/budget.err" && {
  echo "error: restart wrapper did not give up on repeated failure" >&2
  exit 1
}
grep -Fq "failed 3 consecutive times" "${WORKDIR}/budget.err"

# A successful child exit restarts with status 0 (status must be initialized
# for the success case, not just captured on failure).
(
  export DEBIAN_SSH_RESTART_DELAY_SECONDS=0
  export DEBIAN_SSH_MAX_RESTARTS=2
  rm -f "${DEBIAN_SSH_READY_MARKER}"
  start_wrapped_child() { exit 0; }
  run_restart_wrapper
) 2>"${WORKDIR}/success-cycle.err" && {
  echo "error: never-ready child with successful exit exhausted the budget unexpectedly" >&2
  exit 1
}
grep -Fq "exited with status 0" "${WORKDIR}/success-cycle.err"

# A workload that keeps recovering keeps its restart budget: each child
# reaches ready during its own run (marker cleared at child start, touched
# on readiness), so the budget resets every cycle.
(
  export DEBIAN_SSH_RESTART_DELAY_SECONDS=0
  export DEBIAN_SSH_MAX_RESTARTS=3
  rm -f "${DEBIAN_SSH_READY_MARKER}"
  start_wrapped_child() { touch "${DEBIAN_SSH_READY_MARKER}"; exit 1; }
  run_restart_wrapper &
  wrapper_pid="$!"
  sleep 2
  if ! kill -0 "${wrapper_pid}" 2>/dev/null; then
    echo "error: restart wrapper exhausted the budget despite recovering children" >&2
    exit 1
  fi
  kill -TERM "${wrapper_pid}" 2>/dev/null || true
  wait "${wrapper_pid}" 2>/dev/null || true
  rm -f "${DEBIAN_SSH_READY_MARKER}"
)

# Readiness from a PREVIOUS child does not immunize later ones: after one
# ready child, persistent failures exhaust the budget (config channel lost
# after a healthy boot must surface, not loop forever).
(
  export DEBIAN_SSH_RESTART_DELAY_SECONDS=0
  export DEBIAN_SSH_MAX_RESTARTS=2
  rm -f "${DEBIAN_SSH_READY_MARKER}" "${WORKDIR}/marker-once"
  start_wrapped_child() {
    if [ ! -f "${WORKDIR}/marker-once" ]; then
      : >"${WORKDIR}/marker-once"
      touch "${DEBIAN_SSH_READY_MARKER}"
    fi
    exit 1
  }
  run_restart_wrapper
) 2>"${WORKDIR}/stale-marker.err" && {
  echo "error: stale readiness marker granted permanent budget immunity" >&2
  exit 1
}
grep -Fq "failed 2 consecutive times" "${WORKDIR}/stale-marker.err"
rm -f "${WORKDIR}/marker-once"

# A ready child never counts toward the budget, not even off-by-one:
# DEBIAN_SSH_MAX_RESTARTS=1 must restart a child that reached ready, not
# terminate the serving workload on its first exit.
(
  export DEBIAN_SSH_RESTART_DELAY_SECONDS=0
  export DEBIAN_SSH_MAX_RESTARTS=1
  rm -f "${DEBIAN_SSH_READY_MARKER}"
  start_wrapped_child() { touch "${DEBIAN_SSH_READY_MARKER}"; exit 1; }
  run_restart_wrapper &
  wrapper_pid="$!"
  sleep 1
  if ! kill -0 "${wrapper_pid}" 2>/dev/null; then
    echo "error: ready child exhausted the budget via off-by-one" >&2
    exit 1
  fi
  kill -TERM "${wrapper_pid}" 2>/dev/null || true
  wait "${wrapper_pid}" 2>/dev/null || true
  rm -f "${DEBIAN_SSH_READY_MARKER}"
)

# A non-numeric restart budget fails fast instead of silently unbounding.
(
  export DEBIAN_SSH_MAX_RESTARTS=not-a-number
  start_wrapped_child() { exit 0; }
  run_restart_wrapper
) 2>"${WORKDIR}/bad-budget.err" && {
  echo "error: invalid restart budget was accepted" >&2
  exit 1
}
grep -Fq "DEBIAN_SSH_MAX_RESTARTS must be an integer" "${WORKDIR}/bad-budget.err"

# Issue #237: the public app port must not publish debug or startup-error.
(
  unset DEBIAN_SSH_DEBUG_FILE
  unset DEBIAN_SSH_STARTUP_ERROR_FILE
  unset DEBIAN_SSH_PUBLIC_HEALTH_DIR
  unset DEBIAN_SSH_LOCAL_DIAG_DIR
  export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
  export DEBIAN_SSH_HOME="${WORKDIR}/default-diag-home"
  # shellcheck source=../deployment-templates/debian-ssh-frp/entrypoint.sh
  . "${ENTRYPOINT}"
  case "${DEBIAN_SSH_DEBUG_FILE}" in
    "${DEBIAN_SSH_HOME}/health"|"${DEBIAN_SSH_HOME}/health"/*)
      echo "error: default debug file is inside the public health root" >&2
      exit 1
      ;;
  esac
  case "${DEBIAN_SSH_STARTUP_ERROR_FILE}" in
    "${DEBIAN_SSH_HOME}/health"|"${DEBIAN_SSH_HOME}/health"/*)
      echo "error: default startup-error file is inside the public health root" >&2
      exit 1
      ;;
  esac
  test "${DEBIAN_SSH_DEBUG_FILE}" = "${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  test "${DEBIAN_SSH_STARTUP_ERROR_FILE}" = "${DEBIAN_SSH_LOCAL_DIAG_DIR}/startup-error.txt"
  test "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}" = "/state/app-data/.enclava/debian-ssh-frp/public"
  test "${DEBIAN_SSH_PUBLIC_HTTPD_CONF}" = "/state/app-data/.enclava/debian-ssh-frp/httpd/public.httpd.conf"
  test "${DEBIAN_SSH_LOCAL_DIAG_DIR}" = "/state/app-data/.enclava/debian-ssh-frp/diag"
)

# Production defaults must pass the lockdown checks. The previous httpd
# config lived in the parent of config/, so refuse_httpd_conf_dir rejected
# every default boot. Do not call start_health here: that would create the
# production directories.
(
  unset DEBIAN_SSH_DEBUG_FILE
  unset DEBIAN_SSH_STARTUP_ERROR_FILE
  unset DEBIAN_SSH_PUBLIC_HEALTH_DIR
  unset DEBIAN_SSH_LOCAL_DIAG_DIR
  unset DEBIAN_SSH_PUBLIC_HTTPD_CONF
  unset DEBIAN_SSH_PERSISTED_CONFIG_DIR
  unset DEBIAN_SSH_PERSISTENCE_PATH
  unset DEBIAN_FRP_STATE_DIR
  unset DEBIAN_SSH_HOME
  unset DEBIAN_SSH_CAP_CONFIG_DIRS
  export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
  # shellcheck source=../deployment-templates/debian-ssh-frp/entrypoint.sh
  . "${ENTRYPOINT}"
  refuse_public_health_overlap
  refuse_httpd_conf_dir
  refuse_diag_dir
  test "$(health_publish_parent)" = "/state/app-data/.enclava/debian-ssh-frp"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="/state/app-data/.enclava/debian-ssh-frp/public.httpd.conf"
  if refuse_httpd_conf_dir; then
    echo "error: default-parent httpd config directory was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="/state/app-data/.enclava/config/FRP_AUTH_TOKEN"
  if refuse_httpd_conf_dir; then
    echo "error: httpd config inside the default CAP config directory was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="/home/user/.enclava/config/DEBIAN_SSH_AUTHORIZED_KEYS"
  if refuse_httpd_conf_dir; then
    echo "error: httpd config inside the home CAP config directory was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/health
  test "$(health_publish_parent)" = "/"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/health/
  test "$(health_publish_parent)" = "/"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/
  if health_publish_parent; then
    echo "error: health root / produced a stage parent" >&2
    exit 1
  fi
)
if ! /bin/sh -c '
  set -u
  export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
  . "$1"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/health
  parent="$(health_publish_parent)" || exit 1
  [ "$parent" = "/" ] || exit 1
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/
  if health_publish_parent; then
    exit 1
  fi
' sh "${ENTRYPOINT}"; then
  echo "error: dash health_publish_parent rejected /health" >&2
  exit 1
fi

if ! command -v busybox >/dev/null 2>&1; then
  echo "error: busybox is required to prove diagnostics are not published on the app port" >&2
  exit 2
fi

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
reserved_health_port() {
  case "$1" in
    2222|7400|8080|18080) return 0 ;;
  esac
  return 1
}
public_port="$(pick_port)"
while reserved_health_port "${public_port}"; do
  public_port="$(pick_port)"
done
local_port="$(pick_port)"
while [[ "${local_port}" == "${public_port}" ]] || reserved_health_port "${local_port}"; do
  local_port="$(pick_port)"
done

(
  export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
  unset DEBIAN_SSH_DEBUG_FILE
  unset DEBIAN_SSH_STARTUP_ERROR_FILE
  export DEBIAN_SSH_HOME="${WORKDIR}/http-home"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${WORKDIR}/public-health"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${WORKDIR}/http-diag"
  export DEBIAN_HEALTH_PORT="${public_port}"
  export DEBIAN_HEALTH_LOCAL_PORT="${local_port}"
  # shellcheck source=../deployment-templates/debian-ssh-frp/entrypoint.sh
  . "${ENTRYPOINT}"
  trap 'for pid in "${HEALTH_PID:-}" "${HEALTH_LOCAL_PID:-}"; do [ -n "$pid" ] && [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null || true; done' EXIT

  export DEBIAN_SSH_LOCAL_DIAG_DIR="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/nested-diag"
  if start_health; then
    echo "error: diagnostic directory inside the public health root was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${WORKDIR}/http-diag"
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/debug.txt"
  if start_health; then
    echo "error: debug file inside the public health root was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/startup-error.txt"
  if start_health; then
    echo "error: startup-error file inside the public health root was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/startup-error.txt"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${WORKDIR}/httpd-meta/public.httpd.conf"
  mkdir -p "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}"
  # Non-canonical paths that still land in the served directory must be refused.
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/./debug.txt"
  if start_health; then
    echo "error: non-canonical debug path inside the public health root was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  saved_public="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${DEBIAN_SSH_HOME}/health"
  if start_health; then
    echo "error: health root inside the SSH home was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${saved_public}"
  mkdir -p "${WORKDIR}/outside" "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub"
  ln -s "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub" "${WORKDIR}/outside/link"
  export DEBIAN_SSH_DEBUG_FILE="${WORKDIR}/outside/link/../debug.txt"
  if start_health; then
    echo "error: symlink .. path into the public root was accepted" >&2
    exit 1
  fi
  mkdir -p "${DEBIAN_SSH_LOCAL_DIAG_DIR}"
  ln -sfn "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/leaked.txt" "${DEBIAN_SSH_LOCAL_DIAG_DIR}/via-link"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/via-link"
  if start_health; then
    echo "error: final symlink into the public root was accepted" >&2
    exit 1
  fi
  if (
    export DEBIAN_SSH_WRAPPED=1
    fail "should not follow symlink"
  ); then
    echo "error: symlink startup-error write returned success" >&2
    exit 1
  fi
  test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/leaked.txt"
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/startup-error.txt"

  # ".." after a missing component is applied by mkdir -p + open. The
  # uncollapsed string looks outside the docroot; the created file is not.
  escape_root="${WORKDIR}/escape-root"
  mkdir -p "${escape_root}/outside" "${escape_root}/public/sub"
  rm -rf "${escape_root}/outside/missing" "${escape_root}/outside/missing2"
  ln -s "${escape_root}/public/sub" "${escape_root}/outside/link"
  saved_escape_public="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${escape_root}/public"
  export DEBIAN_SSH_DEBUG_FILE="${escape_root}/outside/missing/../../public/debug.txt"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/startup-error.txt"
  if write_debug_snapshot; then
    echo "error: write_debug_snapshot accepted outside/missing/../../public/debug.txt" >&2
    exit 1
  fi
  if [[ -e "${escape_root}/public/debug.txt" || -e "${escape_root}/public/debug.txt.tmp" ]]; then
    echo "error: write_debug_snapshot created the public debug file via a missing-component .. path" >&2
    exit 1
  fi
  if start_health; then
    echo "error: start_health accepted outside/missing/../../public/debug.txt" >&2
    exit 1
  fi
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${escape_root}/outside/missing2/../../public/startup-error.txt"
  rm -rf "${escape_root}/outside/missing2"
  if (
    export DEBIAN_SSH_WRAPPED=1
    fail "startup-leaked"
  ); then
    echo "error: fail() returned success for outside/missing2/../../public/startup-error.txt" >&2
    exit 1
  fi
  if [[ -e "${escape_root}/public/startup-error.txt" ]]; then
    echo "error: fail() created the public startup-error file via a missing-component .. path" >&2
    exit 1
  fi
  if start_health; then
    echo "error: start_health accepted outside/missing2/../../public/startup-error.txt" >&2
    exit 1
  fi
  # ".." that walks back onto an existing symlink is followed by the same open.
  export DEBIAN_SSH_DEBUG_FILE="${escape_root}/outside/missing/../link/../debug.txt"
  rm -rf "${escape_root}/outside/missing" "${escape_root}/public/debug.txt"
  if write_debug_snapshot; then
    echo "error: write_debug_snapshot accepted outside/missing/../link/../debug.txt" >&2
    exit 1
  fi
  if [[ -e "${escape_root}/public/debug.txt" ]]; then
    echo "error: write_debug_snapshot created the public debug file via a missing component and a symlink" >&2
    exit 1
  fi
  if ! /bin/sh -c '
    set -u
    export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
    export DEBIAN_SSH_PUBLIC_HEALTH_DIR="$1"
    export DEBIAN_SSH_DEBUG_FILE="$2"
    export DEBIAN_SSH_STARTUP_ERROR_FILE="$3"
    . "$4"
    path_is_inside "$DEBIAN_SSH_DEBUG_FILE" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" || {
      echo "dash: outside/missing/../../public/debug.txt was not inside" >&2
      exit 1
    }
    path_is_inside "$DEBIAN_SSH_STARTUP_ERROR_FILE" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" || {
      echo "dash: outside/missing2/../../public/startup-error.txt was not inside" >&2
      exit 1
    }
  ' sh \
    "${escape_root}/public" \
    "${escape_root}/outside/missing/../../public/debug.txt" \
    "${escape_root}/outside/missing2/../../public/startup-error.txt" \
    "${ENTRYPOINT}"
  then
    echo "error: dash did not refuse the missing-component escape" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${saved_escape_public}"
  export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/debug.txt"
  export DEBIAN_SSH_STARTUP_ERROR_FILE="${DEBIAN_SSH_LOCAL_DIAG_DIR}/startup-error.txt"

  # A health root that contains the SSH home must be refused before any
  # chmod or delete. Production /home/user is a symlink into app-data.
  ancestor="${WORKDIR}/state/app-data/home"
  mkdir -p "${ancestor}/user/.ssh"
  printf 'hostkey\n' >"${ancestor}/user/.ssh/dropbear_ed25519_host_key"
  chmod 755 "${ancestor}"
  ancestor_mode="$(stat -c %a "${ancestor}")"
  ln -s "${ancestor}/user" "${WORKDIR}/ssh-home-link"
  saved_overlap_home="${DEBIAN_SSH_HOME}"
  saved_overlap_public="${DEBIAN_SSH_PUBLIC_HEALTH_DIR}"
  saved_overlap_config="${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  saved_overlap_persist="${DEBIAN_SSH_PERSISTENCE_PATH}"
  export DEBIAN_SSH_HOME="${WORKDIR}/ssh-home-link"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${ancestor}"
  if start_health; then
    echo "error: health root containing the symlinked SSH home was accepted" >&2
    exit 1
  fi
  test "$(cat "${ancestor}/user/.ssh/dropbear_ed25519_host_key")" = "hostkey"
  test "$(stat -c %a "${ancestor}")" = "${ancestor_mode}"
  export DEBIAN_SSH_HOME="${ancestor}/user"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${ancestor}"
  if start_health; then
    echo "error: health root containing the SSH home was accepted" >&2
    exit 1
  fi
  test "$(cat "${ancestor}/user/.ssh/dropbear_ed25519_host_key")" = "hostkey"

  cfg_parent="${WORKDIR}/cfg-parent"
  mkdir -p "${cfg_parent}/config"
  printf 'secret-token\n' >"${cfg_parent}/config/FRP_AUTH_TOKEN"
  export DEBIAN_SSH_HOME="${saved_overlap_home}"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${cfg_parent}/config"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${cfg_parent}/config"
  if start_health; then
    echo "error: health root equal to persisted config was accepted" >&2
    exit 1
  fi
  test "$(cat "${cfg_parent}/config/FRP_AUTH_TOKEN")" = "secret-token"
  mkdir -p "${cfg_parent}/config/public"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${cfg_parent}/config/public"
  if start_health; then
    echo "error: health root inside persisted config was accepted" >&2
    exit 1
  fi
  test "$(cat "${cfg_parent}/config/FRP_AUTH_TOKEN")" = "secret-token"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${cfg_parent}"
  if start_health; then
    echo "error: health root containing persisted config was accepted" >&2
    exit 1
  fi
  test "$(cat "${cfg_parent}/config/FRP_AUTH_TOKEN")" = "secret-token"

  mkdir -p "${DEBIAN_FRP_STATE_DIR}"
  printf 'frp-token\n' >"${DEBIAN_FRP_STATE_DIR}/server_token"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${saved_overlap_config}"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${DEBIAN_FRP_STATE_DIR}"
  if start_health; then
    echo "error: health root equal to FRP state was accepted" >&2
    exit 1
  fi
  test "$(cat "${DEBIAN_FRP_STATE_DIR}/server_token")" = "frp-token"

  persist_parent="${WORKDIR}/persist-parent"
  mkdir -p "${persist_parent}/data"
  printf 'durable\n' >"${persist_parent}/data/canary"
  export DEBIAN_SSH_PERSISTENCE_PATH="${persist_parent}/data"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${persist_parent}/data"
  if start_health; then
    echo "error: health root equal to the persistence path was accepted" >&2
    exit 1
  fi
  test "$(cat "${persist_parent}/data/canary")" = "durable"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${persist_parent}"
  if start_health; then
    echo "error: health root containing the persistence path was accepted" >&2
    exit 1
  fi
  test "$(cat "${persist_parent}/data/canary")" = "durable"
  export DEBIAN_SSH_PERSISTENCE_PATH="${saved_overlap_persist}"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${saved_overlap_public}"

  # "/" as a case prefix is "//*", which does not match "/etc". A health
  # root of / must be refused without chmod or rm. Do not call start_health
  # on /: a regression would empty the test host.
  if ! /bin/sh -c '
    set -u
    export DEBIAN_SSH_FRP_ENTRYPOINT_TEST=1
    . "$1"
    path_is_inside /etc / || {
      echo "dash: / does not contain /etc" >&2
      exit 1
    }
    if path_is_inside /tmp/a /tmp/b; then
      echo "dash: /tmp/a was inside /tmp/b" >&2
      exit 1
    fi
  ' sh "${ENTRYPOINT}"; then
    echo "error: dash path_is_inside / check failed" >&2
    exit 1
  fi
  root_mode="$(stat -c %a /)"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/
  if refuse_public_health_overlap; then
    echo "error: health root / was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=//
  if refuse_public_health_overlap; then
    echo "error: health root // was accepted" >&2
    exit 1
  fi
  ln -s / "${WORKDIR}/slash-link"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${WORKDIR}/slash-link"
  if refuse_public_health_overlap; then
    echo "error: health root symlink to / was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a /)" = "${root_mode}"
  test "$(resolve_open_path /proc/self/root)" = "/"
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR=/proc/self/root
  if refuse_public_health_overlap; then
    echo "error: health root /proc/self/root was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PUBLIC_HEALTH_DIR="${saved_overlap_public}"

  saved_conf="${DEBIAN_SSH_PUBLIC_HTTPD_CONF}"
  mkdir -p "${DEBIAN_SSH_HOME}/.ssh"
  printf 'hostkey\n' >"${DEBIAN_SSH_HOME}/.ssh/conf-canary"
  chmod 755 "${DEBIAN_SSH_HOME}"
  home_mode="$(stat -c %a "${DEBIAN_SSH_HOME}")"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${DEBIAN_SSH_HOME}/public.httpd.conf"
  if start_health; then
    echo "error: httpd config inside the SSH home was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${DEBIAN_SSH_HOME}")" = "${home_mode}"
  test "$(cat "${DEBIAN_SSH_HOME}/.ssh/conf-canary")" = "hostkey"
  ln -s "${DEBIAN_SSH_HOME}" "${WORKDIR}/home-conf-link"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${WORKDIR}/home-conf-link/public.httpd.conf"
  if start_health; then
    echo "error: httpd config via a symlink to the SSH home was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${DEBIAN_SSH_HOME}")" = "${home_mode}"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${saved_conf}"

  saved_ssh_port="${DEBIAN_SSH_PORT}"
  saved_admin_port="${DEBIAN_FRP_ADMIN_PORT}"
  export DEBIAN_SSH_PORT="${DEBIAN_HEALTH_LOCAL_PORT}"
  if start_health; then
    echo "error: diagnostic port colliding with the SSH port was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PORT="${saved_ssh_port}"
  export DEBIAN_FRP_ADMIN_PORT="${DEBIAN_HEALTH_LOCAL_PORT}"
  if start_health; then
    echo "error: diagnostic port colliding with the FRP admin port was accepted" >&2
    exit 1
  fi
  export DEBIAN_FRP_ADMIN_PORT="${DEBIAN_HEALTH_PORT}"
  if start_health; then
    echo "error: public health port colliding with the FRP admin port was accepted" >&2
    exit 1
  fi
  export DEBIAN_FRP_ADMIN_PORT="${saved_admin_port}"
  export DEBIAN_SSH_PORT="${DEBIAN_HEALTH_PORT}"
  if start_health; then
    echo "error: public health port colliding with the SSH port was accepted" >&2
    exit 1
  fi
  export DEBIAN_SSH_PORT="${saved_ssh_port}"

  # Diagnostic root must not be chmod'd when it is the SSH home, an ancestor,
  # persisted config, FRP state, or the persistence path. cgi-bin and
  # httpd.conf in that tree are customer files.
  saved_diag="${DEBIAN_SSH_LOCAL_DIAG_DIR}"
  saved_diag_home="${DEBIAN_SSH_HOME}"
  saved_diag_cfg="${DEBIAN_SSH_PERSISTED_CONFIG_DIR}"
  saved_diag_persist="${DEBIAN_SSH_PERSISTENCE_PATH}"
  mkdir -p "${DEBIAN_SSH_HOME}/cgi-bin"
  printf 'customer-cgi\n' >"${DEBIAN_SSH_HOME}/cgi-bin/keep"
  printf 'customer-httpd\n' >"${DEBIAN_SSH_HOME}/httpd.conf"
  chmod 755 "${DEBIAN_SSH_HOME}"
  home_mode="$(stat -c %a "${DEBIAN_SSH_HOME}")"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${DEBIAN_SSH_HOME}"
  if start_health; then
    echo "error: diagnostic directory equal to the SSH home was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${DEBIAN_SSH_HOME}")" = "${home_mode}"
  test "$(cat "${DEBIAN_SSH_HOME}/cgi-bin/keep")" = "customer-cgi"
  test "$(cat "${DEBIAN_SSH_HOME}/httpd.conf")" = "customer-httpd"

  diag_ancestor="${WORKDIR}/diag-ancestor"
  mkdir -p "${diag_ancestor}/user/.ssh" "${diag_ancestor}/cgi-bin"
  printf 'hostkey\n' >"${diag_ancestor}/user/.ssh/canary"
  printf 'keep-cgi\n' >"${diag_ancestor}/cgi-bin/x"
  printf 'keep-httpd\n' >"${diag_ancestor}/httpd.conf"
  chmod 755 "${diag_ancestor}"
  ancestor_mode="$(stat -c %a "${diag_ancestor}")"
  export DEBIAN_SSH_HOME="${diag_ancestor}/user"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${diag_ancestor}"
  if start_health; then
    echo "error: diagnostic directory containing the SSH home was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${diag_ancestor}")" = "${ancestor_mode}"
  test "$(cat "${diag_ancestor}/user/.ssh/canary")" = "hostkey"
  test "$(cat "${diag_ancestor}/cgi-bin/x")" = "keep-cgi"
  test "$(cat "${diag_ancestor}/httpd.conf")" = "keep-httpd"
  ln -sfn "${diag_ancestor}/user" "${WORKDIR}/diag-home-link"
  export DEBIAN_SSH_HOME="${WORKDIR}/diag-home-link"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${diag_ancestor}/user"
  if start_health; then
    echo "error: diagnostic directory equal to the resolved SSH home was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${diag_ancestor}")" = "${ancestor_mode}"
  test "$(cat "${diag_ancestor}/httpd.conf")" = "keep-httpd"
  export DEBIAN_SSH_HOME="${saved_diag_home}"

  mkdir -p "${saved_diag_cfg}"
  printf 'secret-token\n' >"${saved_diag_cfg}/FRP_AUTH_TOKEN"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${saved_diag_cfg}"
  if start_health; then
    echo "error: diagnostic directory equal to persisted config was accepted" >&2
    exit 1
  fi
  test "$(cat "${saved_diag_cfg}/FRP_AUTH_TOKEN")" = "secret-token"
  cfg_ancestor="${WORKDIR}/cfg-ancestor"
  mkdir -p "${cfg_ancestor}/config"
  printf 'secret-token\n' >"${cfg_ancestor}/config/FRP_AUTH_TOKEN"
  chmod 755 "${cfg_ancestor}"
  cfg_mode="$(stat -c %a "${cfg_ancestor}")"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${cfg_ancestor}/config"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${cfg_ancestor}"
  if start_health; then
    echo "error: diagnostic directory containing persisted config was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${cfg_ancestor}")" = "${cfg_mode}"
  test "$(cat "${cfg_ancestor}/config/FRP_AUTH_TOKEN")" = "secret-token"

  mkdir -p "${DEBIAN_FRP_STATE_DIR}"
  printf 'frp-token\n' >"${DEBIAN_FRP_STATE_DIR}/server_token"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${saved_diag_cfg}"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${DEBIAN_FRP_STATE_DIR}"
  if start_health; then
    echo "error: diagnostic directory equal to FRP state was accepted" >&2
    exit 1
  fi
  test "$(cat "${DEBIAN_FRP_STATE_DIR}/server_token")" = "frp-token"

  persist_dir="${WORKDIR}/persist-diag"
  mkdir -p "${persist_dir}"
  printf 'durable\n' >"${persist_dir}/canary"
  chmod 755 "${persist_dir}"
  persist_mode="$(stat -c %a "${persist_dir}")"
  export DEBIAN_SSH_PERSISTENCE_PATH="${persist_dir}"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${persist_dir}"
  if start_health; then
    echo "error: diagnostic directory equal to the persistence path was accepted" >&2
    exit 1
  fi
  test "$(cat "${persist_dir}/canary")" = "durable"
  test "$(stat -c %a "${persist_dir}")" = "${persist_mode}"
  export DEBIAN_SSH_PERSISTENCE_PATH="${saved_diag_persist}"
  export DEBIAN_SSH_LOCAL_DIAG_DIR="${saved_diag}"

  # The old default httpd config lived in the parent of persisted config.
  # Locking that parent down must be refused before chmod.
  old_parent="${WORKDIR}/old-httpd-parent"
  mkdir -p "${old_parent}/config"
  printf 'keep\n' >"${old_parent}/config/FRP_AUTH_TOKEN"
  chmod 755 "${old_parent}"
  old_mode="$(stat -c %a "${old_parent}")"
  saved_httpd="${DEBIAN_SSH_PUBLIC_HTTPD_CONF}"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${old_parent}/config"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${old_parent}/public.httpd.conf"
  if start_health; then
    echo "error: httpd config directory containing persisted config was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${old_parent}")" = "${old_mode}"
  test "$(cat "${old_parent}/config/FRP_AUTH_TOKEN")" = "keep"
  export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${saved_diag_cfg}"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${saved_httpd}"

  # A conf path inside a CAP config directory must not chmod that directory
  # or truncate the credential file.
  cap_dir="${WORKDIR}/cap-config"
  mkdir -p "${cap_dir}"
  printf 'live-token\n' >"${cap_dir}/FRP_AUTH_TOKEN"
  printf 'live-key\n' >"${cap_dir}/DEBIAN_SSH_AUTHORIZED_KEYS"
  chmod 755 "${cap_dir}"
  cap_mode="$(stat -c %a "${cap_dir}")"
  saved_caps="${DEBIAN_SSH_CAP_CONFIG_DIRS}"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${cap_dir}"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${cap_dir}/FRP_AUTH_TOKEN"
  if start_health; then
    echo "error: httpd config inside a CAP config directory was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${cap_dir}")" = "${cap_mode}"
  test "$(cat "${cap_dir}/FRP_AUTH_TOKEN")" = "live-token"
  test "$(cat "${cap_dir}/DEBIAN_SSH_AUTHORIZED_KEYS")" = "live-key"
  cap_parent="${WORKDIR}/cap-parent"
  mkdir -p "${cap_parent}/config"
  printf 'live-token\n' >"${cap_parent}/config/FRP_AUTH_TOKEN"
  chmod 755 "${cap_parent}"
  cap_parent_mode="$(stat -c %a "${cap_parent}")"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${cap_parent}/config"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${cap_parent}/public.httpd.conf"
  if start_health; then
    echo "error: httpd config directory containing a CAP config directory was accepted" >&2
    exit 1
  fi
  test "$(stat -c %a "${cap_parent}")" = "${cap_parent_mode}"
  test "$(cat "${cap_parent}/config/FRP_AUTH_TOKEN")" = "live-token"
  export DEBIAN_SSH_CAP_CONFIG_DIRS="${saved_caps}"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${saved_httpd}"

  # A conf file in a safe directory can still be a symlink into durable
  # state. : > would truncate the target. Refuse before that.
  link_dir="${WORKDIR}/httpd-link-dir"
  mkdir -p "${link_dir}" "${saved_diag_cfg}" "${DEBIAN_SSH_HOME}/.ssh" "${DEBIAN_FRP_STATE_DIR}"
  printf 'secret-token\n' >"${saved_diag_cfg}/FRP_AUTH_TOKEN"
  printf 'hostkey\n' >"${DEBIAN_SSH_HOME}/.ssh/dropbear_ed25519_host_key"
  printf 'frp-token\n' >"${DEBIAN_FRP_STATE_DIR}/server_token"
  ln -sfn "${saved_diag_cfg}/FRP_AUTH_TOKEN" "${link_dir}/persist.httpd.conf"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${link_dir}/persist.httpd.conf"
  if start_health; then
    echo "error: httpd config symlink into persisted config was accepted" >&2
    exit 1
  fi
  test "$(cat "${saved_diag_cfg}/FRP_AUTH_TOKEN")" = "secret-token"
  ln -sfn "${DEBIAN_SSH_HOME}/.ssh/dropbear_ed25519_host_key" "${link_dir}/host.httpd.conf"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${link_dir}/host.httpd.conf"
  if start_health; then
    echo "error: httpd config symlink to the host key was accepted" >&2
    exit 1
  fi
  test "$(cat "${DEBIAN_SSH_HOME}/.ssh/dropbear_ed25519_host_key")" = "hostkey"
  ln -sfn "${DEBIAN_FRP_STATE_DIR}/server_token" "${link_dir}/frp.httpd.conf"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${link_dir}/frp.httpd.conf"
  if start_health; then
    echo "error: httpd config symlink into FRP state was accepted" >&2
    exit 1
  fi
  test "$(cat "${DEBIAN_FRP_STATE_DIR}/server_token")" = "frp-token"
  export DEBIAN_SSH_PUBLIC_HTTPD_CONF="${saved_httpd}"

  cgi_target="${WORKDIR}/customer-cgi-target"
  mkdir -p "${cgi_target}"
  printf 'keep\n' >"${cgi_target}/monitor.cgi"
  ln -s "${cgi_target}" "${WORKDIR}/health-symlink"
  scrub_former_health_diagnostics "${WORKDIR}/health-symlink"
  test -L "${WORKDIR}/health-symlink"
  test "$(cat "${cgi_target}/monitor.cgi")" = "keep"

  mkdir -p "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}"
  HEALTH_PID="$$"
  SSHD_PID=""
  FRPC_PID=""
  write_debug_snapshot
  grep -Fq "health_pid=$$" "${DEBIAN_SSH_DEBUG_FILE}"
  if (
    export DEBIAN_SSH_WRAPPED=1
    fail "config did not arrive"
  ); then
    echo "error: wrapped diagnostic failure returned success" >&2
    exit 1
  fi
  test "$(cat "${DEBIAN_SSH_STARTUP_ERROR_FILE}")" = "config did not arrive"
  # Leftovers from the previous image, including a CGI config, must not survive bind.
  printf 'OLD-DEBUG\n' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/debug.txt"
  printf 'OLD-STARTUP\n' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/startup-error.txt"
  printf '%s\n' '#!/bin/sh' 'echo Content-type: text/plain' 'echo' 'echo CGI-RAN' 'id' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/leak.cgi"
  chmod 755 "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/leak.cgi"
  printf '%s\n' '*.cgi:/bin/sh' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/httpd.conf"
  mkdir -p "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/cgi-bin" "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub"
  printf '%s\n' '#!/bin/sh' 'echo Content-type: text/plain' 'echo' 'echo CGI-BIN-RAN' 'id' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/cgi-bin/x"
  chmod 755 "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/cgi-bin/x"
  printf '%s\n' '*.cgi:/bin/sh' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub/httpd.conf"
  printf '%s\n' '#!/bin/sh' 'echo Content-type: text/plain' 'echo' 'echo SUBCGI-RAN' 'id' >"${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub/y.cgi"
  chmod 755 "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub/y.cgi"
  mkdir -p "${DEBIAN_SSH_HOME}/health"
  printf 'OLD-HOME-DEBUG\n' >"${DEBIAN_SSH_HOME}/health/debug.txt"
  printf '#!/bin/sh\necho customer\n' >"${DEBIAN_SSH_HOME}/health/monitor.cgi"
  printf 'customer-httpd\n' >"${DEBIAN_SSH_HOME}/health/httpd.conf"

  start_health
  test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/debug.txt"
  test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/startup-error.txt"
  test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/leak.cgi"
  test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/httpd.conf"
  test ! -e "${DEBIAN_SSH_HOME}/health/debug.txt"
  test -f "${DEBIAN_SSH_HOME}/health/monitor.cgi"
  test "$(cat "${DEBIAN_SSH_HOME}/health/httpd.conf")" = "customer-httpd"
  test ! -d "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/cgi-bin"
  test ! -e "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/sub/y.cgi"
  publish_ready
  test "$(cat "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/healthz")" = "ok"
  test "$(cat "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/ssh.txt")" = "ssh -p 22001 user@relay.enclava.me"
  test "$(cat "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}/frp-url.txt")" = "tcp://relay.enclava.me:22001"
  published_names="$(cd "${DEBIAN_SSH_PUBLIC_HEALTH_DIR}" && find . -mindepth 1 -print | sed 's|^\./||' | sort | tr '\n' ' ')"
  test "${published_names}" = "frp-url.txt healthz ssh.txt "
  python3 - "${public_port}" "${local_port}" <<'PY'
import sys
import time
import urllib.error
import urllib.request

public, local = sys.argv[1], sys.argv[2]

def get(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except Exception as exc:
        return None, str(exc).encode()

def wait_ok(url, needle):
    last = None
    for _ in range(50):
        status, body = get(url)
        last = (status, body)
        if status == 200 and needle in body:
            return body
        time.sleep(0.05)
    raise SystemExit(f"timeout waiting for {url}: {last!r}")

wait_ok(f"http://127.0.0.1:{public}/healthz", b"ok\n")
status, body = get(f"http://127.0.0.1:{public}/ssh.txt")
if status != 200 or b"ssh -p 22001" not in body:
    raise SystemExit(f"public ssh.txt missing: {status} {body!r}")
status, body = get(f"http://127.0.0.1:{public}/frp-url.txt")
if status != 200 or b"tcp://relay.enclava.me:22001" not in body:
    raise SystemExit(f"public frp-url.txt missing: {status} {body!r}")
for path in ("/debug.txt", "/startup-error.txt", "/leak.cgi", "/cgi-bin/x", "/sub/y.cgi", "/ssh.txt.tmp", "/frp-url.txt.tmp", "/healthz.tmp"):
    status, body = get(f"http://127.0.0.1:{public}{path}")
    if status != 404 or b"OLD-DEBUG" in body or b"OLD-STARTUP" in body or b"uid=" in body or b"health_pid" in body:
        raise SystemExit(f"public port published {path}: {status} {body!r}")
wait_ok(f"http://127.0.0.1:{local}/debug.txt", b"health_pid")
status, body = get(f"http://127.0.0.1:{local}/startup-error.txt")
if status != 200 or body != b"config did not arrive\n":
    raise SystemExit(f"loopback startup-error missing: {status} {body!r}")
PY

  local_hex="$(printf '%04X' "${local_port}")"
  awk -v port=":${local_hex}" '$2 ~ port "$" { print $2 }' /proc/net/tcp >"${WORKDIR}/local-binds.txt"
  grep -qx "0100007F:${local_hex}" "${WORKDIR}/local-binds.txt"
  if grep -qx "00000000:${local_hex}" "${WORKDIR}/local-binds.txt"; then
    echo "error: diagnostic listener is bound on 0.0.0.0" >&2
    exit 1
  fi
  if [[ -r /proc/net/tcp6 ]]; then
    awk -v port=":${local_hex}" '$2 ~ port "$" { print $2 }' /proc/net/tcp6 >"${WORKDIR}/local-binds6.txt"
    if grep -q . "${WORKDIR}/local-binds6.txt"; then
      echo "error: diagnostic listener has an IPv6 socket" >&2
      exit 1
    fi
  fi
  public_hex="$(printf '%04X' "${public_port}")"
  awk -v port=":${public_hex}" '$2 ~ port "$" { print $2 }' /proc/net/tcp >"${WORKDIR}/public-binds.txt"
  grep -qx "00000000:${public_hex}" "${WORKDIR}/public-binds.txt"
)

echo "Debian SSH FRP entrypoint tests passed"
