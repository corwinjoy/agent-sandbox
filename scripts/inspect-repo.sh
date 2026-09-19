#!/usr/bin/env bash
# Look at what a repository would run BEFORE any agent or editor opens it.
#
#   inspect-repo.sh <git-url | existing-dir>
#
# With a URL it clones into ./untrusted/<name> with hooks, submodules and LFS smudge
# disabled. Nothing from the repository is executed. It then prints every file that an
# agent, an editor or a package manager would act on automatically.
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,8p' "$0"; exit 2; }

if [ -d "$1" ]; then
  DIR="$(cd "$1" && pwd)"
else
  NAME="$(basename "$1" .git)"; DIR="$PWD/untrusted/$NAME"
  mkdir -p "$(dirname "$DIR")"
  # hooksPath=/dev/null: no hook can fire. No submodules: they are more untrusted repos.
  # GIT_LFS_SKIP_SMUDGE: do not let LFS filters fetch or run during checkout.
  GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null -c protocol.file.allow=never \
      clone --no-recurse-submodules --depth 50 "$1" "$DIR"
fi
cd "$DIR"
hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
show() { for f in "$@"; do if [ -f "$f" ]; then printf '\n--- %s\n' "$f"; sed -n '1,80p' "$f"; fi; done; }
# Flags are counted in a temp file because several checks run in pipeline subshells.
FLAGFILE="$(mktemp)"; trap 'rm -f "$FLAGFILE"' EXIT
flag() { echo x >> "$FLAGFILE"; printf '  \033[31m[!]\033[0m %s\n' "$*"; }

hdr "Agent configuration committed to the repo"
find . -path ./.git -prune -o \( -path '*/.claude/*' -o -name .mcp.json -o -name CLAUDE.md \
     -o -name AGENTS.md -o -path '*/.cursor/*' -o -name .cursorrules -o -name GEMINI.md \
     -o -path '*/.github/copilot-instructions.md' \) -type f -print | sed 's/^/  /' || true
show .claude/settings.json .claude/settings.local.json .mcp.json
[ -f .claude/settings.local.json ] && flag "settings.local.json is committed (normally gitignored)"
for f in .claude/settings.json .claude/settings.local.json; do
  [ -f "$f" ] || continue
  jq -e '.hooks // empty | length > 0' "$f" >/dev/null 2>&1 && flag "$f defines hooks"
  jq -e '.env // empty | length > 0' "$f" >/dev/null 2>&1 && flag "$f sets environment variables: $(jq -c '.env' "$f")"
  jq -e '(.enableAllProjectMcpServers == true) or ((.enabledMcpjsonServers // []) | length > 0)' "$f" >/dev/null 2>&1 \
    && flag "$f pre-approves MCP servers"
  jq -e '.apiKeyHelper // .awsAuthRefresh // .awsCredentialExport // empty' "$f" >/dev/null 2>&1 && flag "$f sets a helper command"
  jq -e '(.permissions.allow // []) | length > 0' "$f" >/dev/null 2>&1 && flag "$f ships permission allow rules"
done
[ -f .mcp.json ] && flag ".mcp.json starts these commands: $(jq -c '[.mcpServers[]? | ([.command // .url] + (.args // []) | join(" "))]' .mcp.json 2>/dev/null)"

hdr "Editor auto-run"
show .vscode/tasks.json
grep -rls '"runOn"[[:space:]]*:[[:space:]]*"folderOpen"' .vscode 2>/dev/null | while read -r f; do flag "$f has a task that runs on folder open"; done || true
[ -d .devcontainer ] && { flag ".devcontainer present: postCreateCommand etc. run if you open it in a dev container"; show .devcontainer/devcontainer.json; }

hdr "Package manager lifecycle scripts"
find . -path ./.git -prune -o -path '*/node_modules' -prune -o -name package.json -type f -print | while read -r f; do
  S="$(jq -c '.scripts // {} | with_entries(select(.key | test("^(pre|post)?install$|^prepare$|^prepublish")))' "$f" 2>/dev/null)"
  if [ -n "$S" ] && [ "$S" != "{}" ]; then flag "$f: $S"; fi
done || true
[ -f setup.py ] && flag "setup.py runs arbitrary Python on 'pip install .'"
if [ -f .npmrc ]; then show .npmrc; fi
[ -f .gitmodules ] && { flag "submodules declared (not fetched)"; show .gitmodules; }

hdr "Suspicious patterns in agent and editor config"
SCAN=(); for p in .claude .mcp.json .vscode .cursor .devcontainer; do [ -e "$p" ] && SCAN+=("$p"); done
HITS=""
[ ${#SCAN[@]} -gt 0 ] && HITS="$(grep -rnIE 'curl |wget |nc |ncat |base64 (-d|--decode)|eval |/dev/tcp/|ANTHROPIC_BASE_URL|\.ssh/|id_rsa|AWS_SECRET' "${SCAN[@]}" 2>/dev/null | cut -c1-220 || true)"
if [ -n "$HITS" ]; then printf '%s\n' "$HITS" | sed 's/^/  /'; flag "$(printf '%s\n' "$HITS" | wc -l) suspicious line(s) above"
else echo "  none found"; fi

hdr "Hidden Unicode in instruction files (zero-width, bidi overrides, tag characters)"
find . -path ./.git -prune -o \( -name 'CLAUDE.md' -o -name 'AGENTS.md' -o -name '.cursorrules' -o -name '*.mdc' -o -name 'README*' \) -type f -print0 \
  | xargs -0 -r grep -lP '[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{E0000}-\x{E007F}]' 2>/dev/null \
  | while read -r f; do flag "$f contains invisible characters"; done || true

hdr "Summary"
echo "  $(wc -l < "$FLAGFILE") item(s) flagged in $DIR"
echo "  Read anything flagged. Then, if you still want an agent on it:"
echo "    cd $DIR && agent-run.sh --untrusted"
