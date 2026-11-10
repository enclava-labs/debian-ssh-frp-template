#!/bin/sh
set -u

: "${DEBIAN_SSH_USER:=user}"
: "${DEBIAN_SSH_UID:=10001}"
: "${DEBIAN_SSH_GID:=10001}"
: "${DEBIAN_SSH_HOME:=/home/user}"
: "${DEBIAN_SSH_PORT:=2222}"
: "${DEBIAN_HEALTH_PORT:=8080}"
: "${DEBIAN_HEALTH_LOCAL_PORT:=18080}"
: "${DEBIAN_SSH_PUBLIC_HEALTH_DIR:=/state/app-data/.enclava/debian-ssh-frp/public}"
: "${DEBIAN_SSH_PUBLIC_HTTPD_CONF:=/state/app-data/.enclava/debian-ssh-frp/httpd/public.httpd.conf}"
: "${DEBIAN_SSH_LOCAL_DIAG_DIR:=/state/app-data/.enclava/debian-ssh-frp/diag}"
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
: "${DEBIAN_SSH_DEBUG_FILE:=$DEBIAN_SSH_LOCAL_DIAG_DIR/debug.txt}"
: "${DEBIAN_SSH_STARTUP_ERROR_FILE:=$DEBIAN_SSH_LOCAL_DIAG_DIR/startup-error.txt}"
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
    canon="$(cd -P "$dir" && pwd)" || return 1
    if [ "$canon" = "/" ]; then
        echo "refusing to lock down /" >&2
        return 1
    fi
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
    if published_path "$DEBIAN_SSH_DEBUG_FILE" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "refusing to publish debug snapshot on the public health port" >&2
        return 1
    fi
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
    mv "$tmp" "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        return 0
    }
    chmod 600 "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || true
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

reject_multiline() {
    key="$1"
    value="$2"
    oneline="$(printf '%s' "$value" | tr -d '\n\r')"
    [ "$oneline" = "$value" ] || {
        echo "$key must be a single line" >&2
        return 1
    }
}

validate_host() {
    key="$1"
    value="$2"
    reject_multiline "$key" "$value" || return 1
    printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$' || {
        echo "$key must be a DNS host" >&2
        return 1
    }
}

validate_exact() {
    key="$1"
    value="$2"
    expected="$3"
    [ "$value" = "$expected" ] || {
        echo "$key must be ${expected}" >&2
        return 1
    }
}

validate_toml_token() {
    key="$1"
    value="$2"
    max="$3"
    reject_multiline "$key" "$value" || return 1
    printf '%s\n' "$value" | grep -Eq "^[A-Za-z0-9_-]{1,${max}}$" || {
        echo "$key must be a single safe token" >&2
        return 1
    }
}

validate_optional_toml_token() {
    key="$1"
    value="$2"
    max="$3"
    [ -n "$value" ] || return 0
    validate_toml_token "$key" "$value" "$max"
}

validate_secret_path() {
    key="$1"
    value="$2"
    reject_multiline "$key" "$value" || return 1
    printf '%s\n' "$value" | grep -Eq '^/[A-Za-z0-9_./-]{1,240}$' || {
        echo "$key must be a safe absolute path" >&2
        return 1
    }
    # Reject a ".." path segment only. ".enclava" is one dot and must stay legal.
    case "$value" in
        *"/.."*|*"../"*|*/..|../*|..)
            echo "$key must not contain .." >&2
            return 1
            ;;
    esac
}

validate_frp_login_token() {
    key="$1"
    value="$2"
    [ -n "$value" ] || {
        echo "$key is required" >&2
        return 1
    }
    bytes="$(printf '%s' "$value" | wc -c | tr -d ' ')"
    [ "$bytes" -le 4096 ] || {
        echo "$key is too long" >&2
        return 1
    }
    # Match frp::validate_single_token: non-empty, at most 4096 bytes, no
    # whitespace, not a placeholder. Quotes and backslashes stay legal.
    # The token is written to a file and only that path is interpolated into
    # frpc.toml, so those bytes cannot close a TOML string. Rejecting them
    # would fail startup for tokens the control plane already accepts.
    # Other non-whitespace bytes (including base64 +/=) stay legal: the
    # operator-chosen login token is not a generated charset.
    compact="$(printf '%s' "$value" | tr -d '[:space:]')"
    [ "$compact" = "$value" ] || {
        echo "$key must be a single token without whitespace" >&2
        return 1
    }
    upper="$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')"
    case "$upper" in
        *REDACTED*|*REPLACE_WITH*|*PLACEHOLDER*)
            echo "$key must not be a placeholder" >&2
            return 1
            ;;
    esac
}

validate_tls_forced() {
    # Hardcoded on below. A delivered false must fail closed, not connect
    # in cleartext and not be silently ignored.
    case "${FRP_TLS_ENABLE-}" in
        ""|true) ;;
        *)
            echo "FRP_TLS_ENABLE must be unset or true; TLS cannot be disabled" >&2
            return 1
            ;;
    esac
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
    # Refuse before chmod. An ancestor of the SSH home, or the persisted
    # config directory, would otherwise be mode 0700 and later emptied.
    refuse_public_health_overlap || return 1
    refuse_diag_dir || return 1
    prepare_secret_dir "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" || return 1
    prepare_secret_dir "$DEBIAN_SSH_LOCAL_DIAG_DIR" || return 1
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

# CAP-delivered values are not trusted. load_cap_config exports every file in
# a ready config dir, so a poisoned delivery can set any of these keys. Every
# quoted field is allowlisted before interpolation: a quote or newline would
# close the string and inject another [[proxies]] table. TLS, proxy type, and
# localIP are hardcoded after an exact check so the delivered bytes are not
# what gets written. The login token is not one of those fields: it is written
# to a file and only the path is quoted, so it follows the server token
# contract, quotes and backslashes included.
#
# The shared bootstrap token is still written. frps auth.token is that login
# gate, so dropping it here would break the relay. Passwordless sudo is the
# workload profile and can read this root-only file; mode 600 does not hide
# it. The relay authorizer must reject a login that presents only this token.
# Making the in-guest token per-deployment requires a relay change and is not
# done here.
render_frpc_config() {
    validate_host FRP_SERVER_ADDR "$FRP_SERVER_ADDR" || return 1
    validate_host FRP_PUBLIC_HOST "$FRP_PUBLIC_HOST" || return 1
    validate_uint FRP_SERVER_PORT "$FRP_SERVER_PORT" || return 1
    validate_uint FRP_REMOTE_PORT "$FRP_REMOTE_PORT" || return 1
    validate_uint FRP_LOCAL_PORT "$FRP_LOCAL_PORT" || return 1
    validate_uint DEBIAN_FRP_ADMIN_PORT "$DEBIAN_FRP_ADMIN_PORT" || return 1
    validate_exact FRP_PROXY_TYPE "$FRP_PROXY_TYPE" tcp || return 1
    validate_exact FRP_LOCAL_ADDR "$FRP_LOCAL_ADDR" 127.0.0.1 || return 1
    validate_toml_token FRP_PROXY_NAME "$FRP_PROXY_NAME" 128 || return 1
    validate_toml_token FRP_TUNNEL_CREDENTIAL_ID "$FRP_TUNNEL_CREDENTIAL_ID" 160 || return 1
    validate_toml_token FRP_TUNNEL_SECRET "$FRP_TUNNEL_SECRET" 256 || return 1
    validate_optional_toml_token ENCLAVA_ORG_ID "${ENCLAVA_ORG_ID:-}" 128 || return 1
    validate_optional_toml_token ENCLAVA_APP_ID "${ENCLAVA_APP_ID:-}" 128 || return 1
    validate_optional_toml_token ENCLAVA_DEPLOYMENT_ID "${ENCLAVA_DEPLOYMENT_ID:-}" 128 || return 1
    validate_secret_path DEBIAN_FRP_TOKEN_FILE "$DEBIAN_FRP_TOKEN_FILE" || return 1
    validate_frp_login_token FRP_AUTH_TOKEN "$FRP_AUTH_TOKEN" || return 1
    validate_tls_forced || return 1
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
transport.tls.enable = true
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
type = "tcp"
localIP = "127.0.0.1"
localPort = ${FRP_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF
    ) || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    if ! grep -qx 'transport.tls.enable = true' "$tmp"; then
        echo "frpc config did not hardcode TLS on" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if [ "$(grep -c '^\[\[proxies\]\]$' "$tmp")" != "1" ]; then
        echo "frpc config must contain exactly one proxy table" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
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

# Resolve the path mkdir -p + open will use: walk left to right, follow
# directory symlinks with pwd -P before applying "..", and follow a final
# symlink. A lexical collapse of ".." first misses outside/link/../file when
# link points into the served directory. ".." after a missing component is
# still applied: mkdir -p creates that component, and the following open
# uses it. Stopping at the missing component and appending the rest as text
# judges outside/missing/../../public/file outside the docroot, then the
# writer creates public/file.
resolve_open_path() {
    raw="$1"
    [ -n "$raw" ] || return 1
    RESOLVE_HOPS=$((${RESOLVE_HOPS:-0} + 1))
    [ "$RESOLVE_HOPS" -lt 40 ] || return 1
    case "$raw" in
        /*) ;;
        *) raw="$(pwd)/$raw" ;;
    esac
    while [ "$raw" != "/" ] && [ "${raw%/}" != "$raw" ]; do
        raw="${raw%/}"
    done
    current="/"
    rest="${raw#/}"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        case "$rest" in
            */*) rest="${rest#*/}" ;;
            *) rest="" ;;
        esac
        [ -n "$part" ] && [ "$part" != "." ] || continue
        if [ "$part" = ".." ]; then
            [ "$current" = "/" ] || current="${current%/*}"
            [ -n "$current" ] || current="/"
            continue
        fi
        if [ "$current" = "/" ]; then
            next="/$part"
        else
            next="$current/$part"
        fi
        if [ -L "$next" ] && [ ! -d "$next" ]; then
            [ -z "$rest" ] || return 1
            target="$(readlink "$next")" || return 1
            case "$target" in
                /*) resolve_open_path "$target" ;;
                *) resolve_open_path "$current/$target" ;;
            esac
            return $?
        fi
        if [ -d "$next" ]; then
            # cd in this shell, not a subshell. "$(cd -P /proc/self && pwd)"
            # records the subshell's pid, which is gone before the next
            # component is checked, so /proc/self/root never resolves to /.
            old_pwd="$(pwd -P)" || return 1
            cd -P "$next" || return 1
            current="$(pwd -P)" || {
                cd "$old_pwd" 2>/dev/null || true
                return 1
            }
            cd "$old_pwd" || return 1
            continue
        fi
        # Missing, or not a directory. Keep walking so a later ".." is
        # applied against this component. If ".." returns to an existing
        # directory, the next iteration resolves symlinks again.
        current="$next"
    done
    if [ -L "$current" ]; then
        target="$(readlink "$current")" || return 1
        case "$target" in
            /*) resolve_open_path "$target" ;;
            *) resolve_open_path "${current%/*}/$target" ;;
        esac
        return $?
    fi
    printf '%s\n' "$current"
}

# 0 = inside, 1 = outside, 2 = could not resolve. Callers that refuse a
# publication must treat 2 as refuse. Callers that skip a lockdown must not.
path_is_inside() {
    RESOLVE_HOPS=0
    child="$(resolve_open_path "$1")" || return 2
    RESOLVE_HOPS=0
    parent="$(resolve_open_path "$2")" || return 2
    [ -n "$child" ] && [ -n "$parent" ] || return 2
    # "/" as a case prefix becomes "//*", which does not match "/etc".
    # The filesystem root contains every absolute path.
    if [ "$parent" = "/" ]; then
        return 0
    fi
    case "$child" in
        "$parent"|"$parent"/*) return 0 ;;
    esac
    return 1
}

# True when the path is inside the parent or cannot be resolved.
published_path() {
    path_is_inside "$1" "$2"
    [ "$?" -ne 1 ]
}

# True when either path contains the other (including equality) or either
# cannot be resolved. Empty "other" is not an overlap.
health_root_overlaps() {
    other="$1"
    [ -n "$other" ] || return 1
    [ -n "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" ] || return 0
    published_path "$other" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" \
        || published_path "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" "$other"
}

# The public root is emptied and chmod'd on start. It must not contain, or
# sit inside, durable state. The persistence root normally contains the
# public directory; only refuse when emptying the public root would delete
# that persistence root.
refuse_public_health_overlap() {
    [ -n "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" ] || return 1
    RESOLVE_HOPS=0
    resolved_public="$(resolve_open_path "$DEBIAN_SSH_PUBLIC_HEALTH_DIR")" || {
        echo "public health root could not be resolved" >&2
        return 1
    }
    # path_is_inside treats "/" as a parent of everything, but do not rely on
    # that alone: emptying or chmod'ing "/" destroys the guest.
    if [ "$resolved_public" = "/" ]; then
        echo "refusing to serve / as the public health root" >&2
        return 1
    fi
    if health_root_overlaps "$DEBIAN_SSH_HOME"; then
        echo "refusing to serve a health root that overlaps the SSH home" >&2
        return 1
    fi
    if health_root_overlaps "$DEBIAN_SSH_LOCAL_DIAG_DIR"; then
        echo "diagnostic directory must not overlap the public health root" >&2
        return 1
    fi
    if health_root_overlaps "$DEBIAN_SSH_PERSISTED_CONFIG_DIR"; then
        echo "public health root must not overlap persisted config" >&2
        return 1
    fi
    if health_root_overlaps "$DEBIAN_FRP_STATE_DIR"; then
        echo "public health root must not overlap FRP state" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTENCE_PATH:-}" ] \
        && published_path "$DEBIAN_SSH_PERSISTENCE_PATH" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "public health root must not contain the persistence path" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PUBLIC_HTTPD_CONF:-}" ] \
        && published_path "$DEBIAN_SSH_PUBLIC_HTTPD_CONF" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "httpd config must not live in the public health root" >&2
        return 1
    fi
    if published_path "$DEBIAN_SSH_DEBUG_FILE" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" \
        || published_path "$DEBIAN_SSH_STARTUP_ERROR_FILE" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "diagnostic files must not be published on the public health port" >&2
        return 1
    fi
    for cap_dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
        if health_root_overlaps "$cap_dir"; then
            echo "public health root must not overlap a CAP config directory" >&2
            return 1
        fi
    done
    return 0
}

refuse_health_ports() {
    [ -n "$DEBIAN_HEALTH_PORT" ] || return 1
    [ -n "$DEBIAN_HEALTH_LOCAL_PORT" ] || return 1
    if [ "$DEBIAN_HEALTH_PORT" = "$DEBIAN_HEALTH_LOCAL_PORT" ]; then
        echo "local diagnostic port must not be the public health port" >&2
        return 1
    fi
    if [ "$DEBIAN_HEALTH_PORT" = "${DEBIAN_SSH_PORT:-}" ] \
        || [ "$DEBIAN_HEALTH_LOCAL_PORT" = "${DEBIAN_SSH_PORT:-}" ]; then
        echo "health port must not collide with the SSH port" >&2
        return 1
    fi
    if [ "$DEBIAN_HEALTH_PORT" = "${DEBIAN_FRP_ADMIN_PORT:-}" ] \
        || [ "$DEBIAN_HEALTH_LOCAL_PORT" = "${DEBIAN_FRP_ADMIN_PORT:-}" ]; then
        echo "health port must not collide with the FRP admin port" >&2
        return 1
    fi
    return 0
}

# prepare_secret_dir chmod 0700s the httpd config's parent. That parent must
# not be the SSH home, persisted config, or another durable directory.
refuse_httpd_conf_dir() {
    conf="${DEBIAN_SSH_PUBLIC_HTTPD_CONF:-}"
    [ -n "$conf" ] || return 1
    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || return 0
    RESOLVE_HOPS=0
    resolved_conf="$(resolve_open_path "$conf_dir")" || {
        echo "httpd config directory could not be resolved" >&2
        return 1
    }
    if [ "$resolved_conf" = "/" ]; then
        echo "refusing to lock down / for the httpd config" >&2
        return 1
    fi
    if published_path "$conf_dir" "$DEBIAN_SSH_HOME" \
        || published_path "$DEBIAN_SSH_HOME" "$conf_dir"; then
        echo "httpd config directory must not overlap the SSH home" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:-}" ] && published_path "$conf_dir" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR"; then
        echo "httpd config directory must not overlap persisted config" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:-}" ] && published_path "$DEBIAN_SSH_PERSISTED_CONFIG_DIR" "$conf_dir"; then
        echo "httpd config directory must not overlap persisted config" >&2
        return 1
    fi
    if [ -n "${DEBIAN_FRP_STATE_DIR:-}" ] && published_path "$conf_dir" "$DEBIAN_FRP_STATE_DIR"; then
        echo "httpd config directory must not overlap FRP state" >&2
        return 1
    fi
    if [ -n "${DEBIAN_FRP_STATE_DIR:-}" ] && published_path "$DEBIAN_FRP_STATE_DIR" "$conf_dir"; then
        echo "httpd config directory must not overlap FRP state" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTENCE_PATH:-}" ] \
        && published_path "$DEBIAN_SSH_PERSISTENCE_PATH" "$conf_dir"; then
        echo "httpd config directory must not contain the persistence path" >&2
        return 1
    fi
    # The default used to live in the parent of config, diag, and public.
    # chmod 0700 on that parent covers those trees. Refuse that layout.
    if [ -n "${DEBIAN_SSH_LOCAL_DIAG_DIR:-}" ] \
        && published_path "$DEBIAN_SSH_LOCAL_DIAG_DIR" "$conf_dir"; then
        echo "httpd config directory must not contain the diagnostic directory" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_LOCAL_DIAG_DIR:-}" ] \
        && published_path "$conf_dir" "$DEBIAN_SSH_LOCAL_DIAG_DIR"; then
        echo "httpd config directory must not sit inside the diagnostic directory" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PUBLIC_HEALTH_DIR:-}" ] \
        && published_path "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" "$conf_dir"; then
        echo "httpd config directory must not contain the public health root" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PUBLIC_HEALTH_DIR:-}" ] \
        && published_path "$conf_dir" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "httpd config directory must not sit inside the public health root" >&2
        return 1
    fi
    # : > follows a symlink. A conf file whose directory is outside a durable
    # tree can still point at a credential inside it. Resolve the file too.
    if published_path "$conf" "$DEBIAN_SSH_HOME"; then
        echo "httpd config must not overlap the SSH home" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:-}" ] \
        && published_path "$conf" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR"; then
        echo "httpd config must not overlap persisted config" >&2
        return 1
    fi
    if [ -n "${DEBIAN_FRP_STATE_DIR:-}" ] \
        && published_path "$conf" "$DEBIAN_FRP_STATE_DIR"; then
        echo "httpd config must not overlap FRP state" >&2
        return 1
    fi
    # A conf path inside a CAP config directory is truncated by `: >` after
    # prepare_secret_dir chmod 0700s that directory. An ancestor conf
    # directory would lock the CAP tree down the same way.
    for cap_dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
        if published_path "$conf" "$cap_dir" \
            || published_path "$cap_dir" "$conf" \
            || published_path "$conf_dir" "$cap_dir" \
            || published_path "$cap_dir" "$conf_dir"; then
            echo "httpd config must not overlap a CAP config directory" >&2
            return 1
        fi
    done
    return 0
}

# prepare_secret_dir chmod 0700s the diagnostic root, and startup deletes
# cgi-bin and httpd.conf there. That root must not be, contain, or sit
# inside durable state. The persistence root normally contains the
# diagnostic directory; only refuse when locking it down would cover the
# persistence root itself.
refuse_diag_dir() {
    diag="${DEBIAN_SSH_LOCAL_DIAG_DIR:-}"
    [ -n "$diag" ] || return 1
    RESOLVE_HOPS=0
    resolved_diag="$(resolve_open_path "$diag")" || {
        echo "diagnostic directory could not be resolved" >&2
        return 1
    }
    if [ "$resolved_diag" = "/" ]; then
        echo "refusing to lock down / for diagnostics" >&2
        return 1
    fi
    if published_path "$diag" "$DEBIAN_SSH_HOME" \
        || published_path "$DEBIAN_SSH_HOME" "$diag"; then
        echo "diagnostic directory must not overlap the SSH home" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:-}" ] \
        && published_path "$diag" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR"; then
        echo "diagnostic directory must not overlap persisted config" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:-}" ] \
        && published_path "$DEBIAN_SSH_PERSISTED_CONFIG_DIR" "$diag"; then
        echo "diagnostic directory must not overlap persisted config" >&2
        return 1
    fi
    if [ -n "${DEBIAN_FRP_STATE_DIR:-}" ] \
        && published_path "$diag" "$DEBIAN_FRP_STATE_DIR"; then
        echo "diagnostic directory must not overlap FRP state" >&2
        return 1
    fi
    if [ -n "${DEBIAN_FRP_STATE_DIR:-}" ] \
        && published_path "$DEBIAN_FRP_STATE_DIR" "$diag"; then
        echo "diagnostic directory must not overlap FRP state" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PERSISTENCE_PATH:-}" ] \
        && published_path "$DEBIAN_SSH_PERSISTENCE_PATH" "$diag"; then
        echo "diagnostic directory must not contain the persistence path" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PUBLIC_HEALTH_DIR:-}" ] \
        && published_path "$diag" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "diagnostic directory must not overlap the public health root" >&2
        return 1
    fi
    if [ -n "${DEBIAN_SSH_PUBLIC_HEALTH_DIR:-}" ] \
        && published_path "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" "$diag"; then
        echo "diagnostic directory must not overlap the public health root" >&2
        return 1
    fi
    conf="${DEBIAN_SSH_PUBLIC_HTTPD_CONF:-}"
    if [ -n "$conf" ]; then
        conf_dir="${conf%/*}"
        if [ "$conf_dir" != "$conf" ] \
            && published_path "$diag" "$conf_dir"; then
            echo "diagnostic directory must not overlap the httpd config directory" >&2
            return 1
        fi
        if [ "$conf_dir" != "$conf" ] \
            && published_path "$conf_dir" "$diag"; then
            echo "diagnostic directory must not overlap the httpd config directory" >&2
            return 1
        fi
    fi
    for cap_dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
        if published_path "$diag" "$cap_dir" \
            || published_path "$cap_dir" "$diag"; then
            echo "diagnostic directory must not overlap a CAP config directory" >&2
            return 1
        fi
    done
    return 0
}

empty_directory() {
    dir="$1"
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    canon="$(cd -P "$dir" && pwd)" || return 1
    if [ "$canon" = "/" ]; then
        echo "refusing to empty /" >&2
        return 1
    fi
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        rm -rf "$entry" || return 1
    done
}

# The previous image wrote diagnostics into $HOME/health and served that
# directory. It is tenant-writable and is no longer an HTTP root, so only
# those known diagnostic names are removed. Customer scripts and configs
# stay. A symlink is left alone: following it would delete files elsewhere.
scrub_former_health_diagnostics() {
    dir="$1"
    [ -n "$dir" ] || return 0
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
    rm -f \
        "$dir/debug.txt" \
        "$dir/startup-error.txt" \
        "$dir/debug.txt.tmp" \
        "$dir/startup-error.txt.tmp" \
        "$dir"/debug.txt.tmp.* \
        "$dir"/startup-error.txt.tmp.*
}

start_health() {
    [ -n "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" ] || return 1
    [ -n "$DEBIAN_SSH_LOCAL_DIAG_DIR" ] || return 1
    [ -n "$DEBIAN_SSH_PUBLIC_HTTPD_CONF" ] || return 1
    [ -n "$DEBIAN_HEALTH_PORT" ] || return 1
    [ -n "$DEBIAN_HEALTH_LOCAL_PORT" ] || return 1
    # Refuse before prepare_secret_dir or empty_directory. Those mutate the
    # configured path, including when it is an ancestor of durable state.
    refuse_health_ports || return 1
    refuse_public_health_overlap || return 1
    refuse_httpd_conf_dir || return 1
    refuse_diag_dir || return 1
    prepare_secret_dir "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" || return 1
    prepare_secret_dir "$DEBIAN_SSH_LOCAL_DIAG_DIR" || return 1
    # The previous image left files in this inode. Empty it so cgi-bin,
    # nested httpd.conf, and symlinks cannot survive an upgrade.
    empty_directory "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" || return 1
    scrub_former_health_diagnostics "$DEBIAN_SSH_HOME/health" || return 1
    rm -rf "$DEBIAN_SSH_LOCAL_DIAG_DIR/cgi-bin" "$DEBIAN_SSH_LOCAL_DIAG_DIR/httpd.conf" || return 1
    conf_dir="${DEBIAN_SSH_PUBLIC_HTTPD_CONF%/*}"
    [ "$conf_dir" != "$DEBIAN_SSH_PUBLIC_HTTPD_CONF" ] || conf_dir="."
    if [ "$conf_dir" != "." ]; then
        prepare_secret_dir "$conf_dir" || return 1
    fi
    : >"$DEBIAN_SSH_PUBLIC_HTTPD_CONF" || return 1
    chmod 600 "$DEBIAN_SSH_PUBLIC_HTTPD_CONF" || return 1
    busybox httpd -f -c "$DEBIAN_SSH_PUBLIC_HTTPD_CONF" -p "0.0.0.0:${DEBIAN_HEALTH_PORT}" -h "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" &
    HEALTH_PID="$!"
    busybox httpd -f -c "$DEBIAN_SSH_PUBLIC_HTTPD_CONF" -p "127.0.0.1:${DEBIAN_HEALTH_LOCAL_PORT}" -h "$DEBIAN_SSH_LOCAL_DIAG_DIR" &
    HEALTH_LOCAL_PID="$!"
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

# busybox httpd serves every name in the docroot, including *.tmp and
# dotfiles. Stage beside the served directory, then rename in, so a refresh
# never publishes a fourth public path. The stage is a new directory: adopting
# an existing sibling would chmod it 0700 and truncate matching names.
health_publish_parent() {
    root="$DEBIAN_SSH_PUBLIC_HEALTH_DIR"
    [ -n "$root" ] || return 1
    while [ "$root" != "/" ] && [ "${root%/}" != "$root" ]; do
        root="${root%/}"
    done
    [ "$root" != "/" ] || return 1
    parent="${root%/*}"
    [ "$parent" != "$root" ] || return 1
    # /health has an empty ${root%/*}. Stage under /, not fail closed.
    [ -n "$parent" ] || parent="/"
    printf '%s\n' "$parent"
}

# Only remove a directory this process created with mktemp. A customer
# directory that happens to use the prefix must not be deleted.
remove_health_publish_stage() {
    stage="$1"
    [ -n "$stage" ] || return 0
    case "$stage" in
        */.enclava-health-stage.??????) ;;
        *)
            echo "refusing to remove unexpected health publish stage" >&2
            return 1
            ;;
    esac
    [ "$stage" != "/" ] || return 1
    rm -rf "$stage"
}

# Fresh private directory beside the public root, on the same filesystem, so
# mv is a rename. Never adopt an existing name.
make_health_publish_stage() {
    parent="$(health_publish_parent)" || return 1
    [ -d "$parent" ] || return 1
    stage="$(umask 077 && mktemp -d "${parent}/.enclava-health-stage.XXXXXX")" || return 1
    case "$stage" in
        */.enclava-health-stage.??????) ;;
        *)
            rm -rf "$stage" 2>/dev/null || true
            return 1
            ;;
    esac
    if [ ! -d "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" ] || [ -L "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" ]; then
        remove_health_publish_stage "$stage" 2>/dev/null || rm -rf "$stage" 2>/dev/null || true
        return 1
    fi
    public_dev="$(stat -c %d "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" 2>/dev/null)" || {
        remove_health_publish_stage "$stage" 2>/dev/null || true
        return 1
    }
    stage_dev="$(stat -c %d "$stage" 2>/dev/null)" || {
        remove_health_publish_stage "$stage" 2>/dev/null || true
        return 1
    }
    if [ "$public_dev" != "$stage_dev" ]; then
        echo "health publish stage is not on the public root filesystem" >&2
        remove_health_publish_stage "$stage" 2>/dev/null || true
        return 1
    fi
    if published_path "$stage" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" \
        || published_path "$DEBIAN_SSH_PUBLIC_HEALTH_DIR" "$stage"; then
        echo "health publish stage overlaps the public health root" >&2
        remove_health_publish_stage "$stage" 2>/dev/null || true
        return 1
    fi
    chown_if_root 0:0 "$stage" || {
        remove_health_publish_stage "$stage" 2>/dev/null || true
        return 1
    }
    chmod 700 "$stage" || {
        remove_health_publish_stage "$stage" 2>/dev/null || true
        return 1
    }
    printf '%s\n' "$stage"
}

publish_ready() {
    stage="$(make_health_publish_stage)" || return 1
    printf 'ssh -p %s %s@%s\n' "$FRP_REMOTE_PORT" "$DEBIAN_SSH_USER" "$FRP_PUBLIC_HOST" >"$stage/ssh.txt" || {
        remove_health_publish_stage "$stage" || true
        return 1
    }
    printf 'tcp://%s:%s\n' "$FRP_PUBLIC_HOST" "$FRP_REMOTE_PORT" >"$stage/frp-url.txt" || {
        remove_health_publish_stage "$stage" || true
        return 1
    }
    printf 'ok\n' >"$stage/healthz" || {
        remove_health_publish_stage "$stage" || true
        return 1
    }
    mv -f "$stage/ssh.txt" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR/ssh.txt" || {
        remove_health_publish_stage "$stage" || true
        return 1
    }
    mv -f "$stage/frp-url.txt" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR/frp-url.txt" || {
        remove_health_publish_stage "$stage" || true
        return 1
    }
    mv -f "$stage/healthz" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR/healthz" || {
        remove_health_publish_stage "$stage" || true
        return 1
    }
    remove_health_publish_stage "$stage" || return 1
    touch "$DEBIAN_SSH_READY_MARKER" 2>/dev/null || true
}

mark_unready() {
    rm -f "$DEBIAN_SSH_PUBLIC_HEALTH_DIR/healthz" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR/ssh.txt" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR/frp-url.txt"
}

write_process_snapshot() {
    for process_pid in "${HEALTH_PID:-}" "${HEALTH_LOCAL_PID:-}" "${SSHD_PID:-}" "${FRPC_PID:-}"; do
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
    if published_path "$DEBIAN_SSH_DEBUG_FILE" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "refusing to publish debug snapshot on the public health port" >&2
        return 1
    fi
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
    mv "$DEBIAN_SSH_DEBUG_FILE.tmp" "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || return 0
    chmod 600 "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || true
}

fail() {
    message="$1"
    echo "$message" >&2
    err_file="$DEBIAN_SSH_STARTUP_ERROR_FILE"
    if published_path "$err_file" "$DEBIAN_SSH_PUBLIC_HEALTH_DIR"; then
        echo "refusing to publish startup-error on the public health port" >&2
    else
        err_dir="${err_file%/*}"
        [ -n "$err_dir" ] && [ "$err_dir" != "$err_file" ] && mkdir -p "$err_dir" 2>/dev/null || true
        # Replace a symlink instead of following it into the docroot.
        [ ! -L "$err_file" ] || rm -f "$err_file" 2>/dev/null || true
        err_tmp="${err_file}.tmp.$$"
        if (umask 077 && printf '%s\n' "$message" >"$err_tmp"); then
            mv -f "$err_tmp" "$err_file" 2>/dev/null || rm -f "$err_tmp" 2>/dev/null || true
        fi
    fi
    if [ "$DEBIAN_SSH_WRAPPED" = "1" ]; then
        exit 1
    fi
    sleep 3600
    exit 1
}

cleanup() {
    for pid in "${FRPC_PID:-}" "${SSHD_PID:-}" "${HEALTH_PID:-}" "${HEALTH_LOCAL_PID:-}"; do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${FRPC_PID:-}" "${SSHD_PID:-}" "${HEALTH_PID:-}" "${HEALTH_LOCAL_PID:-}"; do
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
