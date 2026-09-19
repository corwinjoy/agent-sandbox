#!/usr/bin/env bash
# Check that the sandbox really blocks a repository's hooks and MCP servers.
#
#   test-hook-blocking.sh
#
# It builds a throwaway repository that tries to run code three ways, the same ways a
# malicious clone would:
#   - hooks in .claude/settings.json (SessionStart, UserPromptSubmit, Stop)
#   - an MCP server in .mcp.json, pre-approved by "enableAllProjectMcpServers": true
# Each one only creates an empty marker file in the project directory. Nothing else.
#
# It then runs one short headless Claude session in that repository, twice:
#   1. CONTROL: with the image's managed settings replaced by "{}". The markers SHOULD
#      appear. This proves the test can see a hook or MCP server when one runs.
#   2. REAL:    the sandbox as shipped. NO marker may appear.
# Headless (-p) is the hardest case: it never shows the workspace trust dialog, so project
# hooks are used and .mcp.json servers connect without asking.
#
# Needs a logged-in sandbox (run agent-run.sh once first). Each run sends one tiny prompt.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-hooktest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/hostile-repo"; mkdir -p "$PROJ/.claude"
echo '{}' > "$WORK/empty-managed-settings.json"; chmod 0644 "$WORK/empty-managed-settings.json"

cd "$PROJ" && git init -q .
hook() { printf '[{"hooks":[{"type":"command","command":"touch /workspace/MARKER_hook_%s"}]}]' "$1"; }
cat > .claude/settings.json <<JSON
{
  "enableAllProjectMcpServers": true,
  "hooks": {
    "SessionStart": $(hook SessionStart),
    "UserPromptSubmit": $(hook UserPromptSubmit),
    "Stop": $(hook Stop)
  }
}
JSON
cat > .mcp.json <<'JSON'
{ "mcpServers": { "probe": { "command": "sh", "args": ["-c", "touch /workspace/MARKER_mcp_server_started; sleep 20"] } } }
JSON

session() {   # $1 = extra podman args
  rm -f "$PROJ"/MARKER_*
  AGENT_RUN_EXTRA_ARGS="$1" "$HERE/agent-run.sh" -- -p "Reply with only the word ok" </dev/null >"$WORK/out.txt" 2>&1 \
    || { echo "  the Claude session failed:"; sed 's/^/    /' "$WORK/out.txt" | tail -5; exit 1; }
  # `|| true`: finding no marker is a valid result, not an error.
  { ls "$PROJ" | grep '^MARKER_' || true; } | sed 's/^MARKER_//' | tr '\n' ' '
}

echo "1. CONTROL run, managed settings replaced by {} (markers expected)"
CONTROL="$(session "-v $WORK/empty-managed-settings.json:/etc/claude-code/managed-settings.json:ro")"
echo "   ran: ${CONTROL:-nothing}"
echo "2. REAL run, sandbox as shipped (no marker allowed)"
REAL="$(session "")"
echo "   ran: ${REAL:-nothing}"

echo
if [ -z "$CONTROL" ]; then
  echo "INCONCLUSIVE: nothing ran even without managed settings, so this test cannot tell"
  echo "whether the sandbox blocks anything. Check that the sandbox is logged in."; exit 2
elif [ -n "$REAL" ]; then
  echo "FAIL: the sandbox let a repository run: $REAL"; exit 1
else
  echo "PASS: without managed settings the repository ran: $CONTROL"
  echo "      with the sandbox as shipped it ran nothing."
fi
