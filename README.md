# Debian SSH FRP Template

This image runs a Debian SSH workload behind the Enclava-operated FRP TCP relay.

PaaS injects the FRP relay address, bootstrap token, proxy name, remote port,
and per-instance tunnel credential through the CAP confidential config-token
path. Customers provide only `DEBIAN_SSH_AUTHORIZED_KEYS`.

The template publishes:

- `/healthz`
- `/ssh.txt`
- `/frp-url.txt`

`frpc` must authenticate `Login`, `HeartBeats`, and `NewWorkConns`; the entrypoint
therefore renders `auth.additionalScopes = ["HeartBeats", "NewWorkConns"]`.

The image builds upstream FRP 0.71.1 with Go 1.26.10 and the fixed `x/net`
dependency, including both original dashboards. Published upstream binaries
still contain the affected dependencies.

## Signed image

Every push to `main` publishes `ghcr.io/enclava-labs/debian-ssh-frp-template`
and signs the pushed digest keylessly from `.github/workflows/image.yml`.
Enclava PaaS accepts only digests signed by that identity:

```sh
cosign verify ghcr.io/enclava-labs/debian-ssh-frp-template@sha256:<digest> \
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
