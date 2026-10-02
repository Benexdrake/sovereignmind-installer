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
#
# Env-Variablen:
#   SOVEREIGNMIND_GHCR_TOKEN  Pflicht. GitHub-Token mit Zugriff auf "Contents"
#                             (privates Repo lesen) und "Packages"
#                             (GHCR-Images ziehen) - klassischer PAT mit Scopes
#                             `repo` + `read:packages`, oder Fine-grained-Token
#                             mit "Contents: Read-only" + "Packages: Read-only".
#   GITHUB_USER               Optional. Benutzername für `docker login`, Default "Benexdrake".
#   SOVEREIGNMIND_VERSION      Optional. Image-Tag, Default "latest".
#   SOVEREIGNMIND_DIR          Optional. Zielverzeichnis, Default "./sovereignmind".
#   SOVEREIGNMIND_REF          Optional. Git-Ref/Branch/Tag für die
#                             Compose-Dateien, Default "main".
#
# Details/Hintergrund der Design-Entscheidungen:
# docs/anpassungen-plan/phase-5-installer-registry.md

set -euo pipefail

REPO="Benexdrake/SovereignMind"
REF="${SOVEREIGNMIND_REF:-main}"
TARGET_DIR="${SOVEREIGNMIND_DIR:-./sovereignmind}"
VERSION="${SOVEREIGNMIND_VERSION:-latest}"

if [ -z "${SOVEREIGNMIND_GHCR_TOKEN:-}" ]; then
  echo "Fehler: SOVEREIGNMIND_GHCR_TOKEN nicht gesetzt." >&2
  echo "Siehe README.md, Abschnitt 'Installation beim Kunden', für die Token-Erstellung." >&2
  exit 1
fi
GITHUB_USER="${GITHUB_USER:-Benexdrake}"

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

echo "==> Lade Compose-Dateien von GitHub (Ref: $REF)" >&2
for f in docker-compose.yml docker-compose.images.yml docker-compose.nvidia.yml \
  docker-compose.rocm.yml docker-compose.cuda.yml docker-compose.vulkan.yml \
  docker-compose.local-llamacpp.yml .env.example; do
  echo "    $f" >&2
  curl -fsSL \
    -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO}/contents/${f}?ref=${REF}" \
    -o "$f"
done

# models.json (Modell-Katalog, Phase 2a, docs/pläne/log-modelle-hardware-anpassungen/02a-...) nur
# laden, wenn noch keine vorhanden ist - der Admin kann die Datei nach der Erstinstallation
# bearbeiten (neues Modell ergänzen, VRAM-Wert korrigieren), ein erneuter Installer-/Update-Lauf
# soll das nicht überschreiben (anders als die Compose-Dateien, die immer den Release-Stand
# bekommen).
if [ ! -f models.json ]; then
  echo "    models.json" >&2
  curl -fsSL \
    -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO}/contents/models.json?ref=${REF}" \
    -o models.json
else
  echo "==> Vorhandene models.json unveraendert uebernommen." >&2
fi

# config.jsonl (zentrale, nicht geheime Konfiguration, docs/pläne/chat-voice-dokumente-ollama-native/
# 07-phase-7-config-jsonl-feature-gates.md) ebenfalls nur bei der Erstinstallation laden - der
# Betreiber trägt dort Impressum, Ports, Connector-Hosts usw. ein, ein Update soll das nicht
# überschreiben. Fehlende neue Schlüssel fangen die Defaults in docker-compose.yml ab.
if [ ! -f config.jsonl ]; then
  echo "    config.jsonl" >&2
  curl -fsSL     -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}"     -H "Accept: application/vnd.github.raw"     "https://api.github.com/repos/${REPO}/contents/config.jsonl?ref=${REF}"     -o config.jsonl
else
  echo "==> Vorhandene config.jsonl uebernommen (Werte bleiben unveraendert)." >&2
  # Neue Schlüssel späterer Releases ergänzen (nur hinzufügen, nie bestehende Werte ändern).
  if curl -fsSL     -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}"     -H "Accept: application/vnd.github.raw"     "https://api.github.com/repos/${REPO}/contents/config.jsonl?ref=${REF}"     -o config.jsonl.new; then
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

# scripts/*.sh liegen im Repo unter scripts/, werden hier aber flach abgelegt (wie die
# Compose-Dateien) - der Installer geht nicht von einem vollständigen Repo-Checkout aus.
for f in detect-vram.sh ensure-docker.sh llamacpp-catalog.sh load-config.sh backup-db.sh restore-db.sh; do
  echo "    $f" >&2
  curl -fsSL \
    -H "Authorization: token ${SOVEREIGNMIND_GHCR_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/${REPO}/contents/scripts/${f}?ref=${REF}" \
    -o "$f"
done

# shellcheck disable=SC1091
source detect-vram.sh
# shellcheck disable=SC1091
source ensure-docker.sh
# shellcheck disable=SC1091
source llamacpp-catalog.sh
ensure_docker_running

vram_label() {
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "erkannter Unified-Memory-Speicher"
  else
    echo "erkannte VRAM-Menge"
  fi
}

# AMD-Geräte-Checks: Auf nativem Linux liegt /dev/kfd (ROCm) bzw. /dev/dxg (WSL2-Vulkan) direkt
# im Host-Dateisystem, ein einfacher [ -e ]-Test reicht. Unter Windows/Git-Bash (uname -s
# MINGW*/MSYS*) läuft der Docker-Daemon dagegen in einer eigenen WSL2-VM, die von der
# Windows-Bash aus nicht einsehbar ist - ein [ -e /dev/kfd ]-Test dort schlägt IMMER fehl, ganz
# unabhängig von der tatsächlichen Hardware/Docker-Konfiguration (s. scripts/compose-up.sh sowie
# docs/pläne/voice-tab-in-ki-einstellungen-und-gpu-diagnose.md, dort auf einer RX 9070 XT
# verifiziert). Deshalb dort stattdessen ein Wegwerf-Containerstart als echter
# Erreichbarkeits-Test (analog install.ps1/Test-AmdRocmDevicesReachable) - docker run schlägt
# bei fehlendem Gerät mit Exit-Code <> 0 fehl, statt den Compose-Start später mit einem
# Geräte-Fehler abzubrechen.
is_windows_bash() {
  [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]
}

has_amd_rocm_device() {
  if is_windows_bash; then
    # MSYS_NO_PATHCONV=1: Git Bash wandelt "/dev/kfd" sonst wie einen Unix-Pfad in einen
    # Windows-Pfad um, bevor er als --device-Argument bei Docker ankommt ("...adding custom
    # device \"C\": no such file or directory") - der Erreichbarkeits-Test würde dadurch IMMER
    # fehlschlagen, unabhängig von der tatsächlichen Docker-/Hardware-Konfiguration.
    MSYS_NO_PATHCONV=1 docker run --rm --device=/dev/kfd --device=/dev/dri busybox true >/dev/null 2>&1
  else
    [ -e /dev/kfd ]
  fi
}

has_amd_dxg_device() {
  if is_windows_bash; then
    # s. Kommentar in has_amd_rocm_device - derselbe Git-Bash-Pfadumwandlungs-Bug.
    MSYS_NO_PATHCONV=1 docker run --rm --device=/dev/dxg busybox true >/dev/null 2>&1
  else
    [ -e /dev/dxg ]
  fi
}

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> .env aus Vorlage angelegt (nur Geheimnisse). Ports, Impressum usw. stehen in config.jsonl." >&2
else
  echo "==> Vorhandene .env unverändert übernommen." >&2
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

LLM_SERVER="${LLM_SERVER:-0}"

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

warn_llamacpp_amd_windows() {
  # Nur Windows/Git-Bash: dort läuft Docker in WSL2, AMD-GPU-Passthrough für llama.cpp fehlt.
  if is_windows_bash && ! { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; } &&
    command -v powershell.exe >/dev/null 2>&1 &&
    powershell.exe -NoProfile -Command "Get-CimInstance Win32_VideoController | ForEach-Object Name" 2>/dev/null | grep -Eiq 'AMD|Radeon'; then
    echo "WARNUNG: llama.cpp (LLM_SERVER=1) mit GPU-Beschleunigung wird unter Windows + AMD nicht unterstützt (Docker-Desktop-WSL2-D3D12, s. docs/offen.md) - es läuft im CPU-Modus. Empfehlung: LLM_SERVER=0 (Ollama) in config.jsonl setzen." >&2
  fi
}

FILES=(-f docker-compose.yml -f docker-compose.images.yml)
COMPOSE_ARGS=()
LOCAL_LLAMACPP=0

case "$LLM_SERVER" in
0)
  # Ollama läuft nativ auf dem Host (kein Container), s. docs/pläne/chat-voice-dokumente-ollama-native.
  ensure_native_ollama

  # GPU-Durchreichung für voice-worker (STT/TTS) und GPU-Erkennung im Backend (Nvidia). Ollama selbst läuft
  # nativ und braucht das Overlay nicht. Ein ROCm-Overlay gibt es hier bewusst nicht (llama.cpp-Pfad).
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1     && docker run --rm --gpus all busybox true >/dev/null 2>&1; then
    echo "GPU erkannt: Nvidia - reiche sie an voice-worker/backend durch (docker-compose.nvidia.yml)" >&2
    FILES+=(-f docker-compose.nvidia.yml)

    # XTTS-v2 steht unter der Coqui Public Model License (nicht-kommerziell): Zustimmung nie automatisch,
    # sondern einmalig mit Lizenzhinweis abfragen und in config.jsonl festhalten.
    if [ -z "${XTTS_LICENSE_ACCEPTED:-}" ]; then
      {
        echo ""
        echo "Die GPU-Sprachausgabe nutzt Coqui XTTS-v2 (Coqui Public Model License, https://coqui.ai/cpml)."
        echo "  Die Lizenz erlaubt nur NICHT-KOMMERZIELLE Nutzung. Ohne Zustimmung nutzt die Sprachausgabe Piper (CPU)."
      } >&2
      read -r -p "Lizenz akzeptieren und XTTS-v2 aktivieren? [j/N] " xtts_answer </dev/tty || xtts_answer=""
      case "$xtts_answer" in
        j|J|ja|Ja|y|Y|yes) config_set XTTS_LICENSE_ACCEPTED 1 ;;
        *) config_set XTTS_LICENSE_ACCEPTED 0 ;;
      esac
    fi
  fi
  ;;
1)
  warn_llamacpp_amd_windows
  LOCAL_LLAMACPP=1
  COMPOSE_ARGS+=(--profile local-llamacpp)
  FILES+=(-f docker-compose.local-llamacpp.yml)

  # Erkennungsreihenfolge wie scripts/compose-up.sh (s. dort für Details/Risiken).
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "macOS erkannt – Docker Desktop hat keinen Zugriff auf die Apple-GPU (kein Metal-Passthrough in Containern möglich). Läuft im CPU-Modus; dank Unified Memory ist das kein Fehlzustand." >&2
  elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    echo "GPU erkannt: Nvidia (nvidia-smi vorhanden) – nutze docker-compose.cuda.yml" >&2
    FILES+=(-f docker-compose.cuda.yml)
  elif has_amd_rocm_device; then
    echo "GPU erkannt: AMD/ROCm (/dev/kfd erreichbar) – nutze docker-compose.rocm.yml" >&2
    FILES+=(-f docker-compose.rocm.yml)
  elif is_windows_bash && has_amd_dxg_device; then
    echo "GPU erkannt: AMD via Vulkan/dxg (Windows/WSL2) – nutze docker-compose.vulkan.yml (bekannte Einschränkung: erreicht die GPU noch nicht, s. docs/plan-llamacpp-migration/01-spike-verifikation.md)" >&2
    FILES+=(-f docker-compose.vulkan.yml)
  else
    echo "Keine unterstützte GPU erkannt – llama.cpp läuft im CPU-Modus" >&2
  fi
  ;;
*)
  echo "Fehler: Nicht unterstützter Wert für LLM_SERVER: '$LLM_SERVER'. Unterstützt werden aktuell 0 (Ollama) und 1 (llama.cpp)." >&2
  exit 1
  ;;
esac

export SOVEREIGNMIND_VERSION="$VERSION"

echo "==> Ziehe Images (Version: $VERSION)" >&2
docker compose "${FILES[@]}" "${COMPOSE_ARGS[@]}" pull

if [ "$LOCAL_LLAMACPP" = "1" ]; then
  # Kein separater Pull-Container nötig (s. scripts/compose-up.sh) - llm-chat/llm-embed laden ihr
  # Modell selbst beim ersten Start.
  vram_gb="$(detect_vram_gb)"
  if [ -n "$vram_gb" ] && [ "$vram_gb" -ge 16 ]; then
    LLM_CHAT_MODEL_KEY="${LLM_CHAT_MODEL_16GB:-qwen2.5-14b-instruct-q4_k_m}"
  else
    LLM_CHAT_MODEL_KEY="${LLM_CHAT_MODEL_8GB:-qwen2.5-7b-instruct-q4_k_m}"
  fi
  export LLM_CHAT_MODEL_KEY
  export LLM_CHAT_HF_REPO="${LLM_CHAT_HF_REPO:-$(llamacpp_catalog_repo "$LLM_CHAT_MODEL_KEY")}"
  export LLM_CHAT_HF_FILE="${LLM_CHAT_HF_FILE:-$(llamacpp_catalog_file "$LLM_CHAT_MODEL_KEY")}"
  echo "Zu ladendes Chat-Modell: $LLM_CHAT_MODEL_KEY ($(vram_label): ${vram_gb:-unbekannt} GB)" >&2
  echo "Hinweis: llm-chat/llm-embed laden ihr Modell beim ersten Start automatisch von Hugging Face (kann mehrere Minuten dauern) - Fortschritt mit 'docker compose logs -f llm-chat' verfolgen." >&2
fi

echo "==> Starte Stack" >&2
docker compose "${FILES[@]}" "${COMPOSE_ARGS[@]}" up -d

echo "" >&2
echo "Fertig. Chat-UI: http://localhost:${FRONTEND_PORT:-3000}" >&2
echo "Erster Start: die Seite öffnen - sie führt auf /setup (Lizenzschlüssel einfügen, Admin-Passwort vergeben)." >&2
echo "Erneut ausführen aktualisiert auf die neueste Version (idempotent, .env und config.jsonl bleiben erhalten)." >&2
