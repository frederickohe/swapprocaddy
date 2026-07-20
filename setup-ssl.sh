#!/usr/bin/env bash
# Obtain TLS certificates via Caddy (Let's Encrypt) for swappro.store.
#
# Prerequisites:
#   - ./setup-networks.sh has been run
#   - ../swapbackend and this stack are running
#   - DNS A records for all hostnames below point to this server
#   - Ports 80 and 443 are reachable from the internet
#
# Usage:
#   ./setup-ssl.sh
#   CADDY_ACME_EMAIL=you@example.com ./setup-ssl.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADDY_DIR="$SCRIPT_DIR"
BACKEND_DIR="$(cd "$SCRIPT_DIR/../swapbackend" && pwd)"
CADDY_CONTAINER="${CADDY_CONTAINER:-swappro-caddy}"

DOMAINS=(
  swappro.store
  www.swappro.store
  admin.swappro.store
  api.swappro.store
  db.swappro.store
  portainer.swappro.store
)

REQUIRED_CONTAINERS=(
  swappro_backend
  swappro_pgadmin
  swappro_portainer
  swappro-caddy
)

info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."
}

check_dns() {
  local domain="$1"
  local answers=""

  if command -v dig >/dev/null 2>&1; then
    answers="$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)"
  elif command -v nslookup >/dev/null 2>&1; then
    answers="$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n +2 || true)"
  else
    warn "Neither dig nor nslookup found — skipping DNS check for $domain"
    return 0
  fi

  if [[ -z "$answers" ]]; then
    warn "$domain does not resolve to an IPv4 address yet"
    return 1
  fi

  echo "  $domain → $answers"
  return 0
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}

wait_for_https() {
  local domain="$1"
  local attempt
  local code="000"

  for attempt in $(seq 1 12); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://${domain}/" 2>/dev/null || echo "000")"
    if [[ "$code" != "000" ]]; then
      echo "  $domain — HTTPS reachable (HTTP $code)"
      return 0
    fi
    sleep 5
  done

  warn "$domain — HTTPS not reachable yet (last status: $code)"
  return 1
}

verify_certificate() {
  local domain="$1"
  local subject expiry

  if ! subject="$(echo | openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"; then
    warn "$domain — could not read certificate"
    return 1
  fi

  expiry="$(echo | openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2-)"
  echo "  $domain — ${subject#subject= } (expires ${expiry})"
}

require_command docker
require_command curl
require_command openssl

[[ -d "$BACKEND_DIR" ]] || fail "swapbackend not found at $BACKEND_DIR (expected sibling of swapprocaddy)"

info "Checking Docker network 'swappro'"
docker network inspect swappro >/dev/null 2>&1 || fail "Network 'swappro' not found. Run ./setup-networks.sh first."

info "Starting Swappro backend stack (if needed)"
(
  cd "$BACKEND_DIR"
  docker compose up -d
)

for name in swappro_backend swappro_pgadmin; do
  container_running "$name" || fail "Container '$name' is not running. Check: cd ../swapbackend && docker compose logs"
done

info "Starting Caddy + Portainer (if needed)"
(
  cd "$CADDY_DIR"
  docker compose up -d
)

for name in "${REQUIRED_CONTAINERS[@]}"; do
  container_running "$name" || fail "Container '$name' is not running. Check: cd swapprocaddy && docker compose logs"
done

info "Validating Caddyfile"
docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile

info "Reloading Caddy to trigger certificate requests"
docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile

info "Checking DNS (A records must point to this server before certs can issue)"
dns_ok=true
for domain in "${DOMAINS[@]}"; do
  check_dns "$domain" || dns_ok=false
done

if [[ "$dns_ok" != true ]]; then
  warn "One or more domains do not resolve. Fix DNS, then re-run ./setup-ssl.sh"
fi

info "Requesting certificates (HTTPS handshake to each host)"
for domain in "${DOMAINS[@]}"; do
  wait_for_https "$domain" || true
done

info "Certificate status"
for domain in "${DOMAINS[@]}"; do
  verify_certificate "$domain" || true
done

echo ""
echo "Done. Caddy stores certificates in the 'caddy_data' Docker volume."
echo "Renewal is automatic. To inspect: docker exec $CADDY_CONTAINER caddy list-certificates --config /etc/caddy/Caddyfile"
