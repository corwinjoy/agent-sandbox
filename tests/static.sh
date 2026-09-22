#!/usr/bin/env bash
# Static checks: nothing is executed from the scripts under test.
#   syntax (bash -n), shellcheck, JSON validity, executable bits, and docs/check-docs.py.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1
mapfile -t SH < <(ls scripts/*.sh scripts/container/*.sh tests/*.sh)

section "bash syntax"
for f in "${SH[@]}"; do check "bash -n $f" bash -n "$f"; done

section "shellcheck (warning level)"
if command -v shellcheck >/dev/null; then
  for f in "${SH[@]}"; do check "shellcheck $f" shellcheck -S warning -x "$f"; done
elif command -v podman >/dev/null; then
  # No local shellcheck: use the official image. CI runners have shellcheck installed.
  for f in "${SH[@]}"; do
    check "shellcheck $f (container)" podman run --rm -v "$REPO":/mnt:ro -w /mnt docker.io/koalaman/shellcheck:stable -S warning -x "$f"
  done
else
  fail "shellcheck is not installed and podman is not available to run it"
fi

section "executable bits"
for f in scripts/*.sh scripts/container/check-github-token.sh scripts/container/proxy-entrypoint.sh tests/run-tests.sh; do check "$f is executable" test -x "$f"; done

section "JSON files"
check "managed-settings.json parses" jq -e . scripts/container/managed-settings.json
check "managed settings block repository hooks"       jq -e '.allowManagedHooksOnly == true' scripts/container/managed-settings.json
check "managed settings allow no MCP servers"         jq -e '.allowManagedMcpServersOnly == true and (.allowedMcpServers | length == 0)' scripts/container/managed-settings.json
check "managed settings deny 'gh pr merge'"           jq -e '.permissions.deny | index("Bash(gh pr merge *)")' scripts/container/managed-settings.json

section "allowlists"
check "allowlists contain only host names and comments" bash -c '! grep -vE "^\s*(#.*)?$" scripts/container/allowed-domains*.txt | grep -vE ":\.?[A-Za-z0-9.-]+$"'
check "squid denies by default" grep -q '^http_access deny all' scripts/container/squid.conf
check "squid refuses plain HTTP tunnels" grep -q '^http_access deny CONNECT !SSL_ports' scripts/container/squid.conf
check "squid refuses git push on inspected domains" grep -q '^http_access deny inspect_domains git_push' scripts/container/squid.conf
check "squid cuts tunnels whose TLS name is not listed" grep -q '^ssl_bump terminate !allowed_sni' scripts/container/squid.conf
check "inspected domains are exactly github.com and api.github.com" bash -c '[ "$(grep -v "^#" scripts/container/inspect-github.txt | sort | tr "\n" " ")" = "api.github.com github.com " ]'
check "the untrusted allowlist has no registry" bash -c '! grep -vE "^\s*#" scripts/container/allowed-domains-untrusted.txt | grep -qiE "npmjs|pypi|pythonhosted"'
check "enforce mode adds no rules" bash -c '! grep -vE "^\s*(#.*)?$" scripts/container/mode-enforce.conf | grep -q .'
check "proxy image runs as the proxy user" grep -q '^USER proxy' scripts/container/Containerfile.proxy

section "docs"
check "guide anchors, links and consistency with the scripts" python3 tests/check-docs.py
python3 tests/check-docs.py 2>&1 | grep -E 'BROKEN|MISMATCH|MISSING' | sed 's/^/        | /'

finish "static"
