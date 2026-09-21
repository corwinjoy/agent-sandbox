# agent-sandbox

[![CI](https://github.com/corwinjoy/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/corwinjoy/agent-sandbox/actions/workflows/ci.yml)

A guide and scripts for running an AI coding agent (Claude Code) inside a rootless Podman
sandbox on Linux, with a GitHub credential that works on one repository only.

The agent, its hooks and its MCP servers all run in a container that can see one project
directory, reach an allowlist of domains through a proxy, and optionally use the NVIDIA GPU
and hardware perf counters.

**Read the guide: [docs/setup-guide.md](docs/setup-guide.md).** For the reasoning in talk form,
see [slides/](slides/).

## Quick start

Ubuntu 24.04, or another apt-based distribution with Podman 4.3 or later (Ubuntu 22.04 is too old).
Check the host prerequisites in the guide's [Before you start](docs/setup-guide.md#before-you-start)
section first: leaving the `docker` group and updating runc and the NVIDIA Container Toolkit
matter more than anything below.

```bash
git clone https://github.com/corwinjoy/agent-sandbox.git
cd agent-sandbox
export PATH="$PWD/scripts:$PATH"

01-setup-podman.sh                                # Stage 1: Podman, images, networks, GPU via CDI
02-github-single-repo.sh OWNER/REPO               # Stage 2: single-repo token
(cd ~/src/myrepo && agent-run.sh --check-token)   # confirm it works there and nowhere else
03-claude-settings.sh                             # Stage 3: harden Claude Code on the host

cd ~/src/myrepo
agent-run.sh                                      # the first run asks you to log in to Claude
agent-run.sh --gpu --perf                         # CUDA and hardware perf counters
```

For the CUDA toolkit inside the container, run Stage 1 as
`BASE_IMAGE=docker.io/nvidia/cuda:12.6.3-devel-ubuntu24.04 01-setup-podman.sh`.

For a repository you have not reviewed:

```bash
inspect-repo.sh https://github.com/someone/project.git   # clone without executing, flag what it would auto-run
cd untrusted/project && agent-run.sh --untrusted           # no token, no GPU, model-API-only network
```

## What is here

```text
docs/
  setup-guide.md              The guide: three stages, daily use, untrusted repositories,
                              troubleshooting, alternatives, appendices, test status, sources
scripts/
  01-setup-podman.sh          Stage 1: host checks, Podman, NVIDIA CDI, images, networks
  02-github-single-repo.sh    Stage 2: fine-grained token for one repo, stored as a Podman secret
  03-claude-settings.sh       Stage 3: sandbox and credential hardening for Claude Code on the host
  agent-run.sh                Launcher: --gpu, --perf, --ask, --untrusted, --shell, --check-token
  inspect-repo.sh             Review a repository's agent config, editor tasks and install
                              scripts before anything opens it
  test-hook-blocking.sh       Prove, with control runs, that the sandbox blocks a repository's
                              hooks, MCP servers and CLAUDE.md
  container/
    Containerfile.agent       Agent image: Claude Code, git, gh, Python, build tools, perf
    Containerfile.proxy       Egress proxy image (Squid)
    squid.conf                Proxy rules: HTTPS CONNECT to allowlisted domains only
    allowed-domains.txt       Allowlist, trusted mode
    allowed-domains-untrusted.txt   Allowlist, untrusted mode: Anthropic endpoints only
    gitconfig                 System git config in the image: token helper, SSH-to-HTTPS, hooks off
    managed-settings.json     Claude Code managed settings baked into the image
    check-github-token.sh     The token check that agent-run.sh --check-token runs in the sandbox
tests/
  run-tests.sh                Static checks and unit tests; --integration adds real-Podman tests
  static.sh, unit.sh, integration.sh, check-docs.py, lib.sh
slides/
  agent-sandbox-talk.odp      A 15-slide talk (LibreOffice Impress) with speaker notes
  build-slides.js             Generates the deck; see slides/README.md
.github/workflows/ci.yml      Runs the tests on every push and pull request
```

## What this does not protect against

- It is a shared-kernel sandbox. A Linux kernel or NVIDIA driver bug can still reach the host.
  Use a VM or a separate machine for code you consider hostile. The guide's
  [Alternatives](docs/setup-guide.md#alternatives) section compares this with the built-in Claude
  Code sandbox, plain Docker, gVisor, Docker Sandboxes and VMs, and says when to pick which.
- The project directory is mounted read-write. Anything the agent changes there, including build
  scripts, runs with your privileges if you run it on the host. Git's own routes are handled:
  `.git/hooks` is read-only, and `.git/config` changes are shown to you after each session.
- `github.com` is on the trusted-mode allowlist, so data can be sent there. The single-repo token
  limits where.

Tested end to end on one machine (Ubuntu 24.04, Podman 4.9.3); the guide's
[Test status](docs/setup-guide.md#test-status) section has the detail. Fixes are welcome.
