#!/usr/bin/env bash
# Run ON THE MONITORING SERVER (as root). Creates a self-signed TLS certificate for the server's Tailscale IP,
# because without MagicDNS "tailscale cert" is not available.
#   sudo installer/make-cert.sh [tailscale-ip] [out-dir]
#   (ip default: "tailscale ip -4"; out-dir default: /etc/ssl/monitor -> fullchain.pem + privkey.pem for nginx)
# Then copy <out-dir>/fullchain.pem into the repo as installer/certs/monitoring.crt (public part only, never
# privkey.pem) and rebuild the installer: it is imported into Trusted Root on every Windows agent.
set -euo pipefail
IP="${1:-$(tailscale ip -4 | head -n1)}"
OUT="${2:-/etc/ssl/monitor}"
if [[ ! "$IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "Not a Tailscale IPv4 (100.64.0.0/10): $IP" >&2; exit 1
fi
mkdir -p "$OUT"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout "$OUT/privkey.pem" -out "$OUT/fullchain.pem" \
  -subj "/CN=$IP" \
  -addext "subjectAltName=IP:$IP" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth"
chmod 600 "$OUT/privkey.pem"; chmod 644 "$OUT/fullchain.pem"
openssl x509 -in "$OUT/fullchain.pem" -noout -subject -ext subjectAltName -enddate
echo "nginx: ssl_certificate $OUT/fullchain.pem; ssl_certificate_key $OUT/privkey.pem; then: systemctl reload nginx"
echo "Installer: copy $OUT/fullchain.pem to installer/certs/monitoring.crt"
