#!/usr/bin/env bash
# Launch Claude Code inside the rootless Podman sandbox, on the current directory.
#
#   agent-run.sh [--gpu] [--perf] [--ask] [--untrusted] [--shell] [--gvisor] [-- claude args...]
#
#   --gpu        expose the NVIDIA GPU through CDI (adds the NVIDIA driver to the attack surface)
#   --perf       allow perf_event_open so `perf stat` sees hardware counters
#   --gvisor     EXPERIMENTAL: run under gVisor (runsc installed and registered with Podman).
#                CPU only: no --gpu (rootless gVisor GPU support is broken upstream), no --perf
#   --ask        start Claude Code in manual permission mode (it asks before each action).
#                The default in the sandbox is auto mode: a safety classifier approves routine
#                actions, and the container is the backstop. Managed deny and ask rules
#                (no merge, prompt on force-push) apply in both modes.
#   --untrusted  for repos you have not reviewed: no GitHub token, no GPU, model-API-only
#                network, separate Claude state, project hooks/MCP/skills not loaded,
#                and always manual permission mode
#   --shell      start bash instead of claude (to look around or log in)
#   --check-token  check the GitHub token attached for this checkout: what it can do on this
#                repository, and that it can write nowhere else. The repository comes from
#                `origin`. Extra repositories to probe go after --:
#                  agent-run.sh --check-token -- OWNER/OTHER
#
# The project directory is the only host path the container sees.
#
# AGENT_RUN_EXTRA_ARGS="..."  extra `podman run` options, for example one more read-only
#                             mount. Anything you add here can weaken the sandbox.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox"
GPU=0 PERF=0 GVISOR=0 UNTRUSTED=0 SHELL_MODE=0 ASK=0 CHECK_TOKEN=0 TOKEN_ATTACHED=0 SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu) GPU=1 ;; --perf) PERF=1 ;; --gvisor) GVISOR=1 ;;
    --untrusted) UNTRUSTED=1 ;; --shell) SHELL_MODE=1 ;; --ask) ASK=1 ;;
    --check-token) CHECK_TOKEN=1 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- mode-dependent names -------------------------------------------------------------
if [ "$UNTRUSTED" = 1 ]; then
  NET=agent-untrusted  PROXY=agent-proxy-untrusted  ALLOW="$CFG_DIR/allowed-domains-untrusted.txt"
  HOME_VOL=agent-claude-home-untrusted      # never shares state with trusted sessions
  [ "$GPU" = 1 ] && { echo "--gpu is refused with --untrusted (see Appendix A of the guide)"; exit 2; }
else
  NET=agent-internal   PROXY=agent-proxy            ALLOW="$CFG_DIR/allowed-domains.txt"
  HOME_VOL=agent-claude-home
fi

if [ "$CHECK_TOKEN" = 1 ] && [ "$UNTRUSTED" = 1 ]; then
  echo "--check-token makes no sense with --untrusted: untrusted sessions never get a token"; exit 2
fi
if [ "$GVISOR" = 1 ] && { [ "$GPU" = 1 ] || [ "$PERF" = 1 ]; }; then
  echo "--gvisor cannot be combined with --gpu or --perf (see Appendix A of the guide)"; exit 2
fi

# ---- egress proxy: start it if it is not already running --------------------------------
# DNS servers for the proxy: the host's real upstream resolvers (not the 127.0.0.53 stub,
# which a container cannot reach). Falls back to public resolvers.
write_proxy_dns() {
  local servers
  servers="$(awk '/^nameserver/{print $2}' /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null \
             | grep -Ev '^(127\.|::1$)|%' | awk '!seen[$0]++' | head -n 3 | tr '\n' ' ')"
  [ -n "${servers// /}" ] || servers="1.1.1.1 9.9.9.9"
  echo "dns_nameservers $servers" > "$CFG_DIR/squid-dns.conf"
}
if ! podman container exists "$PROXY" || [ "$(podman inspect -f '{{.State.Running}}' "$PROXY")" != true ]; then
  podman rm -f "$PROXY" >/dev/null 2>&1 || true
  write_proxy_dns
  # Attached to the internal network (where the agent lives) and to the default
  # network (the way out). The allowlist is mounted read-only.
  podman run -d --name "$PROXY" --network "$NET" --network podman \
    --cap-drop=ALL --cap-add=SETUID --cap-add=SETGID --security-opt=no-new-privileges \
    -v "$ALLOW":/etc/squid/allowed-domains.txt:ro \
    -v "$CFG_DIR/squid-dns.conf":/etc/squid/dns.conf:ro \
    localhost/agent-proxy >/dev/null
fi
# The agent reaches the proxy by IP address. DNS is switched off on the internal network so
# that the agent cannot resolve outside names at all (no DNS tunnelling).
PROXY_IP="$(podman inspect "$PROXY" --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")"
[ -n "$PROXY_IP" ] || { echo "could not find the proxy's address on $NET; see: podman logs $PROXY" >&2; exit 1; }
# Wait (up to ~10 s) until squid accepts connections.
for _ in $(seq 1 20); do
  podman exec "$PROXY" bash -c 'exec 3<>/dev/tcp/127.0.0.1/3128' 2>/dev/null && break
  sleep 0.5
done
PROXY_URL="http://$PROXY_IP:3128"

# ---- assemble the agent container ------------------------------------------------------
# A terminal only when there is one, so that headless use works from scripts and pipelines:
#   agent-run.sh -- -p "summarise this repo" > out.txt
if [ -t 0 ] && [ -t 1 ]; then TTY=(-it); else TTY=(-i); fi
ARGS=(
  --rm "${TTY[@]}"
  --name "agent-$(printf '%s' "$(basename "$PWD")" | tr -c 'a-zA-Z0-9_.-' '-')-$$"
  --network "$NET"                       # internal network: no route out except the proxy
  --dns none                             # no resolver at all: lookups fail at once, the proxy resolves
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

# shellcheck disable=SC2206  # word splitting is intended here
[ -n "${AGENT_RUN_EXTRA_ARGS:-}" ] && ARGS+=( $AGENT_RUN_EXTRA_ARGS )
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
  if podman secret inspect "$SECRET" >/dev/null 2>&1; then
    ARGS+=( --secret "$SECRET,type=env,target=GH_TOKEN" )
    TOKEN_ATTACHED=1
    echo "GitHub token attached for $SLUG"
  else
    echo "No GitHub token for $SLUG (pushes will fail). Create one with 02-github-single-repo.sh $SLUG"
  fi
fi

# Permission mode. The launcher sets it per trust level instead of relying on a settings file,
# because trusted and untrusted sessions keep their settings in different volumes. It comes
# first on the command line, so a --permission-mode you pass after -- takes precedence.
#   trusted:   auto. Fewer prompts; the container, the proxy and the single-repo token limit
#              what a wrongly approved action can do.
#   untrusted: manual. Unreviewed code is where prompt injection is likeliest, and a
#              classifier judges whether an action fits the request, which is what an
#              injection attacks.
if [ "$UNTRUSTED" = 1 ] || [ "$ASK" = 1 ]; then MODE=manual; else MODE=auto; fi

if [ "$CHECK_TOKEN" = 1 ]; then
  [ "$TOKEN_ATTACHED" = 1 ] || { echo "Nothing to check: no token is stored for this checkout's origin (${SLUG:-no GitHub origin found})." >&2; exit 1; }
  # The check script is mounted read-only from this directory, so it needs no image rebuild.
  exec podman run "${ARGS[@]}" -e AGENT_REPO_SLUG="$SLUG" \
    -v "$HERE/container/check-github-token.sh":/usr/local/bin/check-github-token:ro \
    --entrypoint /bin/bash localhost/agent-claude /usr/local/bin/check-github-token "$@"
elif [ "$SHELL_MODE" = 1 ]; then
  exec podman run "${ARGS[@]}" --entrypoint /bin/bash localhost/agent-claude
elif [ "$UNTRUSTED" = 1 ]; then
  # --setting-sources user: do not read the repo's .claude/settings*.json or .mcp.json.
  # Managed settings in the image already block hooks and MCP servers from every source.
  exec podman run "${ARGS[@]}" localhost/agent-claude --permission-mode "$MODE" --setting-sources user "$@"
else
  exec podman run "${ARGS[@]}" localhost/agent-claude --permission-mode "$MODE" "$@"
fi
