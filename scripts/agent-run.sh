#!/usr/bin/env bash
# Launch Claude Code inside the rootless Podman sandbox, on the current directory.
#
#   agent-run.sh [--gpu] [--perf] [--gvisor] [--untrusted] [--shell] [-- claude args...]
#
#   --gpu        expose the NVIDIA GPU through CDI (adds the NVIDIA driver to the attack surface)
#   --perf       allow perf_event_open so `perf stat` sees hardware counters
#   --gvisor     run under gVisor (runsc must be installed and registered; no perf counters)
#   --untrusted  for repos you have not reviewed: no GitHub token, no GPU, model-API-only
#                network, separate Claude state, project hooks/MCP/skills not loaded
#   --shell      start bash instead of claude (to look around or log in)
#
# The project directory is the only host path the container sees.
set -euo pipefail

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox"
GPU=0 PERF=0 GVISOR=0 UNTRUSTED=0 SHELL_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu) GPU=1 ;; --perf) PERF=1 ;; --gvisor) GVISOR=1 ;;
    --untrusted) UNTRUSTED=1 ;; --shell) SHELL_MODE=1 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- mode-dependent names -------------------------------------------------------------
if [ "$UNTRUSTED" = 1 ]; then
  NET=agent-untrusted  PROXY=agent-proxy-untrusted  ALLOW="$CFG_DIR/allowed-domains-untrusted.txt"
  HOME_VOL=agent-claude-home-untrusted      # never shares state with trusted sessions
  [ "$GPU" = 1 ] && { echo "--gpu is refused with --untrusted (see Appendix A)"; exit 2; }
else
  NET=agent-internal   PROXY=agent-proxy            ALLOW="$CFG_DIR/allowed-domains.txt"
  HOME_VOL=agent-claude-home
fi

# ---- egress proxy: start it if it is not already running --------------------------------
if ! podman container exists "$PROXY" || [ "$(podman inspect -f '{{.State.Running}}' "$PROXY")" != true ]; then
  podman rm -f "$PROXY" >/dev/null 2>&1 || true
  # Attached to the internal network (where the agent lives) and to the default
  # network (the way out). The allowlist is mounted read-only.
  podman run -d --name "$PROXY" --network "$NET" --network podman \
    --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --security-opt=no-new-privileges \
    -v "$ALLOW":/etc/squid/allowed-domains.txt:ro \
    localhost/agent-proxy >/dev/null
fi
PROXY_URL="http://$PROXY:3128"

# ---- assemble the agent container ------------------------------------------------------
ARGS=(
  --rm -it
  --name "agent-$(printf '%s' "$(basename "$PWD")" | tr -c 'a-zA-Z0-9_.-' '-')-$$"
  --network "$NET"                       # internal network: no route out except the proxy
  --userns=keep-id:uid=1000,gid=1000     # you on the host == 'agent' in the container
  --cap-drop=ALL                         # no Linux capabilities at all
  --security-opt=no-new-privileges       # setuid binaries cannot raise privileges
  --pids-limit=2048 --memory=16g         # a runaway process cannot take the host down
  -v "$PWD":/workspace:rw                # the only host path in the container (add ,Z on SELinux hosts)
  -v "$HOME_VOL":/home/agent/.claude     # Claude login and state, kept between runs
  --tmpfs /tmp:rw,exec,size=4g
  -e HTTPS_PROXY="$PROXY_URL" -e HTTP_PROXY="$PROXY_URL"
  -e https_proxy="$PROXY_URL" -e http_proxy="$PROXY_URL"
  -e NO_PROXY=localhost,127.0.0.1
)

[ "$GPU" = 1 ]    && ARGS+=( --device nvidia.com/gpu=all )
[ "$GVISOR" = 1 ] && ARGS+=( --runtime=runsc )
if [ "$PERF" = 1 ]; then
  [ -r "$CFG_DIR/seccomp-perf.json" ] || { echo "run 01-setup-podman.sh first"; exit 1; }
  ARGS+=( --security-opt "seccomp=$CFG_DIR/seccomp-perf.json" )
fi

# GitHub token: attach the per-repo secret made by 02-github-single-repo.sh, if one exists
# for this checkout's origin. Never in untrusted mode.
if [ "$UNTRUSTED" = 0 ] && ORIGIN="$(git -C "$PWD" remote get-url origin 2>/dev/null)"; then
  SLUG="$(printf '%s' "$ORIGIN" | sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##')"
  SECRET="gh-$(printf '%s' "$SLUG" | tr '/' '-' | tr -c 'a-zA-Z0-9_.-' '-')"
  if podman secret exists "$SECRET" 2>/dev/null; then
    ARGS+=( --secret "$SECRET,type=env,target=GH_TOKEN" )
    echo "GitHub token attached for $SLUG"
  else
    echo "No GitHub token for $SLUG (pushes will fail). Create one with 02-github-single-repo.sh $SLUG"
  fi
fi

if [ "$SHELL_MODE" = 1 ]; then
  exec podman run "${ARGS[@]}" --entrypoint /bin/bash localhost/agent-claude
elif [ "$UNTRUSTED" = 1 ]; then
  # --setting-sources user: do not read the repo's .claude/settings*.json or .mcp.json.
  # Managed settings in the image already block hooks and MCP servers from every source.
  exec podman run "${ARGS[@]}" localhost/agent-claude --setting-sources user "$@"
else
  exec podman run "${ARGS[@]}" localhost/agent-claude "$@"
fi
