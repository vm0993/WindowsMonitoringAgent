#!/usr/bin/env bash
# Builds dist/OfficeMonitoringAgent-Setup-<version>.exe on macOS/Linux: .NET 10 SDK + Docker (Inno Setup under Wine).
# On Windows use: dotnet publish ... -o publish; iscc /DAppVersion=<version> installer\OfficeMonitoringAgent.iss
#   MONITOR_API_URL=https://100.x.y.z installer/build.sh [version]
#   (version default: <Version> in WindowsMonitoringAgent.csproj; MONITOR_API_URL = Tailscale address of the
#    monitoring server, pre-filled in the wizard. Without it the URL must be typed at install time.
#    Put the server's self-signed certificate from installer/make-cert.sh at installer/certs/monitoring.crt.)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' WindowsMonitoringAgent.csproj)}"

rm -rf publish
dotnet publish WindowsMonitoringAgent.csproj -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none \
  -p:Version="$VERSION" -o publish

docker run --rm --platform linux/amd64 -v "$PWD":/work amake/innosetup:latest \
  "/DAppVersion=$VERSION" "/DFileVersion=${VERSION%%-*}" "/DDefaultApiUrl=${MONITOR_API_URL:-}" installer/OfficeMonitoringAgent.iss

SETUP="dist/OfficeMonitoringAgent-Setup-$VERSION.exe"
(cd dist && shasum -a 256 "$(basename "$SETUP")" > "$(basename "$SETUP").sha256")
echo "Installer: $SETUP"
