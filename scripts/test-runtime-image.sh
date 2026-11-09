#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-debian-ssh-frp-template:ci}"

fail() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

need ssh-keygen

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
  else
    fail "docker is unavailable"
  fi
fi

WORKDIR="$(mktemp -d -t debian-ssh-frp-runtime-test.XXXXXX)"
DURABLE_VOLUME=""
BOOTSTRAP_VOLUME=""
RECOVERY_VOLUME=""
CID=""

cleanup() {
  if [[ -n "${CID}" ]]; then
    "${DOCKER[@]}" rm -f "${CID}" >/dev/null 2>&1 || true
  fi
  for volume in "${DURABLE_VOLUME}" "${BOOTSTRAP_VOLUME}" "${RECOVERY_VOLUME}"; do
    if [[ -n "${volume}" ]]; then
      "${DOCKER[@]}" volume rm -f "${volume}" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C debian-ssh-frp-runtime-test -f "${WORKDIR}/id_ed25519"
PUBLIC_KEY="$(cat "${WORKDIR}/id_ed25519.pub")"

mkdir -p "${WORKDIR}/fake-bin"
cat >"${WORKDIR}/fake-bin/frpc" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = "-c" ] || exit 64
[ -r "${2:-}" ] || exit 65
echo "fake frpc started"
while :; do
  sleep 60
done
EOF
chmod 0755 "${WORKDIR}/fake-bin/frpc"
cat >"${WORKDIR}/fake-bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *telnet://*) printf '%s' 'SSH-2.0-runtime-test' ;;
  *) printf '%s\n' '{"tcp":[{"name":"runtime-shell","status":"running"}]}' ;;
esac
EOF
chmod 0755 "${WORKDIR}/fake-bin/curl"

DURABLE_VOLUME="$("${DOCKER[@]}" volume create "debian-ssh-frp-runtime-durable-$RANDOM-$RANDOM")"
BOOTSTRAP_VOLUME="$("${DOCKER[@]}" volume create "debian-ssh-frp-runtime-bootstrap-$RANDOM-$RANDOM")"

"${DOCKER[@]}" run --rm \
  -v "${BOOTSTRAP_VOLUME}:/state" \
  -v "${DURABLE_VOLUME}:/state/app-data" \
  --user 0:0 \
  --entrypoint /bin/sh \
  -e PUBLIC_KEY="${PUBLIC_KEY}" \
  "${IMAGE}" \
  -c '
    set -eu
    customer_dir=/state/app-data/.enclava/config
    managed_dir=/state/.enclava/config
    mkdir -p "$customer_dir" "$managed_dir"
    touch /state/app-data/.enclava/luks-ready
    touch /state/.enclava/luks-ready
    printf "%s\n" relay.enclava.me >"$managed_dir/FRP_SERVER_ADDR"
    printf "%s\n" 20000 >"$managed_dir/FRP_SERVER_PORT"
    printf "%s\n" bootstrap-token-for-runtime-test >"$managed_dir/FRP_AUTH_TOKEN"
    printf "%s\n" runtime-shell >"$managed_dir/FRP_PROXY_NAME"
    printf "%s\n" tcp >"$managed_dir/FRP_PROXY_TYPE"
    printf "%s\n" 22002 >"$managed_dir/FRP_REMOTE_PORT"
    printf "%s\n" 127.0.0.1 >"$managed_dir/FRP_LOCAL_ADDR"
    printf "%s\n" 2222 >"$managed_dir/FRP_LOCAL_PORT"
    printf "%s\n" runtime-credential >"$managed_dir/FRP_TUNNEL_CREDENTIAL_ID"
    printf "%s\n" runtime-secret >"$managed_dir/FRP_TUNNEL_SECRET"
    printf "%s\n" relay.enclava.me >"$managed_dir/FRP_PUBLIC_HOST"
    printf "%s\n" "$PUBLIC_KEY" >"$customer_dir/DEBIAN_SSH_AUTHORIZED_KEYS"
    chown -R 0:0 /state/app-data
    chown -R 0:0 /state/.enclava
    chmod 0750 /state/app-data/.enclava /state/app-data/.enclava/config
    chmod 0640 /state/app-data/.enclava/luks-ready "$customer_dir"/*
    chmod 0700 /state/.enclava /state/.enclava/config
    chmod 0600 /state/.enclava/luks-ready "$managed_dir"/*
  '

CID="$("${DOCKER[@]}" run -d \
  --read-only \
  -v "${BOOTSTRAP_VOLUME}:/state:rw" \
  -v "${DURABLE_VOLUME}:/state/app-data:rw" \
  -v "${WORKDIR}/fake-bin:/test-bin:ro" \
  -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e DEBIAN_SSH_RESTART_WRAPPER=1 \
  "${IMAGE}")"

for _ in {1..60}; do
  if ! "${DOCKER[@]}" inspect -f '{{.State.Running}}' "${CID}" 2>/dev/null | grep -qx true; then
    "${DOCKER[@]}" logs "${CID}" >&2 || true
    fail "container exited before runtime checks passed"
  fi

  if "${DOCKER[@]}" exec "${CID}" /bin/sh -c '
      test -L /home/user &&
      test "$(readlink /home/user)" = "/state/app-data/home/user" &&
      grep -Fq "Your home folder (/home/user) is persistent and backed by encrypted /state/app-data." /etc/motd &&
      ! grep -Fq "Persistent data lives in /state." /etc/motd &&
      grep -Fq "/home/user is persistent and backed by /state/app-data." /home/user/.profile &&
      ! grep -Fq "Welcome to Enclava Debian SSH." /home/user/.profile &&
      test -d /home/user/health &&
      test -w /home/user/health &&
      command -v sudo &&
      id -nG user | grep -qw sudo &&
      test -f /etc/sudoers.d/user-nopasswd &&
      grep -Fxq "user ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/user-nopasswd &&
      test -f /home/user/.ssh/authorized_keys &&
      grep -q "debian-ssh-frp-runtime-test" /home/user/.ssh/authorized_keys &&
      test -f /state/app-data/.enclava/frp/frpc.toml &&
      grep -q "auth.additionalScopes" /state/app-data/.enclava/frp/frpc.toml &&
      test -f /state/app-data/.enclava/frp/admin-curl.conf &&
      test "$(stat -c "%a" /state/app-data/.enclava/frp/admin-curl.conf)" = 600 &&
      test ! -e /home/user/.config/frp/frpc.toml &&
      grep -q "reason=config_ready" /home/user/health/debug.txt &&
      grep -q "dir\\[2\\].stat=type=directory mode=700 uid=0 gid=0" /home/user/health/debug.txt &&
      test -f /home/user/health/healthz &&
      test -f /home/user/health/ssh.txt &&
      test -f /home/user/health/frp-url.txt &&
      test -f /state/app-data/.enclava/frp/frpc.log &&
      grep -q "fake frpc started" /state/app-data/.enclava/frp/frpc.log &&
      test -f /state/app-data/.enclava/frp/ready-seen &&
      test ! -e /tmp/debian-ssh-frp.log &&
      test ! -e /tmp/debian-ssh-frp-ready-seen &&
      awk '"'"'$2 ~ /:1F90$/ && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }'"'"' /proc/net/tcp /proc/net/tcp6
    ' >/dev/null 2>&1; then
    break
  fi

  sleep 1
done

"${DOCKER[@]}" exec "${CID}" /bin/sh -c '
  test -L /home/user &&
  test "$(readlink /home/user)" = "/state/app-data/home/user" &&
  grep -Fq "Your home folder (/home/user) is persistent and backed by encrypted /state/app-data." /etc/motd &&
  ! grep -Fq "Persistent data lives in /state." /etc/motd &&
  grep -Fq "/home/user is persistent and backed by /state/app-data." /home/user/.profile &&
  ! grep -Fq "Welcome to Enclava Debian SSH." /home/user/.profile &&
  test -d /home/user/health &&
  test -w /home/user/health &&
  command -v sudo &&
  id -nG user | grep -qw sudo &&
  test -f /etc/sudoers.d/user-nopasswd &&
  grep -Fxq "user ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/user-nopasswd &&
  test -f /home/user/.ssh/authorized_keys &&
  grep -q "debian-ssh-frp-runtime-test" /home/user/.ssh/authorized_keys &&
  test -f /state/app-data/.enclava/frp/frpc.toml &&
  grep -q "auth.additionalScopes" /state/app-data/.enclava/frp/frpc.toml &&
  test -f /state/app-data/.enclava/frp/admin-curl.conf &&
  test "$(stat -c "%a" /state/app-data/.enclava/frp/admin-curl.conf)" = 600 &&
  test ! -e /home/user/.config/frp/frpc.toml &&
  grep -q "reason=config_ready" /home/user/health/debug.txt &&
  grep -q "dir\\[2\\].stat=type=directory mode=700 uid=0 gid=0" /home/user/health/debug.txt &&
  test -f /home/user/health/healthz &&
  test -f /home/user/health/ssh.txt &&
  test -f /home/user/health/frp-url.txt &&
  test -f /state/app-data/.enclava/frp/frpc.log &&
  grep -q "fake frpc started" /state/app-data/.enclava/frp/frpc.log &&
  test -f /state/app-data/.enclava/frp/ready-seen &&
  test ! -e /tmp/debian-ssh-frp.log &&
  test ! -e /tmp/debian-ssh-frp-ready-seen &&
  awk '"'"'$2 ~ /:1F90$/ && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }'"'"' /proc/net/tcp /proc/net/tcp6
' >/dev/null || {
  "${DOCKER[@]}" logs "${CID}" >&2 || true
  fail "runtime image did not become locally healthy under --read-only"
}

"${DOCKER[@]}" exec "${CID}" /bin/sh -c '
  printf "%s\n" issue26-durable-state > /home/user/issue26-recovery-marker
  chown 10001:10001 /home/user/issue26-recovery-marker
  chmod 600 /home/user/issue26-recovery-marker
'

"${DOCKER[@]}" stop -t 10 "${CID}" >/dev/null
"${DOCKER[@]}" rm "${CID}" >/dev/null
CID=""
"${DOCKER[@]}" run --rm \
  -v "${DURABLE_VOLUME}:/state/app-data" \
  --user 0:0 \
  --entrypoint /bin/sh \
  "${IMAGE}" \
  -c '
    set -eu
    rm -rf /state/app-data/.enclava/config
    rm -f /state/app-data/.enclava/luks-ready
    rm -f /state/app-data/home/user/health/healthz
    rm -f /state/app-data/home/user/health/ssh.txt
    rm -f /state/app-data/home/user/health/frp-url.txt
    for key in FRP_SERVER_ADDR FRP_SERVER_PORT FRP_AUTH_TOKEN FRP_PROXY_NAME FRP_PROXY_TYPE FRP_REMOTE_PORT FRP_LOCAL_ADDR FRP_LOCAL_PORT FRP_TUNNEL_CREDENTIAL_ID FRP_TUNNEL_SECRET FRP_PUBLIC_HOST DEBIAN_SSH_AUTHORIZED_KEYS; do
      test -s "/state/app-data/.enclava/debian-ssh-frp/config/$key"
    done
  '

RECOVERY_VOLUME="$("${DOCKER[@]}" volume create "debian-ssh-frp-runtime-recovery-$RANDOM-$RANDOM")"

CID="$("${DOCKER[@]}" run -d \
  --read-only \
  -v "${RECOVERY_VOLUME}:/state:rw" \
  -v "${DURABLE_VOLUME}:/state/app-data:rw" \
  -v "${WORKDIR}/fake-bin:/test-bin:ro" \
  -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e DEBIAN_SSH_RESTART_WRAPPER=1 \
  -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=5 \
  "${IMAGE}")"

for _ in {1..30}; do
  if ! "${DOCKER[@]}" inspect -f '{{.State.Running}}' "${CID}" 2>/dev/null | grep -qx true; then
    "${DOCKER[@]}" logs "${CID}" >&2 || true
    fail "persisted-config restart exited before runtime checks passed"
  fi
  if "${DOCKER[@]}" exec "${CID}" /bin/sh -c '
      test ! -e /state/app-data/.enclava/config &&
      test ! -e /state/.enclava/config &&
      test "$(cat /home/user/issue26-recovery-marker)" = issue26-durable-state &&
      grep -q "reason=config_ready" /home/user/health/debug.txt &&
      grep -q "key=FRP_AUTH_TOKEN env=present" /home/user/health/debug.txt &&
      grep -q "complete=yes" /home/user/health/debug.txt &&
      test -f /home/user/health/healthz &&
      test -f /home/user/health/ssh.txt &&
      test -f /home/user/health/frp-url.txt &&
      grep -q "fake frpc started" /state/app-data/.enclava/frp/frpc.log
    ' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

"${DOCKER[@]}" exec "${CID}" /bin/sh -c '
  test ! -e /state/app-data/.enclava/config &&
  test ! -e /state/.enclava/config &&
  test "$(cat /home/user/issue26-recovery-marker)" = issue26-durable-state &&
  grep -q "reason=config_ready" /home/user/health/debug.txt &&
  grep -q "key=FRP_AUTH_TOKEN env=present" /home/user/health/debug.txt &&
  grep -q "complete=yes" /home/user/health/debug.txt &&
  test -f /home/user/health/healthz &&
  test -f /home/user/health/ssh.txt &&
  test -f /home/user/health/frp-url.txt &&
  grep -q "fake frpc started" /state/app-data/.enclava/frp/frpc.log
' >/dev/null || {
  "${DOCKER[@]}" logs "${CID}" >&2 || true
  fail "runtime image did not restart from encrypted persisted config"
}

"${DOCKER[@]}" exec --user 10001:10001 "${CID}" /bin/sh -c '
  sudo -n true &&
  test ! -r /state/.enclava/config/FRP_AUTH_TOKEN &&
  test ! -r /state/.enclava/config/FRP_TUNNEL_SECRET &&
  test ! -r /state/app-data/.enclava/frp/frpc.toml &&
  test ! -r /state/app-data/.enclava/frp/server_token &&
  test ! -r /state/app-data/.enclava/frp/admin-curl.conf &&
  test ! -r /state/app-data/.enclava/debian-ssh-frp/config/FRP_AUTH_TOKEN &&
  test ! -r /state/app-data/.enclava/debian-ssh-frp/config/FRP_TUNNEL_SECRET
' >/dev/null || {
  "${DOCKER[@]}" exec "${CID}" /bin/sh -c 'ls -ldn /state/.enclava /state/.enclava/config /state/app-data/.enclava /state/app-data/.enclava/frp /state/app-data/.enclava/debian-ssh-frp/config 2>/dev/null || true' >&2 || true
  fail "tenant SSH user can read platform-managed FRP credentials"
}

# Corrupted persistent SSH keys (e.g. from an interrupted boot) must be
# regenerated on the next boot instead of crash-looping under a green pod.
"${DOCKER[@]}" exec "${CID}" /bin/sh -c '
  printf "%s\n" corrupt-readiness-key-bytes >/state/app-data/home/user/.ssh/ssh_ready_ed25519_key
  printf "%s\n" corrupt-host-key-bytes >/state/app-data/home/user/.ssh/dropbear_ed25519_host_key
  rm -f /state/app-data/home/user/health/healthz
  rm -f /state/app-data/home/user/health/ssh.txt
  rm -f /state/app-data/home/user/health/frp-url.txt
'

"${DOCKER[@]}" stop -t 10 "${CID}" >/dev/null
"${DOCKER[@]}" rm "${CID}" >/dev/null
CID=""

CID="$("${DOCKER[@]}" run -d \
  --read-only \
  -v "${RECOVERY_VOLUME}:/state:rw" \
  -v "${DURABLE_VOLUME}:/state/app-data:rw" \
  -v "${WORKDIR}/fake-bin:/test-bin:ro" \
  -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e DEBIAN_SSH_RESTART_WRAPPER=1 \
  -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=5 \
  "${IMAGE}")"

for _ in {1..30}; do
  if ! "${DOCKER[@]}" inspect -f '{{.State.Running}}' "${CID}" 2>/dev/null | grep -qx true; then
    "${DOCKER[@]}" logs "${CID}" >&2 || true
    fail "corrupt-key restart exited before runtime checks passed"
  fi
  if "${DOCKER[@]}" exec "${CID}" /bin/sh -c '
      test "$(cat /home/user/.ssh/ssh_ready_ed25519_key.corrupt)" = corrupt-readiness-key-bytes &&
      test "$(cat /home/user/.ssh/dropbear_ed25519_host_key.corrupt)" = corrupt-host-key-bytes &&
      ssh-keygen -y -f /home/user/.ssh/ssh_ready_ed25519_key >/dev/null 2>&1 &&
      dropbearkey -y -f /home/user/.ssh/dropbear_ed25519_host_key >/dev/null 2>&1 &&
      test -s /home/user/.ssh/ssh_ready_ed25519_key.pub &&
      test -f /home/user/health/healthz
    ' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

"${DOCKER[@]}" exec "${CID}" /bin/sh -c '
  test "$(cat /home/user/.ssh/ssh_ready_ed25519_key.corrupt)" = corrupt-readiness-key-bytes &&
  test "$(cat /home/user/.ssh/dropbear_ed25519_host_key.corrupt)" = corrupt-host-key-bytes &&
  ssh-keygen -y -f /home/user/.ssh/ssh_ready_ed25519_key >/dev/null 2>&1 &&
  dropbearkey -y -f /home/user/.ssh/dropbear_ed25519_host_key >/dev/null 2>&1 &&
  test -s /home/user/.ssh/ssh_ready_ed25519_key.pub &&
  test -f /home/user/health/healthz
' >/dev/null || {
  "${DOCKER[@]}" logs "${CID}" >&2 || true
  fail "runtime image did not regenerate corrupted persistent SSH keys"
}

logs="$("${DOCKER[@]}" logs "${CID}" 2>&1 || true)"
case "${logs}" in
  *"Read-only file system"*|*"home setup failed"*|*"can't change directory"*)
    printf '%s\n' "${logs}" >&2
    fail "runtime image attempted to write to read-only root filesystem"
    ;;
esac

echo "Debian SSH FRP runtime image tests passed"
