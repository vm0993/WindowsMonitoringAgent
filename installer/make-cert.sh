#!/usr/bin/env bash
# Run ON THE MONITORING SERVER (as root). Creates a self-signed TLS certificate whose first name is the server's
# Tailscale IP (what agents use) plus any extra names the dashboard is opened with (LAN IP for testing, later the
# public IP or subdomain). Without MagicDNS "tailscale cert" is not available.
#   sudo bash make-cert.sh [tailscale-ip] [extra-ip-or-dns ...]
#   e.g. sudo bash make-cert.sh 100.88.53.5 192.168.66.203 monitor.dapenma.co.id
#   (tailscale-ip default: "tailscale ip -4"; OUT=/etc/ssl/monitor -> fullchain.pem + privkey.pem for nginx)
# Then copy $OUT/fullchain.pem into the repo as installer/certs/monitoring.crt (public part only, never
# privkey.pem) and rebuild the installer: it is imported into Trusted Root on every Windows agent.
# Adding a name later = run again with ALL names, update the installer, and re-import on the agents.
set -euo pipefail
IP="${1:-$(tailscale ip -4 | head -n1)}"
[[ $# -gt 0 ]] && shift
OUT="${OUT:-/etc/ssl/monitor}"
if [[ ! "$IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "Not a Tailscale IPv4 (100.64.0.0/10): $IP" >&2; exit 1
fi
SAN="IP:$IP"
for name in "$@"; do
  if [[ "$name" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then SAN="$SAN,IP:$name"
  elif [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]]; then SAN="$SAN,DNS:$name"
  else echo "Invalid name: $name" >&2; exit 1; fi
done
mkdir -p "$OUT"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout "$OUT/privkey.pem" -out "$OUT/fullchain.pem" \
  -subj "/CN=$IP" \
  -addext "subjectAltName=$SAN" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null
chmod 600 "$OUT/privkey.pem"; chmod 644 "$OUT/fullchain.pem"
openssl x509 -in "$OUT/fullchain.pem" -noout -subject -ext subjectAltName -enddate
echo "nginx: ssl_certificate $OUT/fullchain.pem; ssl_certificate_key $OUT/privkey.pem; then: systemctl reload nginx"
echo "Installer: copy $OUT/fullchain.pem to installer/certs/monitoring.crt"
