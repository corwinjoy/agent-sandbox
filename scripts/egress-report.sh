#!/usr/bin/env bash
# Summarise what the egress proxy allowed and refused, per domain, from its access log.
#
#   egress-report.sh              the trusted-mode proxy (agent-proxy)
#   egress-report.sh --untrusted  the untrusted-mode proxy
#   egress-report.sh --audit      the audit proxy started by agent-run.sh --audit-egress
#   egress-report.sh ... --raw    print the log lines instead of the summary
#
# Use it to grow an allowlist the way you would grow a firewall rule set: run the task, look at
# what was refused (or, in audit mode, what was used), add the narrowest names that work, and
# run it again. In untrusted mode, inspected GitHub requests show as METHOD URL, so a refused
# push appears as "POST https://github.com/<owner>/<repo>.git/git-receive-pack".
set -uo pipefail
PROXY=agent-proxy RAW=0
for a in "$@"; do
  case "$a" in
    --untrusted) PROXY=agent-proxy-untrusted ;; --audit) PROXY=agent-proxy-audit ;; --raw) RAW=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;; *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
podman container exists "$PROXY" 2>/dev/null || { echo "no container named $PROXY; start a session first" >&2; exit 1; }
LOG="$(podman exec "$PROXY" cat /var/log/squid/access.log 2>/dev/null)" || { echo "could not read the log from $PROXY" >&2; exit 1; }
[ -n "$LOG" ] || { echo "the log of $PROXY is empty"; exit 0; }
if [ "$RAW" = 1 ]; then printf '%s\n' "$LOG"; exit 0; fi
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# Squid's native log: time elapsed client result/status bytes method URL ...
# For a tunnel the URL is host:port; for an inspected request it is the full URL.
# Squid's native log: time elapsed client result/status bytes method URL ...
# For a tunnel the URL is host:port; for an inspected request it is the full URL.
# (plain awk, no GNU extensions: the sorting is done by sort)
printf '%s\n' "$LOG" | awk '
  $6 == "-" || $7 ~ /^error:/ { next }                       # connections that ended before a request
  {
    split($4, rs, "/"); result = rs[1]; status = rs[2]; method = $6; url = $7
    host = url; sub(/^https?:\/\//, "", host); sub(/[:\/].*$/, "", host)
    verdict = (result == "TCP_DENIED") ? "REFUSED" : "allowed"  # refused by the proxy, or relayed
    if (method == "CONNECT") print "T", host, verdict
    else print "R", verdict, status, method, url
  }' > "$TMP"
printf '%-45s %8s %8s\n' "domain (tunnels)" "allowed" "refused"
awk '$1=="T"{ if ($3=="allowed") ok[$2]++; else no[$2]++; hosts[$2]=1 }
     END { for (h in hosts) printf "%s %d %d\n", h, ok[h]+0, no[h]+0 }' "$TMP" | sort | awk '{ printf "%-45s %8d %8d\n", $1, $2, $3 }'
if grep -q '^R ' "$TMP"; then
  printf '\n%5s  %-8s %-6s %s\n' "count" "proxy" "status" "inspected request (method URL)"
  awk '$1=="R"{ k=$2 " " $3 " " $4 " " $5; n[k]++ } END { for (k in n) print n[k], k }' "$TMP" | sort -k2,2 -k4,4 -k5,5 \
    | awk '{ printf "%5d  %-8s %-6s %s %s\n", $1, $2, $3, $4, $5 }'
  echo
  echo "proxy=REFUSED means the proxy blocked the request; status is what the upstream answered when it was relayed."
fi
echo
echo "Add the narrowest domain that works to ~/.config/agent-sandbox/allowed-domains*.txt, then: podman rm -f $PROXY"
