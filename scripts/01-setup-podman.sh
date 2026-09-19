#!/usr/bin/env bash
# Stage 1: rootless Podman sandbox for a coding agent (Ubuntu 22.04+/Debian 12+).
#
# What it does, in order:
#   1. Checks the host for known-bad states (docker group, old NVIDIA toolkit, old runc).
#   2. Installs Podman and the rootless helpers.
#   3. Checks that your user has subordinate uid/gid ranges (needed for rootless).
#   4. If an NVIDIA GPU is present: generates the CDI spec so containers can request it.
#   5. Writes a seccomp profile that also allows perf_event_open (for --perf runs).
#   6. Builds the agent image and the egress-proxy image.
#   7. Creates the two internal (no-route-out) networks.
#
# Safe to re-run. Uses sudo only for apt and for writing /etc/cdi.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox"
BASE_IMAGE="${BASE_IMAGE:-docker.io/library/ubuntu:24.04}"   # override for a CUDA base image

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; }
ok()   { printf '  [ok] %s\n' "$*"; }
# Version compare: ver_ge A B  -> true when A >= B
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# ---------------------------------------------------------------- 1. host checks
say "Checking the host"
if id -nG | tr ' ' '\n' | grep -qx docker; then
  warn "You are in the 'docker' group. Any process running as you can become root on this"
  warn "machine with one 'docker run -v /:/host'. Leave it:  sudo gpasswd -d $USER docker"
fi
if id -nG | tr ' ' '\n' | grep -qx lxd; then
  warn "You are in the 'lxd' group, which is also root-equivalent:  sudo gpasswd -d $USER lxd"
fi
if command -v runc >/dev/null; then
  RUNC_V="$(runc --version | awk 'NR==1{print $3}')"
  ver_ge "$RUNC_V" 1.2.8 && ok "runc $RUNC_V" \
    || warn "runc $RUNC_V predates the Nov 2025 escape fixes (need 1.2.8 / 1.3.3+). Update Docker/containerd."
fi
if command -v nvidia-ctk >/dev/null; then
  CTK_V="$(nvidia-ctk --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  ver_ge "$CTK_V" 1.17.8 && ok "NVIDIA Container Toolkit $CTK_V" \
    || warn "NVIDIA Container Toolkit $CTK_V is affected by CVE-2025-23266 (need 1.17.8+). Upgrade before using --gpu."
fi

# ---------------------------------------------------------------- 2. install podman
say "Installing Podman and rootless helpers"
sudo apt-get update -qq
# uidmap: newuidmap/newgidmap for user namespaces. passt/slirp4netns: rootless networking.
# crun: low-level runtime (not affected by the runc bugs above). jq: used by these scripts.
sudo apt-get install -y podman uidmap slirp4netns passt fuse-overlayfs crun jq curl
ok "$(podman --version)"

# ---------------------------------------------------------------- 3. subuid / subgid
say "Checking subordinate id ranges"
for f in /etc/subuid /etc/subgid; do
  if grep -q "^$USER:" "$f"; then ok "$f has an entry for $USER"
  else
    warn "$f has no entry for $USER; adding 65536 ids"
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
    podman system migrate
    break
  fi
done

# ---------------------------------------------------------------- 4. GPU via CDI
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
  say "Generating the NVIDIA CDI spec"
  if ! command -v nvidia-ctk >/dev/null; then
    warn "nvidia-ctk not found. Install the NVIDIA Container Toolkit (1.17.8+), then re-run."
  else
    sudo mkdir -p /etc/cdi
    # Re-run this after every NVIDIA driver update (toolkit 1.18+ does it automatically).
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null
    nvidia-ctk cdi list | sed 's/^/  /'
  fi
else
  say "No working NVIDIA GPU found; skipping CDI (the --gpu flag will not work)"
fi

# ---------------------------------------------------------------- 5. seccomp for perf
say "Writing a seccomp profile that allows perf_event_open"
mkdir -p "$CFG_DIR"
SECCOMP_SRC=/usr/share/containers/seccomp.json
if [ -r "$SECCOMP_SRC" ]; then
  # Start from Podman's default profile and add one unconditional allow rule.
  # Used only when you pass --perf to agent-run.sh.
  jq '.syscalls += [{"names":["perf_event_open"],"action":"SCMP_ACT_ALLOW"}]' \
     "$SECCOMP_SRC" > "$CFG_DIR/seccomp-perf.json"
  ok "$CFG_DIR/seccomp-perf.json"
else
  warn "$SECCOMP_SRC not found; --perf will be unavailable"
fi
PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid)"
[ "$PARANOID" -le 2 ] && ok "kernel.perf_event_paranoid=$PARANOID" \
  || warn "kernel.perf_event_paranoid=$PARANOID blocks unprivileged perf. For profiling: sudo sysctl kernel.perf_event_paranoid=2"

# ---------------------------------------------------------------- 6. images
say "Copying editable allowlists to $CFG_DIR (existing copies are kept)"
for f in allowed-domains.txt allowed-domains-untrusted.txt; do
  [ -e "$CFG_DIR/$f" ] || cp "$HERE/container/$f" "$CFG_DIR/$f"
done

say "Building images (base: $BASE_IMAGE)"
podman build -t localhost/agent-proxy  -f "$HERE/container/Containerfile.proxy" "$HERE/container"
podman build -t localhost/agent-claude -f "$HERE/container/Containerfile.agent" \
       --build-arg BASE_IMAGE="$BASE_IMAGE" "$HERE/container"

# ---------------------------------------------------------------- 7. networks
say "Creating internal networks"
# --internal: containers on these networks have no route to the outside.
# Their only way out is the proxy container, which is also attached to the default network.
for net in agent-internal agent-untrusted; do
  podman network exists "$net" || podman network create --internal "$net" >/dev/null
  ok "network $net"
done

say "Done. Next: 02-github-single-repo.sh OWNER/REPO, then agent-run.sh from a project directory."
