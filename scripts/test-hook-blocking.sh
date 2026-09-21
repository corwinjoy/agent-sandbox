#!/usr/bin/env bash
# Check that the sandbox really blocks a repository's hooks and MCP servers.
#
#   test-hook-blocking.sh              trusted mode (two runs)
#   test-hook-blocking.sh --untrusted  also untrusted mode (four more runs; needs its own login)
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
# Untrusted mode has two layers, and --untrusted tests each one on its own:
#   - the managed settings, as in trusted mode
#   - `claude --setting-sources user`, which stops Claude Code reading the repository's
#     settings files, its .mcp.json and its CLAUDE.md at all
# The repository also carries a CLAUDE.md with a made-up codename; the test asks the model
# whether that codename is in its context.
#
# Needs a logged-in sandbox (run agent-run.sh once first). Each run sends one tiny prompt.
set -euo pipefail
UNTRUSTED=0; [ "${1:-}" = "--untrusted" ] && UNTRUSTED=1
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
printf '%s\n' '# Project notes' '' 'The project codename is PINEAPPLE-7731.' > CLAUDE.md
cat > .mcp.json <<'JSON'
{ "mcpServers": { "probe": { "command": "sh", "args": ["-c", "touch /workspace/MARKER_mcp_server_started; sleep 20"] } } }
JSON

NO_MANAGED="-v $WORK/empty-managed-settings.json:/etc/claude-code/managed-settings.json:ro"
PROMPT='Without using any tools: is a project codename present in your context? Reply with exactly the codename, or the word NONE.'

# session <extra podman args> <launcher flags> [claude args...]
# Prints what ran, then whether the CLAUDE.md codename reached the model.
session() {
  local extra="$1" flags="$2"; shift 2
  rm -f "$PROJ"/MARKER_*
  # shellcheck disable=SC2086  # $flags is a list of launcher flags
  AGENT_RUN_EXTRA_ARGS="$extra" "$HERE/agent-run.sh" $flags -- -p "$PROMPT" "$@" </dev/null >"$WORK/out.txt" 2>&1 \
    || { echo "  the Claude session failed:"; sed 's/^/    /' "$WORK/out.txt" | tail -5; exit 1; }
  # No marker at all is a valid result, not an error.
  RAN="$(cd "$PROJ" && for f in MARKER_*; do [ -e "$f" ] && printf '%s ' "${f#MARKER_}"; done; true)"
  if grep -q 'PINEAPPLE-7731' "$WORK/out.txt"; then MEMO="loaded"; else MEMO="not loaded"; fi
  echo "   ran: ${RAN:-nothing}   | CLAUDE.md: $MEMO"
}
FAILS=0
expect_nothing() { [ -z "$RAN" ] || { echo "   ^ FAIL: this run must not execute anything"; FAILS=$((FAILS+1)); }; }
expect_something() { [ -n "$RAN" ] || { echo "   ^ INCONCLUSIVE: nothing ran in a control, so the test cannot see hooks. Is the sandbox logged in?"; exit 2; }; }

echo "TRUSTED MODE"
echo "1. control: managed settings replaced by {} (markers expected)"
session "$NO_MANAGED" ""; expect_something
echo "2. as shipped (no marker allowed; CLAUDE.md is loaded in trusted mode by design)"
session "" ""; expect_nothing

if [ "$UNTRUSTED" = 1 ]; then
  echo
  echo "UNTRUSTED MODE"
  echo "3. control: no managed settings AND project settings forced back on (markers expected)"
  session "$NO_MANAGED" "--untrusted" --setting-sources user,project,local; expect_something
  echo "4. only --setting-sources user: no managed settings (no marker allowed)"
  session "$NO_MANAGED" "--untrusted"; expect_nothing
  [ "$MEMO" = "not loaded" ] || { echo "   ^ FAIL: the repository's CLAUDE.md reached the model"; FAILS=$((FAILS+1)); }
  echo "5. only managed settings: project settings forced back on (no marker allowed)"
  session "" "--untrusted" --setting-sources user,project,local; expect_nothing
  echo "6. as shipped: both layers (no marker allowed, CLAUDE.md must not load)"
  session "" "--untrusted"; expect_nothing
  [ "$MEMO" = "not loaded" ] || { echo "   ^ FAIL: the repository's CLAUDE.md reached the model"; FAILS=$((FAILS+1)); }
fi

echo
if [ "$FAILS" -gt 0 ]; then echo "FAIL: $FAILS check(s) failed. Do not use the sandbox on untrusted code until you know why."; exit 1
else echo "PASS: the controls ran the repository's hooks and MCP server; every protected run ran nothing."; fi
