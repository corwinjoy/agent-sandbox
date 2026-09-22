#!/usr/bin/env bash
# Integration tests: real rootless Podman and the real images. Run 01-setup-podman.sh first.
# No Claude login, GitHub token, GPU or hardware perf counters are needed, so it runs in CI.
# What needs those (test-hook-blocking.sh, --check-token, --gpu, --perf) is tested by hand;
# see "Test status" in the guide.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export PATH="$SCRIPTS:$PATH"

section "what 01-setup-podman.sh should have left behind"
check "podman is rootless"                 bash -c '[ "$(podman info --format "{{.Host.Security.Rootless}}")" = true ]'
check "network backend is netavark"        bash -c '[ "$(podman info --format "{{.Host.NetworkBackend}}")" = netavark ]'
check "agent image exists"                 podman image exists localhost/agent-claude
check "proxy image exists"                 podman image exists localhost/agent-proxy
for net in agent-internal agent-untrusted; do
  check "network $net is internal"         bash -c "[ \"\$(podman network inspect $net --format '{{.Internal}}')\" = true ]"
  check "network $net has DNS disabled"    bash -c "[ \"\$(podman network inspect $net --format '{{.DNSEnabled}}')\" = false ]"
done
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox"
check "allowlists were copied"             test -s "$CFG/allowed-domains.txt" -a -s "$CFG/allowed-domains-untrusted.txt"
check "perf seccomp profile allows perf_event_open and no rule denies it" jq -e \
  '([.syscalls[] | select(.action=="SCMP_ACT_ALLOW" and (.includes|not) and (.names|index("perf_event_open")))] | length > 0)
   and ([.syscalls[] | select(.action=="SCMP_ACT_ERRNO" and (.names|index("perf_event_open")))] | length == 0)' "$CFG/seccomp-perf.json"
check "squid accepts its configuration (enforce)" bash -c "echo 'dns_nameservers 1.1.1.1' > '$CFG/ci-dns.conf' && podman run --rm -e PROXY_PARSE_ONLY=1 -v '$CFG/allowed-domains.txt':/etc/squid/allowed-domains.txt:ro -v '$CFG/ci-dns.conf':/etc/squid/dns.conf:ro localhost/agent-proxy"
check "squid accepts its configuration (audit, inspecting)" bash -c "podman run --rm -e PROXY_PARSE_ONLY=1 -e PROXY_MODE=audit -e PROXY_INSPECT=github -v '$CFG/allowed-domains-untrusted.txt':/etc/squid/allowed-domains.txt:ro -v '$CFG/ci-dns.conf':/etc/squid/dns.conf:ro localhost/agent-proxy"
check "the image carries the managed settings" bash -c "podman run --rm --entrypoint cat localhost/agent-claude /etc/claude-code/managed-settings.json | jq -e '.allowManagedHooksOnly == true'"
check "claude is installed in the image"   podman run --rm --entrypoint claude localhost/agent-claude --version

# A throwaway project with a git repository in it.
P="$(mktemp -d "${TMPDIR:-$HOME}/agent-itest.XXXXXX")"; trap 'podman rm -f agent-proxy agent-proxy-untrusted agent-proxy-audit >/dev/null 2>&1; rm -rf "$P"' EXIT
( cd "$P" && git init -q . && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init && echo hello > file.txt )

# in_sandbox <launcher flags> <<< commands   ->  OUT
in_sandbox() { OUT="$(cd "$P" && agent-run.sh --shell "$@" 2>&1)"; }
probe='
echo "ID=$(id -un):$(id -u)"
echo "OWNER=$(stat -c %U /workspace/file.txt)"
touch /workspace/written-by-agent && echo "WRITE=ok"
echo "CAPS=$(awk "/^CapEff/{print \$2}" /proc/self/status)"
echo "CAPBND=$(awk "/^CapBnd/{print \$2}" /proc/self/status)"
echo "NNP=$(awk "/^NoNewPrivs/{print \$2}" /proc/self/status)"
echo "HOMES=$(ls /home | tr "\n" " ")"
echo "ALLOWED=$(curl -sS -o /dev/null -m 30 -w "%{http_connect}" https://github.com/ 2>/dev/null)"
echo "DENIED=$(curl -sS -o /dev/null -m 30 https://example.com/ 2>&1 | grep -c "reset by peer")"
echo "DIRECT=$(curl --noproxy "*" -sS -o /dev/null -m 8 -w "%{http_code}" https://1.1.1.1/ 2>/dev/null)"
echo "DNS=$(getent hosts example.com >/dev/null 2>&1 && echo resolves || echo fails)"
echo "HOOKWRITE=$( (echo x > /workspace/.git/hooks/pre-commit) 2>&1 | grep -c "Read-only")"
echo "HOOKSPATH=$(git config --system core.hooksPath)"
echo "GHISSUER=$(echo | openssl s_client -proxy ${HTTPS_PROXY#http://} -connect github.com:443 -servername github.com 2>/dev/null | openssl x509 -noout -issuer | grep -c "agent-sandbox egress proxy CA")"
echo "CAENV=${SSL_CERT_FILE:-unset}"
git -C /workspace config core.hooksPath /workspace/.evil
exit 5
'
section "trusted mode, in a real container"
in_sandbox <<< "$probe"
has "runs as the agent user"                        "ID=agent:1000" "$OUT"
has "project files look owned by the agent inside"  "OWNER=agent" "$OUT"
has "the project is writable"                       "WRITE=ok" "$OUT"
check "files written inside are yours on the host"  test -O "$P/written-by-agent"
has "no effective capabilities"                     "CAPS=0000000000000000" "$OUT"
# A non-root user has no effective capabilities anyway. The bounding set is what --cap-drop=ALL
# empties: with it at zero, nothing in the container can ever acquire a capability.
has "empty capability bounding set (--cap-drop=ALL)" "CAPBND=0000000000000000" "$OUT"
has "no-new-privileges is set"                      "NNP=1" "$OUT"
has "only the agent home exists: the host home is not visible" "HOMES=agent " "$OUT"
has "an allowlisted domain connects through the proxy"         "ALLOWED=200" "$OUT"
has "a domain off the list gets its tunnel reset by the proxy"  "DENIED=1" "$OUT"
has "there is no direct route out"                             "DIRECT=000" "$OUT"
has "outside names do not resolve"                             "DNS=fails" "$OUT"
has "the hooks directory is read-only"                         "HOOKWRITE=1" "$OUT"
check_not "no hook reached the host"                           test -e "$P/.git/hooks/pre-commit"
has "hooks are off inside the container"                       "HOOKSPATH=/dev/null" "$OUT"
has "a planted core.hooksPath is reported afterwards"          "WARNING" "$OUT"
has "and the offending line is shown"                          "hooksPath = /workspace/.evil" "$OUT"
has "GitHub is not inspected in trusted mode: real issuer"     "GHISSUER=0" "$OUT"
has "no proxy CA is pushed into trusted sessions"              "CAENV=unset" "$OUT"

section "untrusted mode, in a real container: read-only GitHub"
in_sandbox --untrusted <<'EOF'
u=https://github.com/octocat/Hello-World.git
echo "ANTHROPIC=$(curl -sS -o /dev/null -m 30 -w "%{http_connect}" https://api.anthropic.com/ 2>/dev/null)"
echo "TOKEN=${GH_TOKEN:-none}"
echo "CAFILES=$(ls /etc/agent-sandbox/ca | sort | tr "\n" " ")"
echo "GHISSUER=$(echo | openssl s_client -proxy ${HTTPS_PROXY#http://} -connect github.com:443 -servername github.com 2>/dev/null | openssl x509 -noout -issuer | grep -c "agent-sandbox egress proxy CA")"
echo "LSREMOTE=$(git ls-remote $u HEAD 2>/dev/null | grep -c HEAD)"
cd /tmp && git clone -q --depth 1 $u hw 2>/dev/null && echo "CLONE=ok" && cd hw && git -c user.email=t@x -c user.name=t commit -q --allow-empty -m x
echo "FETCH=$(git fetch -q origin 2>&1 && echo ok)"
echo "PUSH=$(git -c credential.helper="!f(){ echo username=x; echo password=y; }; f" push origin HEAD:refs/heads/probe 2>&1 | grep -o "returned error: 403")"
echo "APIGET=$(curl -sS -o /dev/null -m 30 -w "%{http_code}" https://api.github.com/repos/octocat/Hello-World)"
echo "APIPOST=$(curl -sS -o /dev/null -m 30 -w "%{http_code}" -X POST -d "{}" https://api.github.com/gists)"
echo "APIPUT=$(curl -sS -o /dev/null -m 30 -w "%{http_code}" -X PUT -d "{}" https://api.github.com/repos/o/r/contents/x)"
echo "RECV=$(curl -sS -o /dev/null -m 30 -w "%{http_code}" -X POST $u/git-receive-pack)"
echo "PYPI=$(curl -sS -o /dev/null -m 20 https://pypi.org/ 2>&1 | grep -c "reset by peer")"
exit
EOF
has "the model API connects"                          "ANTHROPIC=200" "$OUT"
has "no token in the environment"                     "TOKEN=none" "$OUT"
has "the proxy CA is mounted"                         "CAFILES=ca-bundle.pem ca.pem " "$OUT"
has "GitHub is inspected: the proxy's own CA"         "GHISSUER=1" "$OUT"
has "git ls-remote works"                             "LSREMOTE=1" "$OUT"
has "git clone works"                                 "CLONE=ok" "$OUT"
has "git fetch works"                                 "FETCH=ok" "$OUT"
has "git push is refused by the proxy (403)"          "PUSH=returned error: 403" "$OUT"
has "API reads work"                                  "APIGET=200" "$OUT"
has "API POST is refused"                             "APIPOST=403" "$OUT"
has "API PUT is refused"                              "APIPUT=403" "$OUT"
has "the receive-pack upload is refused"              "RECV=403" "$OUT"
has "a registry is still unreachable"                 "PYPI=1" "$OUT"

section "audit mode, in a real container"
in_sandbox --audit-egress <<'EOF'
echo "EXAMPLE=$(curl -sS -o /dev/null -m 30 -w "%{http_connect}/%{http_code}" https://example.com/ 2>/dev/null)"
echo "PLAIN=$(curl -sS -o /dev/null -m 20 -w "%{http_code}" http://example.com/ 2>/dev/null)"
exit
EOF
has "warns that audit mode is on"                     "AUDIT MODE" "$OUT"
has "an unlisted HTTPS domain is allowed and answered" "EXAMPLE=200/200" "$OUT"
has "plain HTTP is still refused"                     "PLAIN=403" "$OUT"
REPORT="$(egress-report.sh --audit 2>&1)"
has "egress-report.sh lists the domain"               "example.com" "$REPORT"
REPORT="$(egress-report.sh --untrusted 2>&1)"
has "egress-report.sh shows the refused push"         "REFUSED  403    POST https://github.com/octocat/Hello-World.git/git-receive-pack" "$REPORT"
has "egress-report.sh shows the allowed fetch"        "allowed  200    POST https://github.com/octocat/Hello-World.git/git-upload-pack" "$REPORT"

section "launcher behaviour with real podman"
( cd "$P" && agent-run.sh --shell <<< 'exit 5' >/dev/null 2>&1 ); eq "the session's exit code is passed on" 5 "$?"
( cd "$P" && agent-run.sh --check-token >/dev/null 2>&1 );        eq "--check-token without a stored token exits 1" 1 "$?"
( cd "$P" && agent-run.sh --untrusted --gpu >/dev/null 2>&1 );    eq "--untrusted --gpu is refused" 2 "$?"

finish "integration"
