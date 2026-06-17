# Codex Sandbox

A Docker-based sandbox for running Codex CLI continuously in a long-lived
container. The primary mobile workflow is Codex Remote Connections from
iPhone, iPad, or the macOS app. SSH and tmux remain available for starting and
monitoring the singleton `codex remote-control` process, plus manual repository
maintenance shells.

The container itself does little after startup. It applies an egress firewall,
seeds default Codex guidance when needed, and sleeps forever. The control tmux
session is where you manually start `codex remote-control`; repo-specific tmux
sessions are optional maintenance shells.

Codex's Linux sandbox uses `bubblewrap` inside the container. OpenAI's
sandboxing prerequisites require `bubblewrap` and support for unprivileged user
namespace creation on Linux/WSL2. Docker's default seccomp profile blocks that
namespace creation, and Docker's default AppArmor profile can block the mount
operations `bubblewrap` performs during sandbox setup. The Compose service sets
`seccomp=unconfined` and `apparmor=unconfined` instead of running the container
as `privileged`.

## Features

- Non-root `dev` user by default.
- Docker-level egress firewall using `iptables` and `ipset`.
- Host bind mounts for workspace, Codex state, and shell history.
- A singleton control tmux session under `/workspace`.
- Optional per-repository shell sessions under `/workspace/<repo>`.
- Codex CLI installed from `@openai/codex`.
- `bubblewrap` installed for Codex's Linux sandbox.
- No Docker socket mount.
- No in-container SSH daemon. Mobile SSH terminates on the Docker host, then
  `./bin/cx` enters tmux inside the container when manual access is needed.

## Prerequisites

- Docker Engine and the Docker Compose plugin.
- A host reachable from your mobile device over a trusted network, VPN, or SSH
  setup.
- A Linux container runtime that supports `NET_ADMIN`, `NET_RAW`, `iptables`,
  `ipset`, `bubblewrap`, and unprivileged user namespaces. Linux hosts are the
  primary target; Docker Desktop may work but is not the main security
  boundary.

## Quick Start

Create the host-side bind mount directories before starting the container:

```sh
mkdir -p codex-workspace data/codex data/history
```

Build and start the container:

```sh
docker compose up -d
```

Clone or copy repositories under `codex-workspace`:

```sh
git clone <repo-url> codex-workspace/my-repo
```

Attach to the control tmux session:

```sh
./bin/cx
```

Inside tmux, sign in and start remote control:

```sh
codex login --device-auth
codex remote-control
```

Detach from tmux with `Ctrl-Space` then `d`. Re-run `./bin/cx` to reattach
later.

For manual work in a repository shell:

```sh
./bin/cx my-repo
```

## Mobile Workflow

From iOS, iPadOS, or the macOS app, use Codex Remote Connections against the
host/container environment. The connected host provides the project files,
tools, credentials, sandbox policy, and approvals.

For SSH fallback or maintenance:

1. SSH into the Docker host over a trusted path. Prefer a VPN or private
   network. Do not expose SSH broadly without normal hardening.
2. Change to this repository on the host.
3. Run `./bin/cx` to start or monitor `codex remote-control`.
4. Run `./bin/cx <repo>` only when you need a repository shell.
5. Detach with `Ctrl-Space` then `d`.

The SSH connection does not need to stay open. tmux and Codex continue inside
the container after your SSH session disconnects.

## Directory Layout

| Host path | Container path | Purpose |
| --- | --- | --- |
| `./codex-workspace` | `/workspace` | Repository workspace root |
| `./codex-workspace/<repo>` | `/workspace/<repo>` | One repository per subdirectory |
| `./data/codex` | `/home/dev/.codex` | Codex config, auth, sessions, skills, logs |
| `./data/history` | `/commandhistory` | Shell history |

Do not commit `data/`. It can contain Codex credentials, including
`auth.json`.

## tmux Wrapper

```sh
./bin/cx            # attach to /workspace control session
./bin/cx my-repo    # attach to /workspace/my-repo shell session
./bin/cx -l         # list sessions and available repos
```

Environment overrides:

```sh
CX_CONTAINER=codex ./bin/cx my-repo
CX_WORKDIR=/workspace ./bin/cx my-repo
CX_CONTROL_SESSION=main ./bin/cx
```

The control session defaults to `codex-control`. Repo shell session names use
the `repo-` prefix plus the repository directory name. `.` and `:` are
sanitized to `_` for tmux only; the working directory remains the exact repo
path.

## Codex Authentication

Codex state is persisted in `./data/codex`.

Recommended for headless or remote hosts:

```sh
codex login --device-auth
```

You can also run an interactive login if the environment can complete the
browser flow:

```sh
codex login
```

If you use file-backed auth, `./data/codex/auth.json` is a secret. Do not print
it, commit it, or paste it into tickets or chat.

## Codex Configuration and Rules

The image bundles:

- `sandbox-config.toml`
- `sandbox-rules/default.rules`

On first startup, the entrypoint copies them into:

- `./data/codex/config.toml`
- `./data/codex/rules/default.rules`

Existing files are not overwritten. The config sets a conservative local
posture: `on-request` approvals, a custom workspace-write permission profile,
no shell-command network access, no live web search, no startup update check,
and filesystem deny rules for common secret files. The rules file mirrors the
Claude sandbox command policy as closely as Codex supports: destructive git,
GitHub mutation, recursive deletion, general sudo, recursive chmod, and chown
are forbidden; broad reads/deletes/moves prompt; routine local inspection,
build, and test commands are allowed.

To apply updated bundled defaults after you have already started the container,
copy them manually from the host:

```sh
cp sandbox-config.toml data/codex/config.toml
mkdir -p data/codex/rules
cp sandbox-rules/default.rules data/codex/rules/default.rules
```

## Firewall

`init-firewall.sh` runs at container startup and:

- Allows Docker DNS and loopback.
- Allows outbound SSH.
- Fetches GitHub IP ranges from `https://api.github.com/meta`.
- Resolves required Codex/OpenAI and package-manager domains once and pins
  their IPv4 addresses in an `ipset`.
- Defaults INPUT, FORWARD, and OUTPUT to DROP.
- Verifies that `https://example.com` is blocked and GitHub/OpenAI are
  reachable.

The default required domains are:

```text
api.openai.com
api.chatgpt.com
auth.openai.com
chatgpt.com
github.com
raw.githubusercontent.com
registry.npmjs.org
npmjs.com
npmjs.org
nodejs.org
crates.io
static.crates.io
index.crates.io
rustup.rs
```

Override the domain lists when needed:

```yaml
environment:
  CODEX_REQUIRED_DOMAINS: "api.openai.com api.chatgpt.com auth.openai.com chatgpt.com"
  CODEX_OPTIONAL_DOMAINS: "sentry.io statsig.com"
```

If upstream DNS changes after startup, restart the container so the firewall
re-resolves the allowlist.

## Installing Extra Apt Packages

The running container blocks apt mirrors and the `dev` user cannot use general
sudo. From the host, an operator with Docker access can install temporary tools:

```sh
docker exec -u 0 codex install-tools valgrind python3
```

The helper temporarily allows apt mirrors, installs the packages, and restores
the locked firewall on exit. Installs are not persistent across image rebuilds
or container recreation.

## Updates

Manual update:

```sh
docker compose build --pull
docker compose up -d
```

The image includes a Watchtower pre-update hook. If Watchtower lifecycle hooks
are enabled on your Watchtower service, the hook exits `75` while a `codex`
process is running, asking Watchtower to postpone the update.

## CI Images

`.github/workflows/build.yml` builds and pushes the image to Docker Hub and
GHCR on pushes to `main`, `v*` tags, manual dispatch, and a daily schedule.
The workflow resolves the latest published `@openai/codex` npm version and
passes it to the Docker build as `CODEX_VERSION`, so the Codex install layer
refreshes only when a new CLI version exists.

Default image names:

```text
Docker Hub: jqtype/codex-sandbox
GHCR: ghcr.io/<github-owner>/codex-sandbox
```

Set the GitHub repository variable `DOCKERHUB_IMAGE` to override the Docker Hub
image name. Docker Hub push requires these repository secrets:

```text
DOCKERHUB_USERNAME
DOCKERHUB_TOKEN
```

GHCR uses the built-in `GITHUB_TOKEN` with `packages: write` permission.

## Notification Scope

This MVP intentionally does not include Slack, email, ntfy, Pushover, or a
custom notification relay. The operational model is mobile SSH on demand plus
tmux persistence. If notifications are added later, prefer a host-local relay
so external notification credentials stay outside the container and outside the
repositories under `/workspace`.
