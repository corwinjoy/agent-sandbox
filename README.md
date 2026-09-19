# agent-sandbox

A guide and scripts for running an AI coding agent (Claude Code) inside a rootless Podman
sandbox on Linux, with a GitHub credential that works on one repository only.

The agent, its hooks and its MCP servers all run in a container that can see one project
directory, reach an allowlist of domains through a proxy, and optionally use the NVIDIA GPU
and hardware perf counters.

**Read the guide: [docs/setup-guide.md](docs/setup-guide.md)**

## Status

Early and only partly tested. Read this before relying on it.

| Piece | Status |
| --- | --- |
| All scripts | Pass `bash -n` |
| `01-setup-podman.sh`, `agent-run.sh` | **Not yet run under Podman.** `agent-run.sh` was dry-run against a stub `podman` |
| `02-github-single-repo.sh` | **Not yet run against GitHub** |
| Agent and proxy images | Build and run under Docker. Proxy allowlist verified under Docker |
| `03-claude-settings.sh`, `inspect-repo.sh` | Tested against sample inputs |
| Managed settings blocking hooks and MCP servers | Follows Anthropic's docs. Not exercised |
| Podman-specific behaviour (internal-network DNS, two networks on the proxy, `keep-id`, secrets) | Follows Podman's docs. Not exercised |

Try it on a scratch machine and a scratch repository first. The guide's [Test status](docs/setup-guide.md#test-status) section has the detail. Fixes are welcome.

## Quick start

Ubuntu 24.04, or another apt-based distribution with Podman 4.3 or later (Ubuntu 22.04 is too old). Check the host prerequisites in the guide's
[Before you start](docs/setup-guide.md#before-you-start) section first: leaving the `docker`
group and updating runc and the NVIDIA Container Toolkit matter more than anything below.

```bash
git clone https://github.com/corwinjoy/agent-sandbox.git
cd agent-sandbox
export PATH="$PWD/scripts:$PATH"

01-setup-podman.sh                                   # Stage 1: Podman, images, networks, GPU via CDI
02-github-single-repo.sh OWNER/REPO --protect-default-branch   # Stage 2: single-repo token
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
| [`scripts/agent-run.sh`](scripts/agent-run.sh) | Launcher: `--gpu`, `--perf`, `--untrusted`, `--shell`, and an experimental CPU-only `--gvisor` |
| [`scripts/inspect-repo.sh`](scripts/inspect-repo.sh) | Reviews a repository's agent config, editor tasks and install scripts before anything opens it |
| [`scripts/container/`](scripts/container/) | Containerfiles, Squid config, domain allowlists, git config, Claude Code managed settings |

## What this does not protect against

- It is a shared-kernel sandbox. A Linux kernel or NVIDIA driver bug can still reach the host. Use a VM or a separate machine for code you consider hostile.
- The project directory is mounted read-write. Anything the agent changes there, including build scripts, runs with your privileges if you run it on the host.
- `github.com` is on the trusted-mode allowlist, so data can be sent there. The single-repo token limits where.

The guide's appendices cover these limits and the alternatives.
