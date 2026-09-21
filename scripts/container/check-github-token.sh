#!/usr/bin/env bash
# Runs INSIDE the sandbox (agent-run.sh --check-token mounts and starts it).
# Checks that the GitHub token attached to this session can do what it should on the target
# repository and nothing anywhere else. It never prints the token and changes nothing on
# GitHub: every probe is a read, or asks git's smart-HTTP endpoint "may I push?" without pushing.
#
#   $AGENT_REPO_SLUG   OWNER/REPO the token was made for (set by the launcher from `origin`)
#   arguments          optional extra OWNER/REPO names that the token must NOT be able to write
set -uo pipefail
TARGET="${AGENT_REPO_SLUG:?AGENT_REPO_SLUG is not set}"
FAILS=0 WARNS=0
pass() { printf '  [pass] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
warn() { printf '  [warn] %s\n' "$*"; WARNS=$((WARNS+1)); }
# HTTP status of git's read (upload-pack) or write (receive-pack) endpoint for a repo.
# GitHub answers 200 only if this credential may do that operation. Nothing is transferred.
git_probe() { curl -sS -o /dev/null -m 25 -w '%{http_code}' -u "x-access-token:$GH_TOKEN" \
                   "https://github.com/$1.git/info/refs?service=git-$2" 2>/dev/null || echo 000; }

echo "Token check for $TARGET"
echo
echo "1. The token itself"
case "${GH_TOKEN:-}" in
  "")           fail "no token is attached to this session"; echo; echo "RESULT: FAIL"; exit 1 ;;
  github_pat_*) pass "fine-grained token" ;;
  ghp_*)        fail "classic token: it cannot be limited to one repository" ;;
  *)            warn "unrecognised token format" ;;
esac
EXP="$(gh api -i "repos/$TARGET" 2>/dev/null | grep -i '^github-authentication-token-expiration:' | cut -d' ' -f2- | tr -d '\r')"
if [ -n "$EXP" ]; then pass "expires $EXP"; else warn "no expiry date. Prefer a token that expires"; fi

echo
echo "2. What it can do on $TARGET"
INFO="$(gh api "repos/$TARGET" --jq '"\(.visibility) repository"' 2>/dev/null)" \
  && pass "API can read it ($INFO)" || fail "API cannot read it. Was this repository selected when the token was created?"
[ "$(git_probe "$TARGET" upload-pack)"  = 200 ] && pass "git can fetch"  || fail "git cannot fetch"
[ "$(git_probe "$TARGET" receive-pack)" = 200 ] && pass "git can push (Contents: write)" \
  || warn "git cannot push: the token is read-only here (Contents is not 'Read and write')"

echo
echo "3. What it can reach elsewhere"
echo "   Note: any token, and no token at all, can READ public repositories. That is normal."
echo "   What must not happen: reading another PRIVATE repository, or WRITING anywhere else."
PRIVATE_OTHERS="$(gh api 'user/repos?per_page=100&visibility=private' --paginate --jq '.[].full_name' 2>/dev/null | grep -vxF "$TARGET" || true)"
if [ -z "$PRIVATE_OTHERS" ]; then pass "no other private repository is visible to the token"
else fail "the token can see $(printf '%s\n' "$PRIVATE_OTHERS" | wc -l) other private repositories, for example: $(printf '%s\n' "$PRIVATE_OTHERS" | head -n 3 | tr '\n' ' ')"; fi

# Write probes: the repositories you named, plus up to three others the token can list.
LISTED="$(gh api 'user/repos?per_page=100' --jq '.[].full_name' 2>/dev/null | grep -vxF "$TARGET" | head -n 3 || true)"
# shellcheck disable=SC2086  # $LISTED is a whitespace-separated list, split on purpose
CANARIES="$(printf '%s\n' "$@" $LISTED | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' | awk '!seen[$0]++' || true)"
if [ -z "$CANARIES" ]; then warn "no other repository to probe. Name one: agent-run.sh --check-token -- OWNER/OTHER"; fi
for r in $CANARIES; do
  CODE="$(git_probe "$r" receive-pack)"
  case "$CODE" in
    200) fail "the token CAN PUSH to $r" ;;
    000) warn "could not reach $r (network or proxy problem), so no verdict" ;;
    *)   pass "cannot push to $r (HTTP $CODE)" ;;
  esac
done

echo
if [ "$FAILS" -gt 0 ]; then echo "RESULT: FAIL ($FAILS problem(s)). Delete the token on GitHub and re-run 02-github-single-repo.sh."; exit 1
elif [ "$WARNS" -gt 0 ]; then echo "RESULT: PASS with $WARNS warning(s)"; exit 0
else echo "RESULT: PASS"; fi
