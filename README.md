# Debian SSH FRP Template

This image runs a Debian SSH workload behind the Enclava-operated FRP TCP relay.

PaaS injects the FRP relay address, bootstrap token, proxy name, remote port,
and per-instance tunnel credential through the CAP confidential config-token
path. Customers provide only `DEBIAN_SSH_AUTHORIZED_KEYS`.

The workload user has passwordless sudo, so root-only file modes do not hide
FRP material from the tenant. The shared bootstrap token remains the relay
login gate (`frps` `auth.token`); this image cannot replace it with a
per-deployment token without a relay change. Tunnel open must be authorized
by the per-instance credential.
The entrypoint hardcodes TLS on and allowlists every value it interpolates
into `frpc.toml` or the admin curl config, so a delivered
`FRP_TLS_ENABLE=false` or a quote/newline in an interpolated field fails closed
instead of injecting another `[[proxies]]` table. The login token is not
interpolated: it is written to a file referenced by `auth.tokenSource.file.path`
and keeps the server contract (any non-whitespace token, including quotes and
backslashes).

The template publishes only:

- `/healthz`
- `/ssh.txt`
- `/frp-url.txt`

Those files are written under `/state/app-data/.enclava/debian-ssh-frp/public`
(root, mode 0700), not under `$HOME/health`. `debug.txt` and
`startup-error.txt` are not on that port. They are written under
`/state/app-data/.enclava/debian-ssh-frp/diag/` (mode 0700, root) and are
also served on `127.0.0.1:${DEBIAN_HEALTH_LOCAL_PORT}` (default 18080).
CAP publishes the app port (`8080`), not the loopback diagnostic port.
On start the public directory is emptied and recreated root-owned, so a
leftover `cgi-bin` script, nested `httpd.conf`, or symlink cannot stay on
port 8080. A health root of `/`, or one that overlaps the SSH home, persisted
config, FRP state, a CAP config directory, or the persistence root, is
refused before that directory is chmod'd or emptied. Readiness files are
written in a fresh private directory beside the served directory, on the
same filesystem, and renamed in. An existing sibling is not reused or
chmod'd, and the stage directory is removed after the rename. A public
root such as `/health` stages under `/`.
`$HOME/health` is no longer served; startup removes only the previous
image's `debug.txt` and `startup-error.txt` there, not customer scripts.
A diagnostic directory that overlaps the SSH home, persisted config, FRP
state, a CAP config directory, or that contains the persistence root, is
refused before it is chmod'd.
Neither health port may equal `DEBIAN_SSH_PORT` or `DEBIAN_FRP_ADMIN_PORT`.
The listeners are given an empty root-owned `-c` config so a top-level
docroot `httpd.conf` is not loaded. That file defaults to
`/state/app-data/.enclava/debian-ssh-frp/httpd/public.httpd.conf`, whose
directory does not contain `config`, `diag`, or `public`. A config
directory that would cover those trees, the SSH home, FRP state, or a
CAP config directory is refused before it is chmod'd.

`frpc` must authenticate `Login`, `HeartBeats`, and `NewWorkConns`; the entrypoint
therefore renders `auth.additionalScopes = ["HeartBeats", "NewWorkConns"]`.

The image builds upstream FRP 0.71.1 with Go 1.26.10 and the fixed `x/net`
dependency, including both original dashboards. Published upstream binaries
still contain the affected dependencies.

## Signed image

Every push to `main` publishes `ghcr.io/enclava-labs/debian-ssh-frp`
and signs the pushed digest keylessly from `.github/workflows/image.yml`.
Enclava PaaS accepts only digests signed by that identity:

```sh
cosign verify ghcr.io/enclava-labs/debian-ssh-frp@sha256:<digest> \
  --certificate-identity https://github.com/enclava-labs/debian-ssh-frp-template/.github/workflows/image.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The same workflow exports `frp-server/frps` and its `frps.sigstore.json`
bundle in the `debian-ssh-frp-template-image` artifact. Verify the bundle
against that identity and source commit before installing the server with
Ansible. Keep relay configuration, credentials and assigned ports unchanged.

Local checks:

```sh
scripts/test-entrypoint.sh
docker build -t debian-ssh-frp-template:local .
scripts/test-runtime-image.sh debian-ssh-frp-template:local
```

## Operations notes

Persistent guest-local SSH material (the dropbear host key and the readiness
key) is validated at every boot. An unparseable key — e.g. corrupted by an
interrupted boot or redeploy — is logged, moved aside as `*.corrupt` for
inspection (the first bad copy wins; later corrupt copies are discarded),
and regenerated, with a line to stderr in the pod log. A missing key on a
normal first boot generates quietly. SSH clients pinned to a previous host
key (TOFU) will see a host-key change after such a rotation; that
availability-over-continuity trade-off is deliberate.

The entrypoint restart wrapper gives up after `DEBIAN_SSH_MAX_RESTARTS`
(default 5) consecutive failures that never reached readiness. Each child
attempt starts with the readiness marker (written once the tunnel is up)
cleared; a child that reaches ready during its own run resets the budget,
so a workload that keeps recovering keeps restarting, while persistent
failures — even after a healthy past, e.g. a lost config channel —
surface as a container crash instead of an all-green pod with a dead
workload.
