#!/usr/bin/env bash
# Stage 2: give the agent a GitHub credential that works on ONE repository only.
#
#   02-github-single-repo.sh OWNER/REPO [--expires-days N] [--canary OWNER/OTHER] [--protect-default-branch]
#
# The token is a fine-grained personal access token with exactly these repository permissions:
#   Contents: read/write        clone, fetch, commit, push
#   Issues: read/write          read issues, add comments
#   Pull requests: read/write   open pull requests, add comments and review comments
#   Metadata: read              added by GitHub automatically
# It cannot touch any other repository, change settings, secrets or webhooks, or edit
# .github/workflows (that needs the separate Workflows permission, which we leave off).
#
# GitHub has no API for creating fine-grained tokens, so the script opens the creation page
# with everything pre-filled except the repository picker. You click three things, paste the
# token back here, and the script verifies it and stores it as a Podman secret. The token is
# never shown on screen or put in the project. Podman's default secret store is a file under
# ~/.local/share/containers/storage/secrets: base64-encoded, NOT encrypted, readable only by
# your user. 03-claude-settings.sh blocks host-side agent sessions from reading it.
set -euo pipefail

usage() { sed -n '2,19p' "$0"; exit "${1:-0}"; }
[ $# -ge 1 ] || usage 2
REPO_SLUG="$1"; shift
EXPIRES=30 CANARY="" PROTECT=0
# An option that takes a value must be followed by one (and not by another option).
need_arg() { [ $# -ge 2 ] && [ "${2#--}" = "$2" ] || { echo "option $1 needs a value" >&2; usage 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --expires-days) need_arg "$@"; EXPIRES="$2"; shift ;;
    --canary) need_arg "$@"; CANARY="$2"; shift ;;
    --protect-default-branch) PROTECT=1 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done
[[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "expected OWNER/REPO" >&2; exit 2; }
# GitHub accepts 1-366 days for expires_in.
{ [[ "$EXPIRES" =~ ^[0-9]+$ ]] && [ "$EXPIRES" -ge 1 ] && [ "$EXPIRES" -le 366 ]; } \
  || { echo "--expires-days must be a whole number from 1 to 366" >&2; exit 2; }
[ -z "$CANARY" ] || [[ "$CANARY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "--canary expects OWNER/REPO" >&2; exit 2; }
OWNER="${REPO_SLUG%%/*}"  REPO="${REPO_SLUG##*/}"
SECRET="gh-$(printf '%s' "$REPO_SLUG" | tr '/' '-' | tr -c 'a-zA-Z0-9_.-' '-')"   # must match agent-run.sh
API=https://api.github.com
for dep in curl jq podman; do command -v "$dep" >/dev/null || { echo "missing: $dep" >&2; exit 1; }; done

# ---------------------------------------------------------------- 1. pre-filled creation page
# Documented URL parameters: name (max 40 chars), description, target_name (resource owner),
# expires_in (days), and one parameter per permission set to read|write|admin.
NAME="$(printf 'agent-%s' "$REPO" | cut -c1-40)"
URL="https://github.com/settings/personal-access-tokens/new"
URL+="?name=$NAME"
URL+="&description=Coding+agent%3A+single+repo+$OWNER%2F$REPO"
URL+="&target_name=$OWNER"            # personal account or organization that owns the repo
URL+="&expires_in=$EXPIRES"           # short-lived on purpose; re-run this script to rotate
URL+="&contents=write"                # commit and push
URL+="&issues=write"                  # comment on issues
URL+="&pull_requests=write"           # open PRs, comment on PRs

cat <<EOF

1. Open this page (trying to open it in your browser now):

   $URL

2. Under "Repository access" choose "Only select repositories" and pick ONLY:  $REPO_SLUG
   This is the one field the link cannot pre-fill, and it is the one that matters most.
3. Check the permissions list shows Contents, Issues and Pull requests as "Read and write",
   Metadata as "Read-only", and nothing else.
4. Click "Generate token" and copy it.

EOF
command -v xdg-open >/dev/null && xdg-open "$URL" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 2. read the token (no echo)
read -rsp "Paste the token here (input hidden): " TOKEN; echo
case "$TOKEN" in
  github_pat_*) ;;                                   # fine-grained tokens start with this
  ghp_*) echo "That is a CLASSIC token: it cannot be limited to one repository. Refusing." >&2; exit 1 ;;
  *) echo "That does not look like a fine-grained token (expected github_pat_...)." >&2; exit 1 ;;
esac
gh_api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

# ---------------------------------------------------------------- 3. verify
echo "Verifying..."
# 3a. The target repository must be reachable. -D writes response headers so we can read the expiry.
HDRS="$(mktemp)"; trap 'rm -f "$HDRS"' EXIT
CODE="$(gh_api -o /dev/null -D "$HDRS" -w '%{http_code}' "$API/repos/$REPO_SLUG")"
[ "$CODE" = 200 ] || { echo "  FAIL: token cannot read $REPO_SLUG (HTTP $CODE). Was the repository selected?" >&2; exit 1; }
echo "  ok: can read $REPO_SLUG"
EXP="$(grep -i '^github-authentication-token-expiration:' "$HDRS" | cut -d' ' -f2- | tr -d '\r' || true)"
[ -n "$EXP" ] && echo "  ok: expires $EXP" || echo "  WARN: token has no expiry. Prefer one that expires."

# 3b. It must NOT reach anything else. Heuristic: list private repos the token can see.
OTHERS="$(gh_api "$API/user/repos?per_page=100&visibility=private" \
          | jq -r --arg t "$REPO_SLUG" '[.[]? | .full_name | select(. != $t)] | length' 2>/dev/null || echo "?")"
case "$OTHERS" in
  0) echo "  ok: no other private repositories visible to this token" ;;
  \?) echo "  note: could not list repositories (that is fine for a single-repo token)" ;;
  *) echo "  FAIL: token can see $OTHERS other private repositories. Recreate it with only $REPO_SLUG selected." >&2; exit 1 ;;
esac
# 3c. Optional explicit check against a private repo you name: it must come back 404.
if [ -n "$CANARY" ]; then
  CCODE="$(gh_api -o /dev/null -w '%{http_code}' "$API/repos/$CANARY")"
  [ "$CCODE" = 404 ] && echo "  ok: $CANARY is invisible to the token (404)" \
    || { echo "  FAIL: token can reach $CANARY (HTTP $CCODE)" >&2; exit 1; }
fi

# ---------------------------------------------------------------- 4. store as a Podman secret
# agent-run.sh injects it as GH_TOKEN only into containers started on a checkout of this repo.
podman secret rm "$SECRET" >/dev/null 2>&1 || true
printf '%s' "$TOKEN" | podman secret create "$SECRET" - >/dev/null
unset TOKEN
echo "Stored as Podman secret '$SECRET'."

# ---------------------------------------------------------------- 5. optional: protect the default branch
# Uses YOUR gh login on the host (needs admin on the repo), never the agent's token.
# The ruleset stops force-pushes to, deletion of, and direct pushes to the default branch,
# so the agent's work arrives as pull requests. Rulesets on private repos need a paid plan.
if [ "$PROTECT" = 1 ]; then
  if ! command -v gh >/dev/null; then
    echo "gh CLI not found; skipping branch protection" >&2
  elif gh api "repos/$REPO_SLUG/rulesets" --jq '.[].name' 2>/dev/null | grep -qx agent-guard-default-branch; then
    echo "Ruleset 'agent-guard-default-branch' already exists."
  else
    gh api -X POST "repos/$REPO_SLUG/rulesets" --input - >/dev/null <<'JSON'
{
  "name": "agent-guard-default-branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      } }
  ]
}
JSON
    echo "Ruleset 'agent-guard-default-branch' created."
  fi
fi

cat <<EOF

Done.
  Check it:   cd <checkout of $REPO_SLUG> && agent-run.sh --check-token
  Use it:     cd <checkout of $REPO_SLUG> && agent-run.sh
  Rotate:     re-run this script (the old secret is replaced)
  Revoke:     https://github.com/settings/personal-access-tokens  and  podman secret rm $SECRET
EOF
