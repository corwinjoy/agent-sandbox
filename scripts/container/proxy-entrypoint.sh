#!/usr/bin/env bash
# Prepares and starts the egress proxy.
#   PROXY_MODE     enforce (default) | audit     audit allows every HTTPS tunnel and only logs it
#   PROXY_INSPECT  none (default) | github       which domains get TLS inspection and method rules
#   PROXY_PARSE_ONLY=1                            check the configuration and exit (used by tests)
#
# The inspection CA lives in /var/lib/agent-proxy (a volume only this container mounts). Its
# public certificate, and a bundle of the system roots plus that certificate, are written to
# /ca-pub (a volume the agent container mounts read-only), so tools inside the sandbox can
# trust the inspected connections.
set -euo pipefail
MODE="${PROXY_MODE:-enforce}"; INSPECT="${PROXY_INSPECT:-none}"
CA_DIR=/var/lib/agent-proxy; PUB=/ca-pub

case "$MODE" in enforce|audit) ;; *) echo "PROXY_MODE must be enforce or audit" >&2; exit 2 ;; esac
cp "/etc/squid/mode-$MODE.conf" /run/squid/mode.conf
case "$INSPECT" in
  none)   printf 'none.invalid\n' > /run/squid/inspect-domains.txt ;;   # a name that can never match
  github) cp /etc/squid/inspect-github.txt /run/squid/inspect-domains.txt ;;
  *) echo "PROXY_INSPECT must be none or github" >&2; exit 2 ;;
esac

# Inspection CA: generated once per volume, so recreating the proxy container keeps the same CA.
if [ ! -s "$CA_DIR/ca.key" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=agent-sandbox egress proxy CA/O=local sandbox, not a public CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.pem" >/dev/null 2>&1
fi
if [ ! -d "$CA_DIR/ssl_db" ]; then
  /usr/lib/squid/security_file_certgen -c -s "$CA_DIR/ssl_db" -M 4MB >/dev/null
fi
chmod 0700 "$CA_DIR"; chmod 0600 "$CA_DIR/ca.key"
# Publish the certificate. The bundle keeps the real public roots first, so connections that
# are not inspected still verify against the real chain.
cat /etc/ssl/certs/ca-certificates.crt "$CA_DIR/ca.pem" > "$PUB/ca-bundle.pem.tmp"
mv "$PUB/ca-bundle.pem.tmp" "$PUB/ca-bundle.pem"
cp "$CA_DIR/ca.pem" "$PUB/ca.pem"
chmod 0644 "$PUB/ca.pem" "$PUB/ca-bundle.pem"

if [ "${PROXY_PARSE_ONLY:-0}" = 1 ]; then exec squid -k parse -f /etc/squid/squid.conf; fi
exec squid -N -f /etc/squid/squid.conf
