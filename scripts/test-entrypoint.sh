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
export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_HOME}/health/debug.txt"
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

publish_ready
test "$(cat "${DEBIAN_SSH_HOME}/health/ssh.txt")" = "ssh -p 22001 user@relay.enclava.me"
test "$(cat "${DEBIAN_SSH_HOME}/health/frp-url.txt")" = "tcp://relay.enclava.me:22001"
test "$(cat "${DEBIAN_SSH_HOME}/health/healthz")" = "ok"

if (
  export DEBIAN_SSH_WRAPPED=1
  export DEBIAN_SSH_HOME="${WORKDIR}/wrapped-home"
  fail "wrapped failure test"
); then
  echo "error: wrapped failure did not exit non-zero" >&2
  exit 1
fi
test "$(cat "${WORKDIR}/wrapped-home/health/startup-error.txt")" = "wrapped failure test"

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

echo "Debian SSH FRP entrypoint tests passed"
