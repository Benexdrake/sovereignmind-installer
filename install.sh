#!/usr/bin/env bash
# SovereignMind Installer (Linux/macOS).
#
# Lädt die Compose-Dateien + .env-Vorlage + config.jsonl aus dem (privaten!) GitHub-Repo, loggt
# sich bei der privaten GHCR-Registry ein, pullt die vorgebauten Images und
# startet den kompletten Stack (Ollama, Qdrant, Ingestion-Worker, Backend,
# Frontend). Entspricht in der Idee `curl -fsSL <url>/install.sh | bash`, mit dem
# Unterschied, dass wegen des privaten Repos ein Token als Header mitgeschickt
# werden muss - s. README.md, Abschnitt "Installation beim Kunden".
#
# Aufruf:
#   SOVEREIGNMIND_GHCR_TOKEN=<token> bash install.sh
#   SOVEREIGNMIND_PORTAL_URL=https://portal.example.com SOVEREIGNMIND_LICENSE_KEY=SM-... bash install.sh   # ohne GitHub-Token
#
# Env-Variablen:
#   SOVEREIGNMIND_PORTAL_URL  Optional (Portal-Modus). Adresse des Lizenzservers des Betreibers; dann kommen Installationsdateien
#                             und Images von dort, der GitHub-Token entfällt. Braucht SOVEREIGNMIND_LICENSE_KEY.
#   SOVEREIGNMIND_LICENSE_KEY Lizenzschlüssel "SM-..." (nur im Portal-Modus); landet in .env und aktiviert die Online-Lizenz.
#   SOVEREIGNMIND_GHCR_TOKEN  Pflicht (außer im Portal-Modus). GitHub-Token mit Zugriff auf "Contents"
#                             (privates Repo lesen) und "Packages"
#                             (GHCR-Images ziehen) - klassischer PAT mit Scopes
#                             `repo` + `read:packages`, oder Fine-grained-Token
#                             mit "Contents: Read-only" + "Packages: Read-only".
#   GITHUB_USER               Optional. Benutzername für `docker login`, Default "Benexdrake".
#   SOVEREIGNMIND_VERSION      Optional. Image-Tag, Default "latest".
#   SOVEREIGNMIND_DIR          Optional. Zielverzeichnis, Default "./sovereignmind".
#   SOVEREIGNMIND_REF          Optional. Git-Ref/Branch/Tag für die
#                             Compose-Dateien, Default "main".
#   SOVEREIGNMIND_BACKUP_SCHEDULE  Optional. "yes"/"no": tägliches Backup per cron einrichten, ohne
#                             nachzufragen (ohne Terminal und ohne Angabe: übersprungen).
#
# Geplantes Backup wieder entfernen (nur den cron-Eintrag, Backups bleiben):
#   bash install.sh --remove-backup-schedule
#
# Details/Hintergrund der Design-Entscheidungen:
# docs/anpassungen-plan/phase-5-installer-registry.md

set -euo pipefail

# Der cron-Eintrag trägt diese Markierung, damit Einrichten/Entfernen ihn eindeutig wiederfinden
# (docs/pläne/postgres-haertung-und-backup/phase-2-geplante-backups-und-aufbewahrung.md).
BACKUP_CRON_MARK="# sovereignmind-backup"

if [ "${1:-}" = "--remove-backup-schedule" ]; then
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "$BACKUP_CRON_MARK"; then
    crontab -l 2>/dev/null | grep -vF "$BACKUP_CRON_MARK" | crontab -
    echo "==> Geplantes Backup (cron) entfernt. Vorhandene Backups bleiben unverändert."
  else
    echo "==> Kein geplantes Backup eingerichtet - nichts zu tun."
  fi
  exit 0
fi

cat <<'BANNER'

    .-""-.
   /  ()  \    SovereignMind
   \      /    On-Premise KI-Gateway
    '-..-'

BANNER

REPO="Benexdrake/SovereignMind"
REF="${SOVEREIGNMIND_REF:-main}"
TARGET_DIR="${SOVEREIGNMIND_DIR:-./sovereignmind}"
VERSION="${SOVEREIGNMIND_VERSION:-latest}"

# Portal-Modus: Dateien und Images kommen vom Lizenzserver des Betreibers, der Lizenzschlüssel ersetzt den GitHub-Token.
PORTAL_URL="${SOVEREIGNMIND_PORTAL_URL:-}"
if [ -n "$PORTAL_URL" ]; then
  if [ -z "${SOVEREIGNMIND_LICENSE_KEY:-}" ]; then
    echo "Fehler: SOVEREIGNMIND_PORTAL_URL ist gesetzt, aber SOVEREIGNMIND_LICENSE_KEY fehlt." >&2
    exit 1
  fi
  PORTAL_URL="${PORTAL_URL%/}"
  PORTAL_HOST="${PORTAL_URL#*://}"
elif [ -z "${SOVEREIGNMIND_GHCR_TOKEN:-}" ]; then
  echo "Fehler: SOVEREIGNMIND_GHCR_TOKEN nicht gesetzt." >&2
  echo "Siehe README.md, Abschnitt 'Installation beim Kunden', für die Token-Erstellung." >&2
  exit 1
fi
GITHUB_USER="${GITHUB_USER:-Benexdrake}"

# --- docker-bootstrap begin (installer-docker-bootstrap-test.sh schneidet diesen Block aus - Marker nicht entfernen)
# Linux: fehlende Voraussetzungen (Docker mit Compose-Plugin, curl, zstd/pciutils für den Ollama-Installer) und den
# Docker-Dienst einrichten, damit der Installer auf einem frisch installierten Ubuntu/Debian ohne Vorarbeit durchläuft.
# Das steht bewusst hier und nicht in ensure-docker.sh: install.sh ist die einzige Datei, die vor dem Docker-Login
# vorhanden ist. macOS/Windows: Docker Desktop bleibt Sache des Benutzers (ensure-docker.sh startet es später).
# Antwort auf die Rückfrage vorab: SOVEREIGNMIND_INSTALL_DOCKER=yes|no (ohne Terminal und ohne Angabe: nein).
SYSTEM_SETUP_APPROVED=0

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

apt_get() {
  # Lock-Timeout: auf frisch installierten Systemen hält unattended-upgrades/PackageKit anfangs oft die dpkg-Sperre.
  as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y "$@"
}

os_field() {
  ( . /etc/os-release 2>/dev/null; printf '%s' "${!1:-}" )
}

# Gibt "<ubuntu|debian> <codename>" für das Docker-apt-Repository aus (Ableger wie Linux Mint über ID_LIKE/UBUNTU_CODENAME).
docker_repo_target() {
  local id like codename
  id="$(os_field ID)"
  like="$(os_field ID_LIKE)"
  case " $id $like " in
    *" ubuntu "*)
      codename="$(os_field UBUNTU_CODENAME)"
      [ -n "$codename" ] || codename="$(os_field VERSION_CODENAME)"
      [ -n "$codename" ] && echo "ubuntu $codename"
      ;;
    *" debian "*)
      codename="$(os_field VERSION_CODENAME)"
      [ -n "$codename" ] && echo "debian $codename"
      ;;
    *) return 1 ;;
  esac
}

confirm_system_setup() {
  local answer="${SOVEREIGNMIND_INSTALL_DOCKER:-}"
  if [ -z "$answer" ]; then
    [ -r /dev/tty ] || return 1
    read -r -p "$1 [J/n] " answer </dev/tty || return 1
  fi
  case "$answer" in "" | j | J | y | Y | yes | Yes | ja | Ja) return 0 ;; *) return 1 ;; esac
}

install_docker_engine() {
  # Offizielle Anleitung: https://docs.docker.com/engine/install/ubuntu/ (apt-Repository, nicht das Convenience-Skript).
  local target distro codename
  target="$(docker_repo_target)"
  distro="${target%% *}"
  codename="${target##* }"
  apt_get update
  apt_get install ca-certificates curl
  as_root install -m 0755 -d /etc/apt/keyrings
  as_root curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
  as_root chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$distro" "$codename" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt_get update
  apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

bootstrap_linux_prerequisites() {
  [ "$(uname -s)" = "Linux" ] || return 0
  local pkgs=() need_docker=0
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  # zstd und lspci/lshw braucht nur der Ollama-Installer (Entpacken bzw. AMD-/Nvidia-Erkennung).
  if ! command -v ollama >/dev/null 2>&1; then
    command -v zstd >/dev/null 2>&1 || pkgs+=(zstd)
    command -v lspci >/dev/null 2>&1 || pkgs+=(pciutils)
  fi
  command -v docker >/dev/null 2>&1 || need_docker=1
  if [ "$need_docker" -eq 0 ] && [ "${#pkgs[@]}" -eq 0 ]; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1 || { [ "$need_docker" -eq 1 ] && ! docker_repo_target >/dev/null; }; then
    if [ "$need_docker" -eq 1 ]; then
      echo "Docker nicht gefunden. Die automatische Installation gibt es nur für Ubuntu/Debian - bitte manuell installieren: https://docs.docker.com/engine/install/" >&2
      exit 1
    fi
    echo "Hinweis: Es fehlen Programme (${pkgs[*]}) - bitte nachinstallieren, falls der Installer daran scheitert." >&2
    return 0
  fi
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    echo "Es fehlen Voraussetzungen, sudo ist aber nicht vorhanden. Bitte als root ausführen oder manuell installieren (Docker: https://docs.docker.com/engine/install/)." >&2
    exit 1
  fi

  {
    echo ""
    echo "Folgende Voraussetzungen fehlen und werden jetzt eingerichtet (benötigt sudo-Rechte):"
    if [ "$need_docker" -eq 1 ]; then
      echo "  - Docker Engine mit Compose-Plugin (offizielles Docker-apt-Repository), Dienst wird gestartet und beim Boot aktiviert"
      echo "  - Ihr Benutzer wird zur Gruppe 'docker' hinzugefügt (das entspricht Root-Rechten auf diesem Rechner)"
    fi
    if [ "${#pkgs[@]}" -gt 0 ]; then
      echo "  - Pakete: ${pkgs[*]}"
    fi
  } >&2
  if ! confirm_system_setup "Jetzt einrichten?"; then
    echo "Abgebrochen. Ohne Einrichtung bitte manuell installieren (Docker: https://docs.docker.com/engine/install/)." >&2
    echo "Ohne Rückfrage: SOVEREIGNMIND_INSTALL_DOCKER=yes setzen." >&2
    exit 1
  fi
  SYSTEM_SETUP_APPROVED=1

  if [ "${#pkgs[@]}" -gt 0 ]; then
    echo "==> Installiere Pakete: ${pkgs[*]}" >&2
    apt_get update
    apt_get install "${pkgs[@]}"
  fi
  if [ "$need_docker" -eq 1 ]; then
    echo "==> Installiere Docker Engine" >&2
    install_docker_engine
  fi
}

# Docker-Dienst starten und dem Benutzer Zugriff ohne sudo geben. Ist die Gruppe 'docker' in dieser Shell noch nicht aktiv
# (frisch hinzugefügt), startet sich das Skript einmal unter dieser Gruppe neu (sg); bei `curl | bash` geht das nicht,
# dann bleibt nur der Hinweis, denselben Befehl in einem neuen Terminal zu wiederholen (der Installer ist idempotent).
ensure_docker_access() {
  [ "$(uname -s)" = "Linux" ] || return 0
  docker info >/dev/null 2>&1 && return 0

  if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet docker; then
    echo "==> Docker-Dienst läuft nicht - starte ihn und aktiviere den Autostart" >&2
    as_root systemctl enable --now docker || {
      echo "Fehler: Docker-Dienst konnte nicht gestartet werden ('sudo systemctl status docker' zeigt den Grund)." >&2
      exit 1
    }
  fi
  local i
  for i in $(seq 1 30); do
    as_root docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null 2>&1 && return 0
  if ! as_root docker info >/dev/null 2>&1; then
    echo "Fehler: Docker-Daemon nicht erreichbar ('sudo systemctl status docker' bzw. 'sudo journalctl -u docker' prüfen)." >&2
    exit 1
  fi

  # Daemon läuft, aber der Benutzer darf den Socket nicht nutzen.
  local user
  user="$(id -un)"
  if [ "$(id -u)" -ne 0 ]; then
    case " $(id -nG "$user") " in
      *" docker "*) ;; # schon Mitglied, nur in dieser Sitzung noch nicht aktiv
      *)
        if [ "$SYSTEM_SETUP_APPROVED" -ne 1 ] &&
           ! confirm_system_setup "Benutzer '$user' zur Gruppe 'docker' hinzufügen (entspricht Root-Rechten)?"; then
          echo "Ohne Zugriff auf Docker nicht möglich. Manuell: sudo usermod -aG docker $user, danach neu anmelden." >&2
          exit 1
        fi
        echo "==> Füge '$user' zur Gruppe 'docker' hinzu" >&2
        as_root usermod -aG docker "$user"
        ;;
    esac
  fi
  if [ -z "${SOVEREIGNMIND_DOCKER_REEXEC:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ] && command -v sg >/dev/null 2>&1; then
    echo "==> Starte den Installer mit aktiver Gruppe 'docker' neu" >&2
    SOVEREIGNMIND_DOCKER_REEXEC=1 exec sg docker -c "$(printf '%q ' bash "${BASH_SOURCE[0]}" "$@")"
  fi
  echo "Docker ist eingerichtet, die Gruppe 'docker' ist in diesem Terminal aber noch nicht aktiv." >&2
  echo "Bitte ein neues Terminal öffnen (oder abmelden und neu anmelden) und denselben Installationsbefehl erneut ausführen." >&2
  exit 1
}
# --- docker-bootstrap end

bootstrap_linux_prerequisites
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker nicht gefunden. Bitte zuerst installieren: https://docs.docker.com/get-docker/" >&2
  exit 1
fi
ensure_docker_access "$@"
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker-Compose-Plugin nicht gefunden ('docker compose'). Bitte Docker aktualisieren." >&2
  exit 1
fi

# Lädt eine Repo-Datei: aus dem privaten GitHub-Repo (Token) oder im Portal-Modus vom Lizenzserver (Lizenzschlüssel).
fetch() {
  local path="$1" out="$2"
  if [ -n "$PORTAL_URL" ]; then
    curl -fsSL -H "X-License-Key: ${SOVEREIGNMIND_LICENSE_KEY}" "${PORTAL_URL}/api/dist/$(basename "$path")" -o "$out"
  else
    curl -fsSL \
      -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}" \
      -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/${REPO}/contents/${path}?ref=${REF}" \
      -o "$out"
  fi
}

if [ -n "$PORTAL_URL" ]; then
  # Registry-Proxy des Portals: Benutzername beliebig, Passwort = Lizenzschlüssel (docker login verlangt HTTPS, außer bei localhost).
  echo "==> Login beim Lizenzserver ($PORTAL_HOST)" >&2
  echo "$SOVEREIGNMIND_LICENSE_KEY" | docker login "$PORTAL_HOST" -u license --password-stdin
else
  echo "==> Login bei ghcr.io" >&2
  echo "$SOVEREIGNMIND_GHCR_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
fi

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

if [ -n "$PORTAL_URL" ]; then
  echo "==> Lade Compose-Dateien vom Lizenzserver ($PORTAL_URL)" >&2
else
  echo "==> Lade Compose-Dateien von GitHub (Ref: $REF)" >&2
fi
for f in docker-compose.yml docker-compose.images.yml docker-compose.nvidia.yml \
  docker-compose.rocm.yml docker-compose.gpu-monitor.yml .env.example; do
  echo "    $f" >&2
  fetch "8.Docker/$f" "$f"
done
# Im Repo liegen die Compose-Dateien in 8.Docker/ (models.json und backups/ eine Ebene darüber), hier flach in einem
# Ordner. Die vom Lizenzserver gelieferte Datei ist schon umgeschrieben (Dockerfile der Administration.Api), der Schritt idempotent.
sed 's#\.\./models\.json#./models.json#g; s#\.\./backups#./backups#g' docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml

# models.json (Modell-Katalog, Phase 2a, docs/pläne/log-modelle-hardware-anpassungen/02a-...) nur
# laden, wenn noch keine vorhanden ist - der Admin kann die Datei nach der Erstinstallation
# bearbeiten (neues Modell ergänzen, VRAM-Wert korrigieren), ein erneuter Installer-/Update-Lauf
# soll das nicht überschreiben (anders als die Compose-Dateien, die immer den Release-Stand
# bekommen).
if [ ! -f models.json ]; then
  echo "    models.json" >&2
  fetch models.json models.json
else
  echo "==> Vorhandene models.json unveraendert uebernommen." >&2
fi

# config.jsonl (zentrale, nicht geheime Konfiguration, docs/pläne/chat-voice-dokumente-ollama-native/
# 07-phase-7-config-jsonl-feature-gates.md) ebenfalls nur bei der Erstinstallation laden - der
# Betreiber trägt dort Impressum, Ports, Connector-Hosts usw. ein, ein Update soll das nicht
# überschreiben. Fehlende neue Schlüssel fangen die Defaults in docker-compose.yml ab.
if [ ! -f config.jsonl ]; then
  echo "    config.jsonl" >&2
  fetch 8.Docker/config.jsonl config.jsonl
else
  echo "==> Vorhandene config.jsonl uebernommen (Werte bleiben unveraendert)." >&2
  # Neue Schlüssel späterer Releases ergänzen (nur hinzufügen, nie bestehende Werte ändern).
  if fetch 8.Docker/config.jsonl config.jsonl.new; then
    added_keys=()
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^\{\"key\":\"([A-Za-z_][A-Za-z0-9_]*)\" ]]; then
        if ! grep -q "^{\"key\":\"${BASH_REMATCH[1]}\"" config.jsonl; then
          [ -n "$(tail -c1 config.jsonl)" ] && echo >> config.jsonl
          printf '%s\n' "$line" >> config.jsonl
          added_keys+=("${BASH_REMATCH[1]}")
        fi
      fi
    done < config.jsonl.new
    if [ "${#added_keys[@]}" -gt 0 ]; then
      echo "==> ${#added_keys[@]} neue Konfigurationsschluessel in config.jsonl ergaenzt (Defaults, Werte pruefen): ${added_keys[*]}" >&2
    fi
  else
    echo "WARNUNG: Aktuelle config.jsonl konnte nicht geladen werden - neue Schluessel nicht geprueft." >&2
  fi
  rm -f config.jsonl.new
fi

# 9.Support/scripts/*.sh liegen im Repo unter 9.Support/scripts/, werden hier aber flach abgelegt (wie die
# Compose-Dateien) - der Installer geht nicht von einem vollständigen Repo-Checkout aus.
for f in ensure-docker.sh load-config.sh backup-db.sh backup-prune.sh restore-db.sh recovery-kit.sh; do
  echo "    $f" >&2
  fetch "9.Support/scripts/${f}" "$f"
done

# shellcheck disable=SC1091
source ensure-docker.sh
ensure_docker_running

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> .env aus Vorlage angelegt (nur Geheimnisse). Ports, Impressum usw. stehen in config.jsonl." >&2
else
  echo "==> Vorhandene .env unverändert übernommen." >&2
fi

# Portal-Modus: Images laufen über den Registry-Proxy des Lizenzservers, die Online-Aktivierung ist gleich mit eingerichtet.
# Die Werte gehören in .env (nicht nur in die Shell), damit spätere `docker compose`-Aufrufe und Updates dasselbe sehen.
if [ -n "$PORTAL_URL" ]; then
  env_set() {
    local key="$1" value="$2"
    grep -v "^${key}=" .env > .env.tmp || true
    printf '%s=%s\n' "$key" "$value" >> .env.tmp
    mv .env.tmp .env
  }
  env_set SOVEREIGNMIND_REGISTRY "${PORTAL_HOST}/benexdrake"
  env_set LICENSE_SERVER_URL "$PORTAL_URL"
  env_set LICENSE_KEY "$SOVEREIGNMIND_LICENSE_KEY"
  chmod 600 .env
  echo "==> Portal-Modus: Registry ${PORTAL_HOST}/benexdrake, Online-Aktivierung über ${PORTAL_URL} (in .env eingetragen)." >&2
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

# shellcheck disable=SC1091
source ./load-config.sh
load_config

# Online-Aktivierung (LICENSE_SERVER_URL) überträgt Daten an den Lizenzserver - vor dem ersten Start
# offenlegen und bestätigen lassen. Ablehnen = rein offline (Lizenzdatei), Server-URL wird geleert.
if [ -n "${LICENSE_SERVER_URL:-}" ]; then
  {
    echo ""
    echo "Datenschutzhinweis zur Online-Aktivierung der Lizenz:"
    echo "  Die Installation meldet sich bei ${LICENSE_SERVER_URL} und überträgt dabei: Lizenzschlüssel, eine Instanz-ID"
    echo "  (Hash aus Hostname und einem lokalen Geheimnis, kein Klartext-Hostname), die Produktversion und"
    echo "  den Zeitpunkt der Prüfung (regelmäßiger Heartbeat). Keine Dokumente, Chats oder Nutzerdaten."
    echo "  Ohne Online-Aktivierung läuft die Installation mit einer Lizenzdatei komplett offline."
  } >&2
  read -r -p "Online-Aktivierung erlauben? [J/n] " license_answer </dev/tty || license_answer=""
  case "$license_answer" in
    n|N|nein|Nein)
      config_set LICENSE_SERVER_URL ""
      export LICENSE_SERVER_URL=""
      echo "    Online-Aktivierung deaktiviert (LICENSE_SERVER_URL geleert)." >&2
      ;;
  esac
fi

ensure_postgres_password config
ensure_jwt_secret config
ensure_dataprotection_cert || exit 1

# Alte Installationen können noch LLM_SERVER=1 (llama.cpp) in config.jsonl/.env haben - der Pfad
# ist entfernt, Ollama ist das einzige Backend. Nur ein Hinweis, kein Abbruch.
if [ -n "${LLM_SERVER:-}" ] && [ "${LLM_SERVER}" != "0" ]; then
  echo "HINWEIS: LLM_SERVER=$LLM_SERVER wird ignoriert - llama.cpp wird nicht mehr unterstützt, es wird Ollama verwendet. Die Einträge LLM_SERVER und LLM_CHAT_*/LLM_EMBED_* können Sie aus config.jsonl entfernen." >&2
fi

ollama_reachable() {
  curl -fsS --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1
}

ollama_listens_on_all_interfaces() {
  # Backend-Container erreicht Ollama nur, wenn es nicht ausschließlich auf 127.0.0.1 lauscht.
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):11434[[:space:]]'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -Eq '(\*|0\.0\.0\.0):11434'
  else
    return 0 # nicht prüfbar - nicht fälschlich warnen
  fi
}

wait_ollama_reachable() {
  local i
  for i in $(seq 1 30); do
    ollama_reachable && return 0
    sleep 2
  done
  return 1
}

ollama_model_tags() {
  # Chat-Modell: OLLAMA_CHAT_MODEL aus config.jsonl/.env, sonst immer Qwen 2.5 7B (unabhängig vom VRAM).
  # Embedding: OLLAMA_EMBEDDING_MODEL / bge-m3.
  local chat_tag="${OLLAMA_CHAT_MODEL:-}"
  echo "${chat_tag:-qwen2.5:7b-instruct-q4_K_M}"
  echo "${OLLAMA_EMBEDDING_MODEL:-bge-m3}"
}

restart_native_ollama() {
  if [ "$(uname -s)" = "Darwin" ]; then
    launchctl setenv OLLAMA_HOST 0.0.0.0
    pkill -x Ollama >/dev/null 2>&1 || true
    pkill -x ollama >/dev/null 2>&1 || true
    sleep 2
    if [ -d /Applications/Ollama.app ]; then
      open -a Ollama
    else
      OLLAMA_HOST=0.0.0.0 nohup ollama serve >/dev/null 2>&1 &
    fi
  elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | sudo tee /etc/systemd/system/ollama.service.d/sovereignmind-host.conf >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
  else
    pkill -x ollama >/dev/null 2>&1 || true
    sleep 2
    OLLAMA_HOST=0.0.0.0 nohup ollama serve >/dev/null 2>&1 &
  fi
}

ensure_native_ollama() {
  # Phase 4 (docs/pläne/chat-voice-dokumente-ollama-native): Ollama läuft nativ, nicht als Container.
  # Idempotent: vorhandenes, korrekt konfiguriertes Ollama wird nur geprüft.
  echo "==> Prüfe native Ollama-Installation" >&2
  if ! command -v ollama >/dev/null 2>&1; then
    echo "    Ollama nicht gefunden - installiere" >&2
    if [ "$(uname -s)" = "Darwin" ]; then
      if command -v brew >/dev/null 2>&1; then
        brew install --cask ollama
      else
        echo "WARNUNG: Homebrew nicht gefunden - bitte Ollama manuell von https://ollama.com/download installieren, danach Installer erneut ausführen." >&2
        return 0
      fi
    else
      curl -fsSL https://ollama.com/install.sh | sh
    fi
  else
    echo "    Ollama bereits installiert." >&2
  fi

  if ! ollama_reachable || ! ollama_listens_on_all_interfaces; then
    echo "    Setze OLLAMA_HOST=0.0.0.0 und starte Ollama (neu)" >&2
    restart_native_ollama
  fi

  if ! wait_ollama_reachable; then
    echo "WARNUNG: Ollama ist nach 60 s nicht unter http://localhost:11434 erreichbar - Modell-Pull übersprungen." >&2
    return 0
  fi
  if ollama_listens_on_all_interfaces; then
    echo "    Ollama lauscht auf 0.0.0.0:11434." >&2
  else
    echo "WARNUNG: Ollama lauscht nur auf Loopback - der Backend-Container wird es nicht erreichen (OLLAMA_HOST=0.0.0.0 setzen und Ollama neu starten)." >&2
  fi

  local tag
  while IFS= read -r tag; do
    echo "==> ollama pull $tag" >&2
    ollama pull "$tag" || echo "WARNUNG: ollama pull $tag fehlgeschlagen - später manuell nachholen." >&2
  done < <(ollama_model_tags)
}

FILES=(-f docker-compose.yml -f docker-compose.images.yml)
# Ollama läuft nativ auf dem Host (kein Container), s. docs/pläne/chat-voice-dokumente-ollama-native.
ensure_native_ollama

# XTTS-v2 steht unter der Coqui Public Model License (nicht-kommerziell). Standard ist XTTS_LICENSE_ACCEPTED=1 (config.jsonl),
# der Installer fragt nicht nach und gibt nur einen Hinweis aus; mit 0 in config.jsonl nutzt die Sprachausgabe Piper (CPU).
ask_xtts_license() {
  [ "${XTTS_LICENSE_ACCEPTED:-1}" != "0" ] || return 0
  echo "Hinweis: Die GPU-Sprachausgabe nutzt Coqui XTTS-v2 (CPML, nur nicht-kommerzielle Nutzung, https://coqui.ai/cpml). Abschalten: XTTS_LICENSE_ACCEPTED=0 in config.jsonl." >&2
}

# GPU-Durchreichung für voice-worker (STT/TTS) und GPU-Erkennung im Backend. Ollama selbst läuft nativ und
# braucht das Overlay nicht.
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 \
    && docker run --rm --gpus all busybox true >/dev/null 2>&1; then
  echo "GPU erkannt: Nvidia - reiche sie an voice-worker/backend durch (docker-compose.nvidia.yml)" >&2
  FILES+=(-f docker-compose.nvidia.yml)
  ask_xtts_license
elif rocm_gpu_usable; then
  # AMD: nur XTTS (TTS) läuft über PyTorch/ROCm auf der GPU, faster-whisper (STT) bleibt auf der CPU. Eigenes
  # voice-worker-Image (sovereignmind-voice-worker-rocm), Gruppen als numerische GIDs (kein "render" im Image).
  echo "GPU erkannt: AMD - reiche sie an den voice-worker durch (docker-compose.rocm.yml; Sprachausgabe auf der GPU, Diktat auf der CPU)" >&2
  FILES+=(-f docker-compose.rocm.yml)
  set_rocm_gids persist
  ask_xtts_license
fi

# Hardware-Dashboard unter Linux mit AMD-GPU: das Backend liest VRAM/Temperatur/Lüfter aus /sys des Hosts (rocm-smi gibt es im
# Image nicht). Das Overlay bindet /sys schreibgeschützt ein, deshalb nur bei erkannter AMD-GPU.
if amd_gpu_present; then
  echo "AMD-GPU erkannt - binde /sys für das Hardware-Dashboard ein (docker-compose.gpu-monitor.yml)" >&2
  FILES+=(-f docker-compose.gpu-monitor.yml)
fi

export SOVEREIGNMIND_VERSION="$VERSION"

# Backup-Ordner vor dem Start anlegen: docker-compose.yml bindet ihn als ./backups:/backups ein, und Docker legt einen fehlenden
# Bind-Mount-Quellordner unter Linux als root an - danach könnte der Benutzer weder backup-db.sh noch der cron-Job dort schreiben.
mkdir -p "${BACKUP_DIR:-./backups}"

# Optional: tägliches Backup per cron (BACKUP_TIME aus config.jsonl, Default 02:00). Ein vorhandener Eintrag wird
# ohne Nachfrage aktualisiert; sonst Nachfrage am Terminal oder SOVEREIGNMIND_BACKUP_SCHEDULE=yes|no.
setup_backup_schedule() {
  local answer="${SOVEREIGNMIND_BACKUP_SCHEDULE:-}" time="${BACKUP_TIME:-02:00}" hour minute dir
  command -v crontab >/dev/null 2>&1 || { echo "Hinweis: crontab nicht gefunden - geplantes Backup übersprungen (manuell: ./backup-db.sh)." >&2; return 0; }
  if ! crontab -l 2>/dev/null | grep -qF "$BACKUP_CRON_MARK"; then
    if [ -z "$answer" ] && [ -r /dev/tty ]; then
      echo "" >&2
      echo "Optional: Tägliches automatisches Backup einrichten (Datenbank, Schlüssel, Dokumente; 7 tägliche," >&2
      echo "4 wöchentliche und 6 monatliche Stände werden aufbewahrt, Einstellungen in config.jsonl)." >&2
      read -r -p "Jetzt einrichten? [J/n] " answer </dev/tty || answer="n"
    fi
    case "$answer" in
      "" | j | J | y | Y | yes | ja) [ -n "${SOVEREIGNMIND_BACKUP_SCHEDULE:-}" ] || [ -r /dev/tty ] || answer="n" ;;
    esac
    case "$answer" in
      "" | j | J | y | Y | yes | ja) ;;
      *) echo "==> Geplantes Backup übersprungen. Erneuter Lauf holt die Einrichtung nach (manuell: ./backup-db.sh)." >&2; return 0 ;;
    esac
  fi
  if ! [[ "$time" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    echo "Warnung: BACKUP_TIME '$time' ist keine Uhrzeit (HH:mm) - verwende 02:00." >&2
    time="02:00"
  fi
  hour="$((10#${time%%:*}))"; minute="$((10#${time##*:}))"
  dir="$(pwd)"
  mkdir -p backups
  { crontab -l 2>/dev/null | grep -vF "$BACKUP_CRON_MARK" || true
    printf '%s %s * * * cd %q && ./backup-db.sh >>backups/backup.log 2>&1 %s
' "$minute" "$hour" "$dir" "$BACKUP_CRON_MARK"
  } | crontab -
  echo "==> Geplantes Backup (cron) eingerichtet: täglich um $time. Entfernen: bash install.sh --remove-backup-schedule" >&2
}

echo "==> Ziehe Images (Version: $VERSION)" >&2
docker compose "${FILES[@]}" pull ||
  {
    echo "Fehler: docker compose pull fehlgeschlagen - Abbruch (Registry-Zugang/Internet prüfen)." >&2
    exit 1
  }

echo "==> Starte Stack" >&2
# --no-build: beim Kunden gibt es keine Build-Kontexte, die *-worker-base-Services aus docker-compose.yml
# würden sonst einen Build versuchen und `up` scheitern lassen.
docker compose "${FILES[@]}" up -d --no-build ||
  {
    echo "Fehler: docker compose up fehlgeschlagen - der Stack läuft nicht. Ausgabe oben prüfen, danach den Installer erneut starten." >&2
    exit 1
  }

# Modelle der Worker (Docling, Whisper, Piper, ggf. XTTS) liegen nicht im Image, sondern in Volumes
# und werden hier nach dem Start geladen (analog zu `ollama pull`). Ein Fehlschlag ist nur eine
# Warnung, die Worker starten trotzdem und laden bei Bedarf nach.
for worker in ingestion-worker voice-worker; do
  echo "==> Lade Modelle: $worker (ca. 1,5 GB ingestion-worker, ca. 3,2 GB voice-worker; beim ersten Mal mehrere Minuten)" >&2
  docker exec "sovereignmind-$worker" python -m app.prefetch ||
    echo "WARNUNG: Modell-Download für $worker fehlgeschlagen - später manuell nachholen: docker exec sovereignmind-$worker python -m app.prefetch" >&2
done

# Recovery-Kit (docs/pläne/schluesselverlust-wiederherstellung/02-phase-2-recovery-kit.md): Geheimnisse (Zertifikat,
# JWT_SECRET, Lizenz) getrennt vom Volume-Backup sichern. Ohne Kit sind Connector-Geheimnisse und Paketschlüssel bei
# Verlust der config.jsonl nicht wiederherstellbar. Nur mit Terminal (die Passphrase wird abgefragt), sonst Hinweis.
offer_recovery_kit() {
  [ -n "${DATAPROTECTION_CERT_PFX:-}" ] || return 0
  docker exec sovereignmind-backend test -f /data/recovery-kit.json 2>/dev/null && return 0
  {
    echo ""
    echo "WICHTIG - Recovery-Kit: Ohne eine getrennte Sicherung Ihrer Geheimnisse (DataProtection-Zertifikat, JWT_SECRET, Lizenz)"
    echo "gehen bei Verlust der config.jsonl die Connector-Geheimnisse und Paketschlüssel unwiederbringlich verloren."
  } >&2
  if [ -t 0 ] && [ -t 1 ]; then
    echo "Das Kit wird jetzt mit einer Passphrase erstellt, die nur Sie kennen (der Betreiber kann sie nicht zurücksetzen)." >&2
    bash ./recovery-kit.sh export ||
      echo "WARNUNG: Recovery-Kit nicht erstellt - bitte nachholen: bash recovery-kit.sh export" >&2
  else
    echo "Bitte in einem Terminal nachholen: bash recovery-kit.sh export" >&2
  fi
}

offer_recovery_kit

setup_backup_schedule

echo "" >&2
echo "Fertig. Chat-UI: http://localhost:${FRONTEND_PORT:-3000}" >&2
echo "Erster Start: die Seite öffnen - sie führt auf /setup (Lizenzschlüssel einfügen, Admin-Passwort vergeben)." >&2
echo "Erneut ausführen aktualisiert auf die neueste Version (idempotent, .env und config.jsonl bleiben erhalten)." >&2
