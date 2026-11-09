#!/bin/sh
set -u

: "${DEBIAN_SSH_USER:=user}"
: "${DEBIAN_SSH_UID:=10001}"
: "${DEBIAN_SSH_GID:=10001}"
: "${DEBIAN_SSH_HOME:=/home/user}"
: "${DEBIAN_SSH_PORT:=2222}"
: "${DEBIAN_HEALTH_PORT:=8080}"
: "${DEBIAN_SSH_RESTART_WRAPPER:=0}"
: "${DEBIAN_SSH_WRAPPED:=0}"
: "${DEBIAN_SSH_RESTART_DELAY_SECONDS:=2}"
: "${DEBIAN_SSH_MAX_RESTARTS:=5}"
: "${DEBIAN_SSH_CONFIG_WAIT_SECONDS:=300}"
: "${DEBIAN_SSH_PERSISTENCE_PATH:=/state/app-data}"
: "${DEBIAN_SSH_CAP_CONFIG_DIRS:=/state/app-data/.enclava/config /state/.enclava/config /home/user/.enclava/config}"
: "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:=/state/app-data/.enclava/debian-ssh-frp/config}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES:=32768}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS:=10}"
: "${DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS:=ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256}"
: "${DEBIAN_SSH_HOST_KEY:=$DEBIAN_SSH_HOME/.ssh/dropbear_ed25519_host_key}"
: "${DEBIAN_SSH_READY_KEY:=$DEBIAN_SSH_HOME/.ssh/ssh_ready_ed25519_key}"
: "${DEBIAN_SSH_PID_FILE:=$DEBIAN_SSH_HOME/.ssh/ssh_daemon.pid}"
: "${DEBIAN_SSH_DEBUG_FILE:=$DEBIAN_SSH_HOME/health/debug.txt}"
: "${DEBIAN_FRP_STATE_DIR:=/state/app-data/.enclava/frp}"
: "${DEBIAN_FRP_CONFIG_FILE:=$DEBIAN_FRP_STATE_DIR/frpc.toml}"
: "${DEBIAN_FRP_TOKEN_FILE:=$DEBIAN_FRP_STATE_DIR/server_token}"
: "${DEBIAN_FRP_LOG_FILE:=$DEBIAN_FRP_STATE_DIR/frpc.log}"
: "${DEBIAN_SSH_READY_MARKER:=$DEBIAN_FRP_STATE_DIR/ready-seen}"
: "${DEBIAN_FRP_LOG_LINES:=80}"
: "${DEBIAN_FRP_UNREADY_EXIT_SECONDS:=120}"
: "${DEBIAN_FRP_ADMIN_PORT:=7400}"
: "${DEBIAN_FRP_ADMIN_CURL_CONFIG:=$DEBIAN_FRP_STATE_DIR/admin-curl.conf}"
: "${ENCLAVA_REQUIRED_CONFIG_KEYS:=FRP_SERVER_ADDR,FRP_SERVER_PORT,FRP_AUTH_TOKEN,FRP_PROXY_NAME,FRP_PROXY_TYPE,FRP_REMOTE_PORT,FRP_LOCAL_ADDR,FRP_LOCAL_PORT,FRP_TUNNEL_CREDENTIAL_ID,FRP_TUNNEL_SECRET,FRP_PUBLIC_HOST,DEBIAN_SSH_AUTHORIZED_KEYS}"

RESTART_WRAPPER_CHILD_PID=""

sync_persistent_state() {
    [ -n "$DEBIAN_SSH_PERSISTENCE_PATH" ] || return 1
    sync -f "$DEBIAN_SSH_PERSISTENCE_PATH" 2>/dev/null || sync 2>/dev/null
}

stop_restart_wrapper() {
    trap - INT TERM
    child="${RESTART_WRAPPER_CHILD_PID:-}"
    if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    sync_persistent_state || true
    exit 0
}

start_wrapped_child() {
    DEBIAN_SSH_WRAPPED=1 DEBIAN_SSH_RESTART_WRAPPER=0 "$0" "$@"
}

validate_uint() {
    key="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*)
            echo "$key must be an integer" >&2
            return 1
            ;;
    esac
}

run_restart_wrapper() {
    validate_uint DEBIAN_SSH_MAX_RESTARTS "$DEBIAN_SSH_MAX_RESTARTS" || exit 1
    trap stop_restart_wrapper INT TERM
    restarts="0"
    while :; do
        # Scope readiness to this child attempt: a stale marker from an
        # earlier run must not grant budget immunity, so a workload whose
        # config channel dies after a healthy boot still exhausts the
        # budget and surfaces as a crash.
        rm -f "$DEBIAN_SSH_READY_MARKER" 2>/dev/null || true
        start_wrapped_child "$@" &
        child="$!"
        RESTART_WRAPPER_CHILD_PID="$child"
        status="0"
        wait "$child" || status="$?"
        RESTART_WRAPPER_CHILD_PID=""
        if [ -e "$DEBIAN_SSH_READY_MARKER" ]; then
            # This child reached ready during its own run (the marker is
            # written on readiness and was cleared at its start): a
            # recovering workload keeps its restart budget, while persistent
            # failures - including slow ones like config timeouts - count.
            restarts="0"
        else
            restarts="$((restarts + 1))"
        fi
        if [ "$restarts" -ge "$DEBIAN_SSH_MAX_RESTARTS" ]; then
            # Consecutive startup failures that survive this many restarts
            # are terminal; exiting surfaces the failure as a container
            # crash instead of an all-green pod with a dead workload.
            echo "debian SSH FRP entrypoint failed ${restarts} consecutive times; giving up" >&2
            exit 1
        fi
        echo "debian SSH FRP entrypoint exited with status ${status}; restarting in ${DEBIAN_SSH_RESTART_DELAY_SECONDS}s" >&2
        sleep "$DEBIAN_SSH_RESTART_DELAY_SECONDS"
    done
}

if [ "$DEBIAN_SSH_RESTART_WRAPPER" = "1" ]; then
    run_restart_wrapper "$@"
fi

is_valid_env_key() {
    case "$1" in
        ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
            return 1
            ;;
    esac
}

running_as_root() {
    [ "$(id -u 2>/dev/null || printf 1)" = "0" ]
}

chown_if_root() {
    if running_as_root; then
        chown "$@" || return 1
    fi
}

prepare_secret_dir() {
    dir="$1"
    [ -n "$dir" ] || return 1
    if [ -L "$dir" ]; then
        rm -f "$dir" || return 1
    fi
    mkdir -p "$dir" || return 1
    [ ! -L "$dir" ] || return 1
    chown_if_root 0:0 "$dir" || return 1
    chmod 700 "$dir" || return 1
}

write_root_secret_file() {
    path="$1"
    value="$2"
    dir="${path%/*}"
    [ "$dir" != "$path" ] || dir="."
    prepare_secret_dir "$dir" || return 1
    tmp="${path}.tmp.$$"
    rm -f "$tmp" 2>/dev/null || true
    (umask 077 && printf '%s\n' "$value" >"$tmp") || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    chown_if_root 0:0 "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    chmod 600 "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    mv -f "$tmp" "$path" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
}

required_config_keys() {
    printf '%s' "$ENCLAVA_REQUIRED_CONFIG_KEYS" | tr ',' ' '
}

config_dir_ready() {
    dir="$1"
    [ -f "$dir/.ready" ] && return 0
    case "$dir" in
        */.enclava/config)
            [ -f "${dir%/config}/luks-ready" ] && return 0
            ;;
    esac
    return 1
}

debug_path_stat() {
    path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        stat -c 'type=%F mode=%a uid=%u gid=%g' "$path" 2>/dev/null || ls -ldn "$path" 2>/dev/null || true
    else
        printf 'missing'
    fi
}

write_config_wait_snapshot() {
    reason="$1"
    elapsed="${2:-}"
    [ -n "$DEBIAN_SSH_DEBUG_FILE" ] || return 0
    mkdir -p "${DEBIAN_SSH_DEBUG_FILE%/*}" 2>/dev/null || return 0
    tmp="${DEBIAN_SSH_DEBUG_FILE}.tmp.$$"
    {
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
        printf 'reason=%s\n' "$reason"
        printf 'config_wait_elapsed_seconds=%s\n' "$elapsed"
        printf 'config_wait_limit_seconds=%s\n' "$DEBIAN_SSH_CONFIG_WAIT_SECONDS"
        printf 'configured_config_dirs=%s\n' "$DEBIAN_SSH_CAP_CONFIG_DIRS"
        printf 'process_identity='
        id 2>/dev/null || true

        printf '\n[config-dirs]\n'
        index=0
        for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
            index=$((index + 1))
            printf 'dir[%s]=%s\n' "$index" "$dir"
            printf 'dir[%s].stat=' "$index"
            debug_path_stat "$dir"
            printf '\n'
            printf 'dir[%s].ready_file=' "$index"
            debug_path_stat "$dir/.ready"
            printf '\n'
            case "$dir" in
                */.enclava/config)
                    printf 'dir[%s].luks_ready=' "$index"
                    debug_path_stat "${dir%/config}/luks-ready"
                    printf '\n'
                    ;;
            esac
            if [ -d "$dir" ]; then
                if config_dir_ready "$dir"; then
                    printf 'dir[%s].ready=yes\n' "$index"
                else
                    printf 'dir[%s].ready=no\n' "$index"
                fi
            else
                printf 'dir[%s].ready=no\n' "$index"
            fi
        done

        printf '\n[persisted-config]\n'
        printf 'dir=%s\n' "$DEBIAN_SSH_PERSISTED_CONFIG_DIR"
        printf 'dir.stat='
        debug_path_stat "$DEBIAN_SSH_PERSISTED_CONFIG_DIR"
        printf '\ncomplete='
        if persisted_config_available; then printf 'yes'; else printf 'no'; fi
        printf '\n'

        printf '\n[required-config]\n'
        for key in $(required_config_keys); do
            if ! is_valid_env_key "$key"; then
                printf 'key=%s status=invalid-key\n' "$key"
                continue
            fi
            eval "value=\${$key:-}"
            if [ -n "$value" ]; then
                printf 'key=%s env=present\n' "$key"
                continue
            fi
            printf 'key=%s env=missing\n' "$key"
            index=0
            for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
                index=$((index + 1))
                path="$dir/$key"
                printf 'key=%s dir[%s].file=' "$key" "$index"
                debug_path_stat "$path"
                printf ' readable='
                if [ -r "$path" ]; then printf 'yes'; else printf 'no'; fi
                printf ' nonempty='
                if [ -s "$path" ]; then printf 'yes'; else printf 'no'; fi
                printf '\n'
            done
        done
    } >"$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        return 0
    }
    mv "$tmp" "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

ready_config_dirs() {
    for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
        if [ -d "$dir" ] && config_dir_ready "$dir"; then
            printf '%s\n' "$dir"
        fi
    done
}

config_file_for_key() {
    key="$1"
    for dir in $(ready_config_dirs); do
        [ -s "$dir/$key" ] || continue
        printf '%s\n' "$dir/$key"
        return 0
    done
    return 1
}

# The customer channel is authoritative once a CAP config-store dir — one
# following the <root>/.enclava/config naming convention — is marked ready,
# either by the .ready sentinel the attestation proxy writes after a config
# put or by the luks-ready marker CAP leaves next to the managed config dir.
# The signal is deliberately independent of DEBIAN_SSH_AUTHORIZED_KEYS
# itself: a customer who deletes or empties the key in a delivered dir must
# not see the persisted copy resurrect removed SSH access. Managed-only dirs
# that do not follow the .enclava/config convention hold FRP_* keys without
# proving customer delivery — pod replacement before CAP re-delivers the
# customer config must still fall back to the persisted copy.
customer_config_ready() {
    for dir in $(ready_config_dirs); do
        case "$dir" in
            */.enclava/config)
                return 0
                ;;
        esac
    done
    return 1
}

required_config_available() {
    for key in $(required_config_keys); do
        is_valid_env_key "$key" || return 1
        eval "value=\${$key:-}"
        [ -n "$value" ] && continue
        config_file_for_key "$key" >/dev/null || return 1
    done
}

wait_for_config() {
    elapsed=0
    while [ "$elapsed" -lt "$DEBIAN_SSH_CONFIG_WAIT_SECONDS" ]; do
        if required_config_available >/dev/null 2>&1; then
            write_config_wait_snapshot "config_ready" "$elapsed"
            return 0
        fi
        if load_persisted_config >/dev/null 2>&1 && required_config_available >/dev/null 2>&1; then
            write_config_wait_snapshot "config_ready" "$elapsed"
            return 0
        fi
        write_config_wait_snapshot "waiting_for_config" "$elapsed"
        sleep 1
        elapsed=$((elapsed + 1))
    done
    write_config_wait_snapshot "config_timeout" "$elapsed"
    echo "CAP config was not ready after ${DEBIAN_SSH_CONFIG_WAIT_SECONDS}s" >&2
    return 1
}

load_cap_config() {
    for dir in $(ready_config_dirs); do
        for path in "$dir"/*; do
            [ -f "$path" ] || continue
            key="${path##*/}"
            is_valid_env_key "$key" || continue
            eval "current=\${$key:-}"
            [ -n "$current" ] && continue
            value="$(cat "$path")" || return 1
            export "$key=$value"
        done
    done
    required_config_available
}

persist_config() {
    prepare_secret_dir "$DEBIAN_SSH_PERSISTED_CONFIG_DIR" 2>/dev/null || return 1
    for key in $(required_config_keys); do
        is_valid_env_key "$key" || return 1
        eval "value=\${$key:-}"
        [ -n "$value" ] || return 1
        write_root_secret_file "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/$key" "$value" || return 1
    done
    persisted_config_available || return 1
    sync_persistent_state
}

persisted_config_available() {
    [ -d "$DEBIAN_SSH_PERSISTED_CONFIG_DIR" ] || return 1
    for key in $(required_config_keys); do
        is_valid_env_key "$key" || return 1
        [ -s "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/$key" ] || return 1
    done
}

load_persisted_config() {
    persisted_config_available || return 1
    for key in $(required_config_keys); do
        is_valid_env_key "$key" || return 1
        eval "value=\${$key:-}"
        [ -n "$value" ] && continue
        # Live config is authoritative once it is visible: prefer its value
        # when the key is present (this can run before load_cap_config from
        # wait_for_config), and treat an absent key as deleted once the
        # customer channel is ready. The persisted copy is only a fallback
        # while the customer channel has not (re)appeared — pod replacement
        # before CAP re-delivers config, or a managed-only dir that is already
        # ready.
        path="$(config_file_for_key "$key" 2>/dev/null || true)"
        if [ -z "$path" ]; then
            customer_config_ready && return 1
            path="$DEBIAN_SSH_PERSISTED_CONFIG_DIR/$key"
            [ -s "$path" ] || return 1
        fi
        value="$(cat "$path")" || return 1
        [ -n "$value" ] || return 1
        export "$key=$value"
    done
}

require_nonempty_env() {
    key="$1"
    eval "value=\${$key:-}"
    [ -n "$value" ] || {
        echo "$key is required" >&2
        return 1
    }
}

validate_host() {
    key="$1"
    value="$2"
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' || {
        echo "$key must be a DNS host" >&2
        return 1
    }
}

validate_authorized_key_algorithm() {
    algorithm="$1"
    for allowed in $DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS; do
        [ "$algorithm" = "$allowed" ] && return 0
    done
    echo "unsupported SSH public key algorithm: ${algorithm}" >&2
    return 1
}

validate_authorized_key_line() {
    line="$1"
    key_file="$2"
    algorithm="${line%% *}"
    rest="${line#* }"
    key_body="${rest%% *}"
    [ "$algorithm" != "$line" ] || {
        echo "SSH public key is missing key material" >&2
        return 1
    }
    validate_authorized_key_algorithm "$algorithm" || return 1
    case "$key_body" in
        ''|*[!A-Za-z0-9+/=]*)
            echo "SSH public key has malformed base64" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$line" >"$key_file" || return 1
    ssh-keygen -l -f "$key_file" >/dev/null 2>&1 || {
        echo "SSH public key could not be parsed by ssh-keygen" >&2
        return 1
    }
}

write_authorized_keys() {
    validate_uint DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES" || return 1
    validate_uint DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS" || return 1
    input="${DEBIAN_SSH_AUTHORIZED_KEYS:-}"
    byte_count="$(printf '%s' "$input" | wc -c | tr -d ' ')"
    [ "$byte_count" -le "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES" ] || {
        echo "DEBIAN_SSH_AUTHORIZED_KEYS exceeds ${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES} bytes" >&2
        return 1
    }
    case "$input" in
        *"-----BEGIN "*|*"PRIVATE KEY"*)
            echo "DEBIAN_SSH_AUTHORIZED_KEYS must contain public keys, not private keys" >&2
            return 1
            ;;
    esac
    tmp="$DEBIAN_SSH_HOME/.ssh/authorized_keys.tmp.$$"
    key_tmp="$DEBIAN_SSH_HOME/.ssh/authorized_key_check.$$"
    : >"$tmp" || return 1
    count=0
    printf '%s\n' "$input" | while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        count=$((count + 1))
        [ "$count" -le "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS" ] || exit 1
        validate_authorized_key_line "$line" "$key_tmp" || exit 1
        grep -qxF "$line" "$tmp" 2>/dev/null || printf '%s\n' "$line" >>"$tmp" || exit 1
    done
    status="$?"
    rm -f "$key_tmp"
    [ "$status" -eq 0 ] || {
        rm -f "$tmp"
        return "$status"
    }
    [ -s "$tmp" ] || {
        echo "DEBIAN_SSH_AUTHORIZED_KEYS must include at least one valid public key" >&2
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chown_if_root "$DEBIAN_SSH_UID:$DEBIAN_SSH_GID" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$DEBIAN_SSH_HOME/.ssh/authorized_keys"
}

write_default_profile() {
    profile="$DEBIAN_SSH_HOME/.profile"
    tmp="${profile}.tmp.$$"
    rm -f "$tmp" 2>/dev/null || true
    if ! cat >"$tmp" <<'EOF'
# Enclava Debian SSH user profile.
# /home/user is persistent and backed by /state/app-data.
EOF
    then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 644 "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    chown_if_root "$DEBIAN_SSH_UID:$DEBIAN_SSH_GID" "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    mv "$tmp" "$profile" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
}

ensure_default_profile() {
    profile="$DEBIAN_SSH_HOME/.profile"
    legacy_tmp="${profile}.legacy.$$"

    if [ ! -f "$profile" ]; then
        write_default_profile
        return "$?"
    fi

    rm -f "$legacy_tmp" 2>/dev/null || true
    if ! cat >"$legacy_tmp" <<'EOF'
echo "Welcome to Enclava Debian SSH."
echo
echo "Persistent data lives in /state."
echo "The root filesystem is platform-managed and may show Kata implementation details."
EOF
    then
        rm -f "$legacy_tmp" 2>/dev/null || true
        return 1
    fi

    if cmp -s "$profile" "$legacy_tmp"; then
        rm -f "$legacy_tmp" 2>/dev/null || true
        write_default_profile
        return "$?"
    fi

    rm -f "$legacy_tmp" 2>/dev/null || true
    chmod 644 "$profile" || return 1
    chown_if_root "$DEBIAN_SSH_UID:$DEBIAN_SSH_GID" "$profile" || return 1
}

ensure_dropbear_host_key() {
    if [ -e "$DEBIAN_SSH_HOST_KEY" ] && ! dropbearkey -y -f "$DEBIAN_SSH_HOST_KEY" >/dev/null 2>&1; then
        # An unparseable persistent host key (e.g. corrupted by an
        # interrupted boot) is logged, kept aside for inspection, and
        # regenerated rather than treated as fatal. Clients pinned to the
        # old host key will see a host-key change. The first bad copy wins:
        # a later corruption (e.g. an interrupted regeneration) never
        # overwrites the preserved original.
        echo "persistent dropbear host key invalid; regenerating (previous copy kept at ${DEBIAN_SSH_HOST_KEY}.corrupt)" >&2
        if [ -s "${DEBIAN_SSH_HOST_KEY}.corrupt" ]; then
            rm -f "$DEBIAN_SSH_HOST_KEY"
        else
            mv -f "$DEBIAN_SSH_HOST_KEY" "${DEBIAN_SSH_HOST_KEY}.corrupt" 2>/dev/null || true
        fi
    fi
    if [ ! -s "$DEBIAN_SSH_HOST_KEY" ]; then
        # Absent on a normal first boot: generate quietly, no sidecar.
        dropbearkey -t ed25519 -f "$DEBIAN_SSH_HOST_KEY" >/dev/null 2>&1 || return 1
    fi
    chown_if_root 0:0 "$DEBIAN_SSH_HOST_KEY" || return 1
    chmod 600 "$DEBIAN_SSH_HOST_KEY" || return 1
}

prepare_home() {
    mkdir -p /state/app-data/home/user || return 1
    mkdir -p "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/health" "$DEBIAN_FRP_STATE_DIR" || return 1
    chown_if_root -R "$DEBIAN_SSH_UID:$DEBIAN_SSH_GID" "$DEBIAN_SSH_HOME/." || return 1
    chmod 700 "$DEBIAN_SSH_HOME" "$DEBIAN_SSH_HOME/.ssh" || return 1
    prepare_secret_dir "$DEBIAN_FRP_STATE_DIR" || return 1
    ensure_default_profile || return 1
    ensure_dropbear_host_key || return 1
}

prepare_ssh_ready_key() {
    if [ -e "$DEBIAN_SSH_READY_KEY" ] && ! ssh-keygen -y -f "$DEBIAN_SSH_READY_KEY" >/dev/null 2>&1; then
        # An unparseable persistent readiness key (e.g. corrupted by an
        # interrupted boot) is logged, kept aside for inspection, and
        # regenerated rather than treated as fatal: the key is a guest-local
        # readiness artifact, so regeneration is safe. The first bad copy
        # wins: a later corruption never overwrites the preserved original.
        echo "persistent readiness key invalid; regenerating (previous copy kept at ${DEBIAN_SSH_READY_KEY}.corrupt)" >&2
        if [ -s "${DEBIAN_SSH_READY_KEY}.corrupt" ]; then
            rm -f "$DEBIAN_SSH_READY_KEY"
        else
            mv -f "$DEBIAN_SSH_READY_KEY" "${DEBIAN_SSH_READY_KEY}.corrupt" 2>/dev/null || true
        fi
    fi
    if [ ! -s "$DEBIAN_SSH_READY_KEY" ]; then
        # Absent on a normal first boot: generate quietly, no sidecar.
        rm -f "$DEBIAN_SSH_READY_KEY.pub" 2>/dev/null || true
        ssh-keygen -q -t ed25519 -N '' -C 'debian-ssh-frp-readiness' -f "$DEBIAN_SSH_READY_KEY" || return 1
    fi
    chown_if_root 0:0 "$DEBIAN_SSH_READY_KEY" || return 1
    chmod 600 "$DEBIAN_SSH_READY_KEY" || return 1
    ssh-keygen -y -f "$DEBIAN_SSH_READY_KEY" >"$DEBIAN_SSH_READY_KEY.pub" || return 1
    chown_if_root 0:0 "$DEBIAN_SSH_READY_KEY.pub" || return 1
    chmod 644 "$DEBIAN_SSH_READY_KEY.pub" || return 1
    ready_pub="$(cat "$DEBIAN_SSH_READY_KEY.pub")" || return 1
    grep -qxF "$ready_pub" "$DEBIAN_SSH_HOME/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$ready_pub" >>"$DEBIAN_SSH_HOME/.ssh/authorized_keys"
    chmod 600 "$DEBIAN_SSH_HOME/.ssh/authorized_keys" || return 1
    chown_if_root "$DEBIAN_SSH_UID:$DEBIAN_SSH_GID" "$DEBIAN_SSH_HOME/.ssh/authorized_keys" || return 1
}

render_frpc_config() {
    validate_host FRP_SERVER_ADDR "$FRP_SERVER_ADDR" || return 1
    validate_host FRP_PUBLIC_HOST "$FRP_PUBLIC_HOST" || return 1
    validate_uint FRP_SERVER_PORT "$FRP_SERVER_PORT" || return 1
    validate_uint FRP_REMOTE_PORT "$FRP_REMOTE_PORT" || return 1
    validate_uint FRP_LOCAL_PORT "$FRP_LOCAL_PORT" || return 1
    validate_uint DEBIAN_FRP_ADMIN_PORT "$DEBIAN_FRP_ADMIN_PORT" || return 1
    write_root_secret_file "$DEBIAN_FRP_TOKEN_FILE" "$FRP_AUTH_TOKEN" || return 1
    write_root_secret_file "$DEBIAN_FRP_ADMIN_CURL_CONFIG" "user = \"enclava:${FRP_TUNNEL_SECRET}\"" || return 1
    config_dir="${DEBIAN_FRP_CONFIG_FILE%/*}"
    [ "$config_dir" != "$DEBIAN_FRP_CONFIG_FILE" ] || config_dir="."
    prepare_secret_dir "$config_dir" || return 1
    tmp="${DEBIAN_FRP_CONFIG_FILE}.tmp.$$"
    rm -f "$tmp" 2>/dev/null || true
    (umask 077 && cat >"$tmp" <<EOF
serverAddr = "${FRP_SERVER_ADDR}"
serverPort = ${FRP_SERVER_PORT}
transport.tls.enable = ${FRP_TLS_ENABLE:-true}
auth.method = "token"
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "${DEBIAN_FRP_TOKEN_FILE}"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
loginFailExit = false
webServer.addr = "127.0.0.1"
webServer.port = ${DEBIAN_FRP_ADMIN_PORT}
webServer.user = "enclava"
webServer.password = "${FRP_TUNNEL_SECRET}"
metadatas.enclava_tunnel_credential_id = "${FRP_TUNNEL_CREDENTIAL_ID}"
metadatas.enclava_tunnel_secret = "${FRP_TUNNEL_SECRET}"
metadatas.enclava_org_id = "${ENCLAVA_ORG_ID:-}"
metadatas.enclava_app_id = "${ENCLAVA_APP_ID:-}"
metadatas.enclava_deployment_id = "${ENCLAVA_DEPLOYMENT_ID:-}"

[[proxies]]
name = "${FRP_PROXY_NAME}"
type = "${FRP_PROXY_TYPE}"
localIP = "${FRP_LOCAL_ADDR}"
localPort = ${FRP_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF
    ) || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    chown_if_root 0:0 "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    chmod 600 "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    mv -f "$tmp" "$DEBIAN_FRP_CONFIG_FILE"
}

start_health() {
    busybox httpd -f -p "0.0.0.0:${DEBIAN_HEALTH_PORT}" -h "$DEBIAN_SSH_HOME/health" &
    HEALTH_PID="$!"
}

start_sshd() {
    rm -f "$DEBIAN_SSH_PID_FILE"
    /usr/sbin/dropbear -F -E -s -w -p "0.0.0.0:${DEBIAN_SSH_PORT}" -P "$DEBIAN_SSH_PID_FILE" -r "$DEBIAN_SSH_HOST_KEY" &
    SSHD_PID="$!"
}

start_frpc() {
    : >"$DEBIAN_FRP_LOG_FILE" || return 1
    chmod 600 "$DEBIAN_FRP_LOG_FILE" || return 1
    frpc -c "$DEBIAN_FRP_CONFIG_FILE" >"$DEBIAN_FRP_LOG_FILE" 2>&1 &
    FRPC_PID="$!"
}

process_running() {
    process_pid="${1:-}"
    [ -n "$process_pid" ] || return 1
    awk '
        $1 == "State:" {
            found = 1
            running = $2 !~ /^Z/
        }
        END { exit found && running ? 0 : 1 }
    ' "/proc/${process_pid}/status" 2>/dev/null
}

frp_proxy_ready() {
    status="$(curl -q --config "$DEBIAN_FRP_ADMIN_CURL_CONFIG" -fsS --max-time 1 "http://127.0.0.1:${DEBIAN_FRP_ADMIN_PORT}/api/status" 2>/dev/null)" || return 1
    compact="$(printf '%s' "$status" | tr -d '[:space:]')"
    printf '%s' "$compact" | grep -Fq "\"name\":\"${FRP_PROXY_NAME}\"" || return 1
    printf '%s' "$compact" | grep -Fq '"status":"running"'
}

frp_public_ssh_ready() {
    banner="$(curl -q -sS --max-time 2 "telnet://${FRP_PUBLIC_HOST}:${FRP_REMOTE_PORT}" 2>/dev/null | head -c 4)"
    [ "$banner" = "SSH-" ]
}

ssh_ready() {
    port_hex="$(printf '%04X' "$DEBIAN_SSH_PORT" 2>/dev/null)" || return 1
    awk -v port=":${port_hex}" '$2 ~ port "$" && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

publish_ready() {
    printf 'ssh -p %s %s@%s\n' "$FRP_REMOTE_PORT" "$DEBIAN_SSH_USER" "$FRP_PUBLIC_HOST" >"$DEBIAN_SSH_HOME/health/ssh.txt.tmp"
    printf 'tcp://%s:%s\n' "$FRP_PUBLIC_HOST" "$FRP_REMOTE_PORT" >"$DEBIAN_SSH_HOME/health/frp-url.txt.tmp"
    printf 'ok\n' >"$DEBIAN_SSH_HOME/health/healthz.tmp"
    mv "$DEBIAN_SSH_HOME/health/ssh.txt.tmp" "$DEBIAN_SSH_HOME/health/ssh.txt"
    mv "$DEBIAN_SSH_HOME/health/frp-url.txt.tmp" "$DEBIAN_SSH_HOME/health/frp-url.txt"
    mv "$DEBIAN_SSH_HOME/health/healthz.tmp" "$DEBIAN_SSH_HOME/health/healthz"
    touch "$DEBIAN_SSH_READY_MARKER" 2>/dev/null || true
}

mark_unready() {
    rm -f "$DEBIAN_SSH_HOME/health/healthz" "$DEBIAN_SSH_HOME/health/ssh.txt" "$DEBIAN_SSH_HOME/health/frp-url.txt"
}

write_process_snapshot() {
    for process_pid in "${HEALTH_PID:-}" "${SSHD_PID:-}" "${FRPC_PID:-}"; do
        [ -r "/proc/${process_pid}/status" ] || continue
        awk -v pid="$process_pid" '
            $1 == "Name:" { name = $2 }
            $1 == "State:" { state = $2 }
            $1 == "PPid:" { ppid = $2 }
            END {
                if (state != "") {
                    printf "pid=%s ppid=%s stat=%s comm=%s\n", pid, ppid, state, name
                }
            }
        ' "/proc/${process_pid}/status" 2>/dev/null || true
    done
}

write_debug_snapshot() {
    mkdir -p "${DEBIAN_SSH_DEBUG_FILE%/*}" 2>/dev/null || return 0
    {
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
        printf 'health_pid=%s ssh_pid=%s frpc_pid=%s\n' "${HEALTH_PID:-}" "${SSHD_PID:-}" "${FRPC_PID:-}"
        printf '\n[processes]\n'
        write_process_snapshot
        printf '\n[frpc-log]\n'
        tail -n "$DEBIAN_FRP_LOG_LINES" "$DEBIAN_FRP_LOG_FILE" 2>/dev/null || true
    } | sed -E \
        -e 's/(FRP_AUTH_TOKEN|FRP_TUNNEL_SECRET)=[^ ]+/\1=<redacted>/g' \
        -e 's/(token|secret|authorization)([^A-Za-z0-9_-]*).*/\1 <redacted>/I' \
        >"$DEBIAN_SSH_DEBUG_FILE.tmp" 2>/dev/null || return 0
    mv "$DEBIAN_SSH_DEBUG_FILE.tmp" "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || true
}

fail() {
    message="$1"
    echo "$message" >&2
    mkdir -p "$DEBIAN_SSH_HOME/health" 2>/dev/null || true
    printf '%s\n' "$message" >"$DEBIAN_SSH_HOME/health/startup-error.txt" 2>/dev/null || true
    if [ "$DEBIAN_SSH_WRAPPED" = "1" ]; then
        exit 1
    fi
    sleep 3600
    exit 1
}

cleanup() {
    for pid in "${FRPC_PID:-}" "${SSHD_PID:-}" "${HEALTH_PID:-}"; do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${FRPC_PID:-}" "${SSHD_PID:-}" "${HEALTH_PID:-}"; do
        [ -n "$pid" ] || continue
        wait "$pid" 2>/dev/null || true
    done
}

shutdown() {
    trap - INT TERM EXIT
    cleanup
    sync_persistent_state || true
    exit 0
}

if [ "${DEBIAN_SSH_FRP_ENTRYPOINT_TEST:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

trap shutdown INT TERM
trap cleanup EXIT

prepare_home || fail "home setup failed"
start_health || fail "health server failed to start"
wait_for_config || fail "CAP config did not arrive"
load_cap_config || fail "CAP config could not be loaded"
load_persisted_config || true
persist_config || fail "encrypted config persistence failed"
write_authorized_keys || fail "SSH authorized key validation failed"
prepare_ssh_ready_key || fail "SSH readiness key setup failed"
for key in FRP_SERVER_ADDR FRP_SERVER_PORT FRP_AUTH_TOKEN FRP_PROXY_NAME FRP_PROXY_TYPE FRP_REMOTE_PORT FRP_LOCAL_ADDR FRP_LOCAL_PORT FRP_TUNNEL_CREDENTIAL_ID FRP_TUNNEL_SECRET FRP_PUBLIC_HOST; do
    require_nonempty_env "$key" || fail "$key is required"
done
render_frpc_config || fail "frpc config render failed"
start_sshd || fail "SSH daemon failed to start"
start_frpc || fail "frpc failed to start"

unready_seconds=0
while :; do
    if process_running "${SSHD_PID:-}" && process_running "${FRPC_PID:-}" && ssh_ready && frp_proxy_ready && frp_public_ssh_ready; then
        publish_ready
        unready_seconds=0
    else
        mark_unready
        write_debug_snapshot
        unready_seconds=$((unready_seconds + 5))
        if [ "$unready_seconds" -ge "$DEBIAN_FRP_UNREADY_EXIT_SECONDS" ]; then
            echo "FRP SSH template stayed unready for ${unready_seconds}s" >&2
            exit 1
        fi
    fi
    sleep 5
done
