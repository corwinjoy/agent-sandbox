# agent-sandbox

A guide and scripts for running an AI coding agent (Claude Code) inside a rootless Podman
sandbox on Linux, with a GitHub credential that works on one repository only.

The agent, its hooks and its MCP servers all run in a container that can see one project
directory, reach an allowlist of domains through a proxy, and optionally use the NVIDIA GPU
and hardware perf counters.

**Read the guide: [docs/setup-guide.md](docs/setup-guide.md)**

## Status

Tested end to end on one machine. Read this before relying on it elsewhere.

| Piece | Status |
| --- | --- |
| `01-setup-podman.sh` | Run from scratch on Ubuntu 24.04 with Podman 4.9.3, after fixing three bugs the first run exposed |
| `agent-run.sh` | Trusted and untrusted modes confirmed under Podman: file ownership, no capabilities, allowlist, no direct route, no DNS. `--perf` and `--gpu --perf` confirmed |
| `--gpu` | Confirmed: a CUDA kernel compiled and ran on the GPU inside the container. Needed a compatible CDI spec on Podman 4.9, which the setup script now installs |
| Claude Code logged in inside the container | Confirmed, including auto mode by default and `--ask` for manual |
| Blocking a repository's hooks, MCP servers and `CLAUDE.md` | Confirmed with `test-hook-blocking.sh --untrusted`: six runs with controls, each untrusted-mode layer tested on its own |
| Untrusted mode with a logged-in session | Confirmed: sign-in works through the Anthropic-only allowlist; manual permission mode |
| `02-github-single-repo.sh` | Used twice to create real single-repository tokens |
| `agent-run.sh --check-token` | Confirmed against a real token: works on its repository, cannot write anywhere else |
| `03-claude-settings.sh`, `inspect-repo.sh` | Tested against sample inputs |

The guide's [Test status](docs/setup-guide.md#test-status) section has the detail. Fixes are welcome.

## Quick start

Ubuntu 24.04, or another apt-based distribution with Podman 4.3 or later (Ubuntu 22.04 is too old). Check the host prerequisites in the guide's
[Before you start](docs/setup-guide.md#before-you-start) section first: leaving the `docker`
group and updating runc and the NVIDIA Container Toolkit matter more than anything below.

```bash
git clone https://github.com/corwinjoy/agent-sandbox.git
cd agent-sandbox
export PATH="$PWD/scripts:$PATH"

01-setup-podman.sh                                   # Stage 1: Podman, images, networks, GPU via CDI
02-github-single-repo.sh OWNER/REPO                            # Stage 2: single-repo token
(cd ~/src/myrepo && agent-run.sh --check-token)                # confirm it works there and nowhere else
03-claude-settings.sh                                # Stage 3: harden Claude Code on the host

cd ~/src/myrepo
agent-run.sh              # the first run asks you to log in to Claude; add --gpu and --perf as needed
```

For a repository you have not reviewed:

```bash
inspect-repo.sh https://github.com/someone/project.git   # clone without executing, flag what it would auto-run
cd untrusted/project && agent-run.sh --untrusted           # no token, no GPU, model-API-only network
```

## What is here

| Path | Contents |
| --- | --- |
| [`docs/setup-guide.md`](docs/setup-guide.md) | The developer guide: three stages, daily use, untrusted repositories, and appendices with the reasoning and sources |
| [`scripts/01-setup-podman.sh`](scripts/01-setup-podman.sh) | Host checks, Podman install, NVIDIA CDI spec, perf seccomp profile, images, internal networks |
| [`scripts/02-github-single-repo.sh`](scripts/02-github-single-repo.sh) | Fine-grained token for one repo (read, commit, push, comment), verified and stored as a Podman secret |
| [`scripts/03-claude-settings.sh`](scripts/03-claude-settings.sh) | Merges sandbox and credential hardening into `~/.claude/settings.json` |
| [`scripts/agent-run.sh`](scripts/agent-run.sh) | Launcher. Trusted sessions start in auto permission mode, untrusted ones in manual. Flags: `--gpu`, `--perf`, `--ask`, `--untrusted`, `--shell`, and an experimental CPU-only `--gvisor` |
| [`scripts/inspect-repo.sh`](scripts/inspect-repo.sh) | Reviews a repository's agent config, editor tasks and install scripts before anything opens it |
| [`scripts/test-hook-blocking.sh`](scripts/test-hook-blocking.sh) | Checks, with a control run, that the sandbox blocks a repository's hooks and MCP servers |
| [`scripts/container/`](scripts/container/) | Containerfiles, Squid config, domain allowlists, git config, Claude Code managed settings |

## What this does not protect against

- It is a shared-kernel sandbox. A Linux kernel or NVIDIA driver bug can still reach the host. Use a VM or a separate machine for code you consider hostile. The guide's [Appendix E](docs/setup-guide.md#appendix-e-why-not-docker-sandboxes) compares this with Docker Sandboxes, which is VM-based, and says when to pick which.
- The project directory is mounted read-write. Anything the agent changes there, including build scripts, runs with your privileges if you run it on the host.
- `github.com` is on the trusted-mode allowlist, so data can be sent there. The single-repo token limits where.

The guide's appendices cover these limits and the alternatives.
