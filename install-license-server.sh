#!/usr/bin/env bash
# SovereignMind Betreiber-Installer: Lizenzserver ("Portal") + Postgres (+ optional Caddy mit TLS).
#
# Nur für den Betreiber (dich), nie beim Kunden. Der Kunden-Installer (install.sh) bleibt unverändert.
#
# Aufruf:
#   SOVEREIGNMIND_GHCR_TOKEN=<token> bash install-license-server.sh
#   SOVEREIGNMIND_GHCR_TOKEN=<token> PORTAL_DOMAIN=portal.example.com bash install-license-server.sh   # mit TLS (Caddy)
#
# Env-Variablen:
#   SOVEREIGNMIND_GHCR_TOKEN  Pflicht. GitHub-Token (Contents + Packages lesen). Wird für den Download und `docker login`
#                             gebraucht und als PORTAL_UPSTREAM_TOKEN in .env (Rechte 600) abgelegt - der Registry-Proxy
#                             des Portals nutzt ihn, damit Kunden ohne eigenen GHCR-Token Images ziehen können.
#   GITHUB_USER               Optional, Default "Benexdrake".
#   PORTAL_DOMAIN             Optional. Öffentliche Domain -> Caddy-Profil "tls" (Ports 80/443, Zertifikat automatisch).
#                             Ohne Domain lauscht der Server nur auf 127.0.0.1:5100 (PackTool/SSH-Tunnel).
#   SOVEREIGNMIND_VERSION     Optional. Image-Tag, Default "latest".
#   SOVEREIGNMIND_DIR         Optional. Zielverzeichnis, Default "./license-server".
#   SOVEREIGNMIND_REF         Optional. Git-Ref für die Compose-Dateien, Default "main".
#
# Erneuter Aufruf = Update: .env und secrets/ bleiben unverändert, Images werden neu gezogen.
# Hintergrund: docs/pläne/betreiber-konsole-lizenzserver/phase-3-betreiber-stack.md

set -euo pipefail
# Git Bash (Windows) würde "/secrets" sonst in einen Windows-Pfad umschreiben.
export MSYS_NO_PATHCONV=1

REPO="Benexdrake/SovereignMind"
REF="${SOVEREIGNMIND_REF:-main}"
TARGET_DIR="${SOVEREIGNMIND_DIR:-./license-server}"
VERSION="${SOVEREIGNMIND_VERSION:-latest}"
GITHUB_USER="${GITHUB_USER:-Benexdrake}"
PORTAL_DOMAIN="${PORTAL_DOMAIN:-}"
COMPOSE_FILE="docker-compose.license-server.yml"

if [ -z "${SOVEREIGNMIND_GHCR_TOKEN:-}" ]; then
  echo "Fehler: SOVEREIGNMIND_GHCR_TOKEN nicht gesetzt." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker nicht gefunden. Bitte zuerst installieren: https://docs.docker.com/get-docker/" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker-Compose-Plugin nicht gefunden ('docker compose'). Bitte Docker aktualisieren." >&2
  exit 1
fi

echo "==> Login bei ghcr.io" >&2
echo "$SOVEREIGNMIND_GHCR_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "==> Lade Compose-Datei von GitHub (Ref: $REF)" >&2
for f in "$COMPOSE_FILE" Caddyfile.license-server 9.Support/scripts/backup-license-server.sh; do
  echo "    $f" >&2
  curl -fsSL \
    -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO}/contents/${f}?ref=${REF}" \
    -o "$(basename "$f")"
done
chmod +x backup-license-server.sh

# .env nur bei der Erstinstallation anlegen (ein neues Postgres-Passwort würde die bestehende Datenbank aussperren).
if [ ! -f .env ]; then
  umask 077
  owner_lc=$(echo "$GITHUB_USER" | tr '[:upper:]' '[:lower:]')
  {
    echo "# Betreiber-Stack (Lizenzserver). Enthält Geheimnisse - Rechte 600, nie weitergeben."
    echo "GITHUB_OWNER=${owner_lc}"
    echo "SOVEREIGNMIND_VERSION=${VERSION}"
    echo "PORTAL_POSTGRES_PASSWORD=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    echo "PORTAL_UPSTREAM_USER=${GITHUB_USER}"
    echo "PORTAL_UPSTREAM_TOKEN=${SOVEREIGNMIND_GHCR_TOKEN}"
    if [ -n "$PORTAL_DOMAIN" ]; then
      echo "PORTAL_DOMAIN=${PORTAL_DOMAIN}"
      echo "PORTAL_PUBLIC_URL=https://${PORTAL_DOMAIN}"
    else
      echo "PORTAL_PUBLIC_URL=http://localhost:5100"
    fi
  } > .env
  chmod 600 .env
  echo "==> .env angelegt (Rechte 600)." >&2
else
  chmod 600 .env
  echo "==> Vorhandene .env unverändert übernommen." >&2
  # Domain nachträglich per Variable gesetzt: nur ergänzen, nie bestehende Werte ändern.
  if [ -n "$PORTAL_DOMAIN" ] && ! grep -q '^PORTAL_DOMAIN=' .env; then
    { echo "PORTAL_DOMAIN=${PORTAL_DOMAIN}"; echo "PORTAL_PUBLIC_URL=https://${PORTAL_DOMAIN}"; } >> .env
  fi
fi

profile_args=()
if grep -q '^PORTAL_DOMAIN=.\+' .env; then
  profile_args=(--profile tls)
  echo "==> TLS-Profil aktiv (Caddy, Domain aus .env)." >&2
fi

compose() { docker compose -f "$COMPOSE_FILE" ${profile_args[@]+"${profile_args[@]}"} "$@"; }

echo "==> Ziehe Images" >&2
compose pull

echo "==> Initialisiere Geheimnisse (nur beim ersten Mal)" >&2
mkdir -p secrets backups
compose run --rm --no-deps license-server init --dir /secrets
chmod 700 secrets
chmod 600 secrets/* 2>/dev/null || true

echo "==> Starte Stack" >&2
compose up -d

echo "==> Warte auf den Lizenzserver" >&2
for _ in $(seq 1 40); do
  if compose ps license-server --format '{{.Health}}' 2>/dev/null | grep -q healthy; then
    ready=1
    break
  fi
  sleep 3
done
if [ "${ready:-0}" != "1" ]; then
  echo "WARNUNG: Der Lizenzserver wurde nicht gesund. Logs: docker compose -f $COMPOSE_FILE logs license-server" >&2
  exit 1
fi

public_url=$(grep '^PORTAL_PUBLIC_URL=' .env | cut -d= -f2-)
cat >&2 <<EOF

Lizenzserver läuft: ${public_url}
  - PackTool (Betreiber-Konsole): LicenseServer__BaseUrl=${public_url}  LicenseServer__AdminKey=<Admin-Schlüssel von oben>
  - Kunden-Installationen: License__ServerUrl=${public_url}, License__PublicKeyPem = secrets/license_public.pem
  - Sichern: secrets/ (Signaturschlüssel!) und die Postgres-Datenbank (docker compose -f $COMPOSE_FILE exec postgres pg_dump -U portal portal)
EOF
