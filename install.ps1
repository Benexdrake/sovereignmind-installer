# SovereignMind Installer (Windows).
#
# Laedt die Compose-Dateien + .env-Vorlage + config.jsonl aus dem (privaten!) GitHub-Repo, loggt
# sich bei der privaten GHCR-Registry ein, pullt die vorgebauten Images und
# startet den kompletten Stack (Ollama, Qdrant, Ingestion-Worker, Backend,
# Frontend). Bash-Gegenstueck: scripts/install.sh - siehe dort fuer
# ausfuehrlichere Kommentare, dieses Skript spiegelt denselben Ablauf.
#
# Aufruf (PowerShell):
#   $env:SOVEREIGNMIND_GHCR_TOKEN = "<token>"
#   .\install.ps1
#
# Parameter/Env-Variablen: siehe scripts/install.sh (identische Namen/Defaults).
#
# GPU-Erkennung: Nvidia ueber nvidia-smi, AMD ueber Get-CimInstance Win32_VideoController (Name
# enthaelt "AMD"/"Radeon") - s. docs/plan-llamacpp-migration/04-compose-skripte.md. Im
# Ollama-Pfad (LLM_SERVER=0) reicht die AMD-Namenserkennung allein NICHT, um
# docker-compose.rocm.yml anzuhaengen (das mountet /dev/kfd + /dev/dri) - anders als beim
# Bash-Installer, der mit `[ -e /dev/kfd ]` auf nativem Linux direkt gegen das echte Geraet
# prueft, sieht Win32_VideoController nur die Windows-Hardware, nicht ob Docker Desktop/WSL2
# dieses Geraet dem Container ueberhaupt durchreicht (ueblicherweise NICHT, ROCm-unter-WSL2 ist
# auf eine enge Hardware-Liste begrenzt, s. docs/pläne/voice-tab-in-ki-einstellungen-und-gpu-diagnose.md).
# Deshalb zusaetzlich Test-AmdRocmDevicesReachable: ein Wegwerf-`docker run --device=/dev/kfd`,
# der nur bei Erfolg das Overlay anhaengt - ohne diesen Probe wuerde `docker compose up` bei
# fehlendem /dev/kfd mit einem Geraete-Fehler abbrechen (auf dieser Maschine per RX 9070 XT
# verifiziert: /dev/kfd/-dri fehlen, nur /dev/dxg ist vorhanden). Im llama.cpp-Pfad
# (LLM_SERVER=1) fuehrt erkanntes AMD stattdessen zu docker-compose.vulkan.yml (nutzt /dev/dxg,
# kein Geraete-Risiko) statt zum CPU-Fallback.
#
# VRAM-Menge (fuer die Modellauswahl, s. scripts/detect-vram.sh/install.sh): nur ueber nvidia-smi
# ermittelbar (AMD-VRAM-Abfrage unter Windows ohne rocm-smi nicht moeglich). Ohne erkannte
# Nvidia-GPU gilt derselbe konservative Fallback wie im Bash-Installer - das 8GB-Modell.

[CmdletBinding()]
param(
    [string]$Version = $(if ($env:SOVEREIGNMIND_VERSION) { $env:SOVEREIGNMIND_VERSION } else { "latest" }),
    [string]$TargetDir = $(if ($env:SOVEREIGNMIND_DIR) { $env:SOVEREIGNMIND_DIR } else { ".\sovereignmind" }),
    [string]$Ref = $(if ($env:SOVEREIGNMIND_REF) { $env:SOVEREIGNMIND_REF } else { "main" })
)

$ErrorActionPreference = "Stop"

$Repo = "Benexdrake/SovereignMind"
$Token = $env:SOVEREIGNMIND_GHCR_TOKEN
$GithubUser = if ($env:GITHUB_USER) { $env:GITHUB_USER } else { "Benexdrake" }

if (-not $Token) {
    Write-Error "SOVEREIGNMIND_GHCR_TOKEN nicht gesetzt. Siehe README.md, Abschnitt 'Installation beim Kunden'."
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker nicht gefunden. Bitte zuerst Docker Desktop installieren: https://docs.docker.com/get-docker/"
    exit 1
}
docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker-Compose-Plugin nicht gefunden ('docker compose'). Bitte Docker Desktop aktualisieren."
    exit 1
}

function Get-VramGb {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $raw = (nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($raw -match '^\s*(\d+)\s*$') {
            return [int][math]::Round([double]$Matches[1] / 1024)
        }
    }
    # AMD-VRAM-Menge ist unter Windows ohne rocm-smi nicht ermittelbar, s. Skript-Kopfkommentar -
    # dort greift der konservative 8GB-Fallback wie beim Bash-Installer.
    return $null
}

function Test-NvidiaGpu {
    return [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue) -and
        ((nvidia-smi -L 2>$null | Select-Object -First 1))
}

function Test-AmdGpu {
    $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($controller in $controllers) {
        if ($controller.Name -match 'AMD|Radeon') {
            return $true
        }
    }
    return $false
}

function Test-AmdRocmDevicesReachable {
    # Wegwerf-Container statt reiner Namenspruefung, s. Skript-Kopfkommentar: /dev/kfd/-dri
    # existieren unter Docker Desktop/WSL2 ueblicherweise nicht, auch wenn Windows eine
    # AMD-GPU meldet. docker run schlaegt dann mit einem Geraete-Fehler fehl (LASTEXITCODE <> 0).
    docker run --rm --device=/dev/kfd --device=/dev/dri busybox true 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-NvidiaDockerReachable {
    # Wegwerf-Container wie bei Test-AmdRocmDevicesReachable: nvidia-smi auf dem Host reicht nicht, Docker
    # (WSL2-Backend) muss die GPU auch durchreichen koennen, sonst scheitert `docker compose up` an
    # "could not select device driver nvidia".
    docker run --rm --gpus all busybox true 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Add-MissingConfigKeys {
    # Ein Update laedt config.jsonl nicht neu (Werte des Betreibers bleiben). Schluessel, die erst spaetere
    # Releases einfuehren, werden hier ergaenzt: nur HINZUFUEGEN, nie bestehende Werte aendern.
    param([string]$Url, [hashtable]$Headers)
    $Temp = "config.jsonl.new"
    try {
        Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $Temp -ErrorAction Stop
    }
    catch {
        Write-Warning "Aktuelle config.jsonl konnte nicht geladen werden - neue Schluessel nicht geprueft ($($_.Exception.Message))."
        return
    }
    $Known = @{}
    foreach ($Line in Get-Content "config.jsonl" -Encoding UTF8) {
        if (-not $Line.Trim()) { continue }
        try { $Entry = $Line | ConvertFrom-Json } catch { continue }
        if ($Entry.key) { $Known[[string]$Entry.key] = $true }
    }
    $Added = @()
    $NewLines = @()
    foreach ($Line in Get-Content $Temp -Encoding UTF8) {
        if (-not $Line.Trim()) { continue }
        try { $Entry = $Line | ConvertFrom-Json } catch { continue }
        if ($Entry.key -and -not $Known[[string]$Entry.key]) {
            $Added += [string]$Entry.key
            $NewLines += $Line
        }
    }
    Remove-Item $Temp -ErrorAction SilentlyContinue
    if ($NewLines.Count -eq 0) { return }
    $Existing = [System.IO.File]::ReadAllText((Join-Path (Get-Location) "config.jsonl"))
    if (-not $Existing.EndsWith("`n")) { $Existing += "`n" }
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) "config.jsonl"), $Existing + (($NewLines -join "`n") + "`n"), $Utf8NoBom)
    Write-Host "==> $($NewLines.Count) neue Konfigurationsschluessel in config.jsonl ergaenzt (Defaults, Werte pruefen): $($Added -join ', ')"
}

function Confirm-XttsLicense {
    # XTTS-v2 (GPU-Sprachausgabe) steht unter der Coqui Public Model License (nicht-kommerziell). Die Zustimmung
    # darf nicht automatisch erfolgen: einmalig mit Lizenzhinweis abfragen und in config.jsonl festhalten.
    if ($EnvValues["XTTS_LICENSE_ACCEPTED"]) { return }
    Write-Host ""
    Write-Host "Die GPU-Sprachausgabe nutzt Coqui XTTS-v2 (Coqui Public Model License, https://coqui.ai/cpml)."
    Write-Host "  Die Lizenz erlaubt nur NICHT-KOMMERZIELLE Nutzung. Ohne Zustimmung nutzt die Sprachausgabe Piper (CPU)."
    $Answer = Read-Host "Lizenz akzeptieren und XTTS-v2 aktivieren? [j/N]"
    if ($Answer -match '^(j|ja|y|yes)$') { Set-ConfigValue "XTTS_LICENSE_ACCEPTED" "1" }
    else { Set-ConfigValue "XTTS_LICENSE_ACCEPTED" "0" }
}

function Confirm-LicenseServerPrivacy {
    # Online-Aktivierung (LICENSE_SERVER_URL) uebertraegt Daten an den Lizenzserver - vor dem ersten Start
    # offenlegen und bestaetigen lassen. Ablehnen = rein offline (Lizenzdatei), Server-URL wird geleert.
    $Url = $EnvValues["LICENSE_SERVER_URL"]
    if (-not $Url) { return }
    Write-Host ""
    Write-Host "Datenschutzhinweis zur Online-Aktivierung der Lizenz:"
    Write-Host "  Die Installation meldet sich bei $Url und uebertraegt dabei: Lizenzschluessel, eine Instanz-ID"
    Write-Host "  (Hash aus Hostname und einem lokalen Geheimnis, kein Klartext-Hostname), die Produktversion und"
    Write-Host "  den Zeitpunkt der Pruefung (regelmaessiger Heartbeat). Keine Dokumente, Chats oder Nutzerdaten."
    Write-Host "  Ohne Online-Aktivierung laeuft die Installation mit einer Lizenzdatei komplett offline."
    $Answer = Read-Host "Online-Aktivierung erlauben? [J/n]"
    if ($Answer -match '^(n|nein)$') {
        Set-ConfigValue "LICENSE_SERVER_URL" ""
        Write-Host "    Online-Aktivierung deaktiviert (LICENSE_SERVER_URL geleert)."
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-HardwareAgent {
    # Optionaler, überspringbarer Schritt (s. docs/pläne/hardware-monitoring-dashboard/
    # 01-phase-0-windows-agent.md, Punkt 5): laedt die vorgebaute, self-contained
    # SovereignMind.HardwareAgent-Binary als GitHub-Release-Asset (s. docs/pläne/
    # hardware-agent-vorgebaute-binary/) und registriert sie als Windows-Dienst
    # (LibreHardwareMonitorLib braucht fuer einen Teil der Sensoren Administrator-Rechte, s.
    # Plan-Übersicht Abschnitt "Risiken"). Ohne diesen Schritt bleibt HARDWARE_AGENT_BASE_URL leer
    # und das Backend faellt auf die bisherige nvidia-smi/rocm-smi-Erkennung zurueck (Phase 1) -
    # kein Blocker fuers restliche Setup.
    param(
        [string]$Port = "5077"
    )

    Write-Host ""
    Write-Host "Optional: Hardware-Companion-Agent installieren (liefert echte AMD/Nvidia/Intel-GPU-"
    Write-Host "und Host-CPU/RAM-Werte fuers Hardware-Dashboard; laeuft als Windows-Dienst, braucht"
    Write-Host "Administrator-Rechte)."
    $Choice = Read-Host "Jetzt installieren? [j/N]"
    if ($Choice -ne "j" -and $Choice -ne "J") {
        Write-Host "==> Hardware-Agent uebersprungen - AMD/CPU/RAM zeigen im Dashboard spaeter 'nicht ermittelbar' (Nvidia-Fallback via nvidia-smi bleibt unveraendert). Erneuter Lauf dieses Skripts holt die Installation jederzeit nach."
        return
    }

    if (-not (Test-IsElevated)) {
        Write-Warning "Fuer die Dienst-Installation werden Administrator-Rechte benoetigt. Dieses Skript als Administrator erneut ausfuehren, um den Hardware-Agent zu installieren. Ueberspringe fuer jetzt."
        return
    }

    $AssetName = "SovereignMind.HardwareAgent-win-x64.exe"
    $ApiHeaders = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
    }

    Write-Host "==> Suche Hardware-Agent-Release (Ref: $Ref)"
    $Release = $null
    if ($Ref -ne "latest") {
        try {
            $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Ref" -Headers $ApiHeaders
        }
        catch {
            Write-Host "    Kein Release mit Tag '$Ref' gefunden - versuche 'latest'."
        }
    }
    if (-not $Release) {
        try {
            $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $ApiHeaders
        }
        catch {
            Write-Warning "Kein GitHub-Release gefunden - Hardware-Agent-Installation uebersprungen (Release-Workflow evtl. noch nie fuer diesen Ref gelaufen)."
            return
        }
    }

    $Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $Asset) {
        Write-Warning "Release-Asset '$AssetName' nicht im Release '$($Release.tag_name)' gefunden - Hardware-Agent-Installation uebersprungen."
        return
    }

    $AgentOutDir = "hardware-agent"
    New-Item -ItemType Directory -Force -Path $AgentOutDir | Out-Null
    $ExePath = Join-Path (Resolve-Path $AgentOutDir).Path "SovereignMind.HardwareAgent.exe"

    # Laufenden Dienst zuerst stoppen/entfernen - erst danach die .exe herunterladen. Sonst
    # haelt der laufende Prozess beim Update-Fall (Skript ein zweites Mal ausgefuehrt) die Datei
    # gesperrt und Invoke-WebRequest schlaegt mit "wird von einem anderen Prozess verwendet" fehl
    # (im Endcheck von docs/pläne/hardware-agent-vorgebaute-binary/03-phase-3-test-rollout.md
    # reproduziert).
    $ServiceName = "SovereignMind Hardware Agent"

    $Existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Host "==> Vorhandener Dienst '$ServiceName' wird aktualisiert."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        sc.exe delete "$ServiceName" | Out-Null
        Start-Sleep -Seconds 1
    }

    Write-Host "==> Lade Hardware-Agent-Binary aus Release '$($Release.tag_name)'"
    $DownloadHeaders = @{
        Authorization = "token $Token"
        Accept        = "application/octet-stream"
    }
    Invoke-WebRequest -Uri $Asset.url -Headers $DownloadHeaders -OutFile $ExePath

    New-Service -Name $ServiceName `
        -BinaryPathName "`"$ExePath`"" `
        -DisplayName $ServiceName `
        -StartupType Automatic `
        -Description "Liest CPU/RAM/GPU-Sensoren fuer das SovereignMind-Hardware-Dashboard (bindet nur an localhost)." | Out-Null
    Start-Service -Name $ServiceName

    Write-Host "==> Hardware-Agent als Windows-Dienst '$ServiceName' installiert und gestartet (Port $Port, nur localhost)."

    if (-not $EnvValues["HARDWARE_AGENT_BASE_URL"]) {
        Set-ConfigValue "HARDWARE_AGENT_BASE_URL" "http://host.docker.internal:$Port"
        Write-Host "==> HARDWARE_AGENT_BASE_URL in config.jsonl eingetragen."
    }
}

function Import-ConfigJsonl {
    # config.jsonl (docs/pläne/chat-voice-dokumente-ollama-native/07-phase-7-config-jsonl-feature-gates.md):
    # ein JSON-Objekt pro Zeile ({"key":...,"value":...,"description":...}); Zeilen ohne "key" sind
    # reine Gliederung. Nicht-leere Werte landen in $EnvValues und als Prozess-Umgebungsvariable, damit
    # `docker compose` sie fuer die ${VAR:-default}-Ausdruecke sieht. Rangfolge: Shell-Umgebung >
    # .env > config.jsonl (bereits gesetzte Werte werden nicht ueberschrieben).
    if (-not (Test-Path "config.jsonl")) { return }
    foreach ($Line in Get-Content "config.jsonl" -Encoding UTF8) {
        if (-not $Line.Trim()) { continue }
        try { $Entry = $Line | ConvertFrom-Json } catch { continue }
        if (-not $Entry.key -or -not $Entry.value) { continue }
        if ($EnvValues[$Entry.key]) { continue }
        if ([Environment]::GetEnvironmentVariable($Entry.key)) {
            $EnvValues[$Entry.key] = [Environment]::GetEnvironmentVariable($Entry.key)
            continue
        }
        $EnvValues[$Entry.key] = [string]$Entry.value
        [Environment]::SetEnvironmentVariable($Entry.key, [string]$Entry.value, "Process")
    }
}

function Set-ConfigValue([string]$Key, [string]$Value) {
    # Setzt den Wert eines vorhandenen Eintrags in config.jsonl (Beschreibung bleibt erhalten), haengt
    # sonst eine neue Zeile an.
    $Lines = @(Get-Content "config.jsonl" -Encoding UTF8)
    $Pattern = '^(\{"key":"' + [regex]::Escape($Key) + '","value":")[^"]*(")'
    $Found = $false
    $Lines = $Lines | ForEach-Object {
        if ($_ -match $Pattern) {
            $Found = $true
            $Matches[1] + $Value.Replace('$', '$$') + $Matches[2] + $_.Substring($Matches[0].Length)
        }
        else { $_ }
    }
    if (-not $Found) { $Lines += ('{"key":"' + $Key + '","value":"' + $Value + '"}') }
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) "config.jsonl"), (($Lines -join "`n") + "`n"), $Utf8NoBom)
    $EnvValues[$Key] = $Value
    [Environment]::SetEnvironmentVariable($Key, $Value, "Process")
}

function Initialize-PostgresPassword {
    # Stellt sicher, dass POSTGRES_PASSWORD gesetzt ist (docs/pläne/postgres-umstellung/phase-2-...).
    # Ist es leer, wird ein zufaelliges Passwort erzeugt und in config.jsonl gespeichert. Existiert
    # bereits ein postgres-data-Volume, wird NIE ein neues Passwort erzeugt - es passte nicht mehr
    # zum initialisierten Cluster.
    if ($EnvValues["POSTGRES_PASSWORD"]) { return }
    $Volume = docker volume ls -q --filter "name=postgres-data$"
    if ($Volume) {
        Write-Error ("POSTGRES_PASSWORD ist leer, aber das Volume postgres-data existiert bereits. Das Passwort steht im Datenbank-Cluster - " +
            "bitte den bisherigen Wert in config.jsonl eintragen (oder die Daten per 'docker compose down -v' verwerfen).")
        exit 1
    }
    $Bytes = New-Object byte[] 24
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $Rng.GetBytes($Bytes)
    $Rng.Dispose()
    # Nur alphanumerische Zeichen: unproblematisch in Connection-String, config.jsonl und .env.
    $Password = ([Convert]::ToBase64String($Bytes) -replace '[^A-Za-z0-9]', '')
    while ($Password.Length -lt 32) { $Password += ([char[]]'abcdefghjkmnpqrstuvwxyz23456789' | Get-Random) }
    Set-ConfigValue "POSTGRES_PASSWORD" $Password
    Write-Host "==> POSTGRES_PASSWORD erzeugt und in config.jsonl gespeichert."
}

function Initialize-JwtSecret {
    # Stellt sicher, dass JWT_SECRET (Signaturschluessel der Login-Tokens) gesetzt ist. Ist es leer,
    # wird ein zufaelliger Wert erzeugt und in config.jsonl gespeichert.
    if ($EnvValues["JWT_SECRET"]) { return }
    $Bytes = New-Object byte[] 48
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $Rng.GetBytes($Bytes)
    $Rng.Dispose()
    $Secret = ([Convert]::ToBase64String($Bytes) -replace '[^A-Za-z0-9]', '')
    while ($Secret.Length -lt 48) { $Secret += ([char[]]'abcdefghjkmnpqrstuvwxyz23456789' | Get-Random) }
    Set-ConfigValue "JWT_SECRET" $Secret
    Write-Host "==> JWT_SECRET erzeugt und in config.jsonl gespeichert."
}

function Get-LlamaCppCatalogRepo([string]$Key) {
    switch ($Key) {
        'qwen2.5-7b-instruct-q4_k_m' { return 'Qwen/Qwen2.5-7B-Instruct-GGUF' }
        default { return 'Qwen/Qwen2.5-14B-Instruct-GGUF' }
    }
}

function Get-LlamaCppCatalogFile([string]$Key) {
    switch ($Key) {
        'qwen2.5-7b-instruct-q4_k_m' { return 'qwen2.5-7b-instruct-q4_k_m.gguf' }
        default { return 'qwen2.5-14b-instruct-q4_k_m.gguf' }
    }
}

function Test-OllamaReachable {
    try {
        Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 3 | Out-Null
        return $true
    }
    catch { return $false }
}

function Test-OllamaListensOnAllInterfaces {
    # Der Backend-Container erreicht Ollama nur, wenn es nicht ausschliesslich auf 127.0.0.1 lauscht.
    $listeners = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
    foreach ($l in $listeners) {
        if ($l.LocalAddress -eq "0.0.0.0" -or $l.LocalAddress -eq "::") { return $true }
    }
    return $false
}

function Stop-OllamaProcesses {
    Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Start-OllamaApp {
    # Tray-App startet den Server mit; Fallback: `ollama serve` direkt.
    $AppExe = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"
    if (Test-Path $AppExe) {
        Start-Process -FilePath $AppExe -WindowStyle Hidden
        # Die App oeffnet trotzdem ihr Chat-Fenster - schliessen (Tray-App und Server laufen weiter,
        # per Test 2026-09-30 bestaetigt). Nur kurz warten; kommt kein Fenster, ist nichts zu tun.
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $app = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($app) { [void]$app.CloseMainWindow(); break }
            Start-Sleep -Milliseconds 500
        }
    }
    else {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    }
}

function Wait-OllamaReachable([int]$TimeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaReachable) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-OllamaModelTags {
    # Chat-Modell: config.jsonl/.env-Override (OLLAMA_CHAT_MODEL), sonst immer Qwen 2.5 7B (unabhaengig vom VRAM).
    # Embedding: OLLAMA_EMBEDDING_MODEL / bge-m3.
    $chatTag = $EnvValues["OLLAMA_CHAT_MODEL"]
    if (-not $chatTag) { $chatTag = "qwen2.5:7b-instruct-q4_K_M" }
    $embedTag = if ($EnvValues["OLLAMA_EMBEDDING_MODEL"]) { $EnvValues["OLLAMA_EMBEDDING_MODEL"] } else { "bge-m3" }
    return @($chatTag, $embedTag)
}

function Install-NativeOllama {
    # Phase 4 (docs/pläne/chat-voice-dokumente-ollama-native): Ollama laeuft nativ auf dem Host, nicht
    # als Container. Idempotent: bereits installiertes/korrekt konfiguriertes Ollama wird nur geprueft.
    Write-Host ""
    Write-Host "==> Pruefe native Ollama-Installation"
    $freshInstall = $false

    $installed = [bool](Get-Command ollama -ErrorAction SilentlyContinue) -or
        (Test-Path (Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"))
    if (-not $installed) {
        $Installer = Join-Path $env:TEMP "OllamaSetup.exe"
        Write-Host "    Ollama nicht gefunden - lade OllamaSetup.exe herunter (~1,5 GB)"
        # Die Fortschrittsanzeige von Invoke-WebRequest bremst grosse Downloads in Windows PowerShell 5.1
        # drastisch aus (>10 min fuer ~1,5 GB, Testlauf 2026-09-30) - deshalb curl.exe (in Windows 10/11
        # enthalten), Fallback Invoke-WebRequest ohne Fortschrittsanzeige.
        $DownloadUrl = "https://ollama.com/download/OllamaSetup.exe"
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            curl.exe -L -sS -o $Installer $DownloadUrl
            $downloadOk = ($LASTEXITCODE -eq 0)
        }
        else {
            $previousProgress = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"
            try { Invoke-WebRequest -Uri $DownloadUrl -OutFile $Installer; $downloadOk = $true }
            catch { $downloadOk = $false }
            finally { $ProgressPreference = $previousProgress }
        }
        if (-not $downloadOk) {
            Write-Warning "Download von OllamaSetup.exe fehlgeschlagen. Bitte manuell von https://ollama.com/download installieren."
            Remove-Item $Installer -ErrorAction SilentlyContinue
            return
        }
        Write-Host "    Installiere Ollama (silent)"
        # Bewusst ohne `Start-Process -Wait`: das wartet auch auf den am Ende des Setups gestarteten
        # Kindprozess (Ollama selbst) und kehrt dann nie zurueck. WaitForExit() wartet nur auf das Setup.
        $proc = Start-Process -FilePath $Installer -ArgumentList "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES" -PassThru
        $proc.WaitForExit()
        Remove-Item $Installer -ErrorAction SilentlyContinue
        if ($proc.ExitCode -ne 0) {
            Write-Warning "Ollama-Installer endete mit Exit-Code $($proc.ExitCode). Bitte manuell von https://ollama.com/download installieren."
            return
        }
        $freshInstall = $true
        # PATH dieser Sitzung um die neue Installation ergaenzen
        $env:Path += ";" + (Join-Path $env:LOCALAPPDATA "Programs\Ollama")
    }
    else {
        Write-Host "    Ollama bereits installiert."
    }

    $hostVar = [Environment]::GetEnvironmentVariable("OLLAMA_HOST", "User")
    $needsRestart = $false
    if ($hostVar -ne "0.0.0.0") {
        Write-Host "    Setze OLLAMA_HOST=0.0.0.0 (User-Scope, damit der Backend-Container Ollama erreicht)"
        [Environment]::SetEnvironmentVariable("OLLAMA_HOST", "0.0.0.0", "User")
        $needsRestart = $true
    }
    $env:OLLAMA_HOST = "0.0.0.0"

    # Nach einer frischen Installation startet das Ollama-Setup selbst eine Instanz - ohne OLLAMA_HOST (nur
    # Loopback), und ggf. erst nach der Erreichbarkeits-Pruefung (Testlauf 2026-09-30: zweite Instanz scheiterte
    # am belegten Port, die Loopback-Instanz blieb). Deshalb immer beenden und mit OLLAMA_HOST neu starten.
    if ($freshInstall -or $needsRestart -or -not (Test-OllamaReachable) -or -not (Test-OllamaListensOnAllInterfaces)) {
        Write-Host "    Starte Ollama (neu), damit OLLAMA_HOST=0.0.0.0 wirksam wird"
        Stop-OllamaProcesses
        Start-OllamaApp
    }

    if (-not (Wait-OllamaReachable)) {
        Write-Warning "Ollama ist nach 60 s nicht unter http://localhost:11434 erreichbar - Modell-Pull uebersprungen."
        return
    }
    if (-not (Test-OllamaListensOnAllInterfaces)) {
        Write-Warning "Ollama lauscht nur auf Loopback - der Backend-Container wird es nicht erreichen. Ollama beenden (Tray-Icon -> Quit) und neu starten, OLLAMA_HOST=0.0.0.0 muss gesetzt sein."
    }
    else {
        Write-Host "    Ollama lauscht auf 0.0.0.0:11434."
    }

    foreach ($tag in (Get-OllamaModelTags)) {
        Write-Host "==> ollama pull $tag"
        ollama pull $tag
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ollama pull $tag fehlgeschlagen - spaeter manuell nachholen."
        }
    }
}

function Write-LlamaCppAmdWarning {
    if (Test-AmdGpu -and -not (Test-NvidiaGpu)) {
        Write-Warning "llama.cpp (LLM_SERVER=1) mit GPU-Beschleunigung wird unter Windows + AMD nicht unterstuetzt (Docker-Desktop-WSL2-D3D12, s. docs/offen.md) - es liefe im CPU-Modus. Empfehlung: LLM_SERVER=0 (Ollama) in config.jsonl setzen."
    }
}

Write-Host "==> Login bei ghcr.io"
# Kein "$Token | docker login": Windows PowerShell 5.1 haengt beim Pipen "\r\n" an, GHCR lehnt den Token dann mit "denied" ab.
cmd /c "<nul set /p =$Token| docker login ghcr.io -u $GithubUser --password-stdin"
if ($LASTEXITCODE -ne 0) {
    Write-Error "docker login bei ghcr.io fehlgeschlagen. Token pruefen (Scope read:packages)."
    exit 1
}

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
Push-Location $TargetDir
try {
    Write-Host "==> Lade Compose-Dateien von GitHub (Ref: $Ref)"
    $Files = @(
        "docker-compose.yml",
        "docker-compose.images.yml",
        "docker-compose.nvidia.yml",
        "docker-compose.rocm.yml",
        "docker-compose.cuda.yml",
        "docker-compose.vulkan.yml",
        "docker-compose.local-llamacpp.yml",
        ".env.example"
    )
    $Headers = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github.raw"
    }
    foreach ($f in $Files) {
        Write-Host "    $f"
        $Url = "https://api.github.com/repos/$Repo/contents/${f}?ref=$Ref"
        Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $f
    }

    # Backup-/Restore-Skripte (liegen im Repo unter scripts/, hier flach neben den Compose-Dateien).
    foreach ($f in "backup-db.ps1", "restore-db.ps1") {
        Write-Host "    $f"
        Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/contents/scripts/${f}?ref=$Ref" -Headers $Headers -OutFile $f
    }

    # models.json (Modell-Katalog, Phase 2a, docs/pläne/log-modelle-hardware-anpassungen/02a-...)
    # nur laden, wenn noch keine vorhanden ist - der Admin kann die Datei nach der Erstinstallation
    # bearbeiten (neues Modell ergaenzen, VRAM-Wert korrigieren), ein erneuter Installer-/Update-Lauf
    # soll das nicht ueberschreiben (anders als die Compose-Dateien, die immer den Release-Stand
    # bekommen).
    if (-not (Test-Path "models.json")) {
        Write-Host "    models.json"
        $ModelsJsonUrl = "https://api.github.com/repos/$Repo/contents/models.json?ref=$Ref"
        Invoke-WebRequest -Uri $ModelsJsonUrl -Headers $Headers -OutFile "models.json"
    }
    else {
        Write-Host "==> Vorhandene models.json unveraendert uebernommen."
    }

    # config.jsonl (zentrale, nicht geheime Konfiguration) nur bei der Erstinstallation laden - ein
    # Update soll die Werte des Betreibers (Impressum, Ports, Connector-Hosts, ...) nicht ueberschreiben.
    # Fehlende neue Schluessel fangen die Defaults in docker-compose.yml ab.
    $ConfigIsNew = -not (Test-Path "config.jsonl")
    if ($ConfigIsNew) {
        Write-Host "    config.jsonl"
        $ConfigUrl = "https://api.github.com/repos/$Repo/contents/config.jsonl?ref=$Ref"
        Invoke-WebRequest -Uri $ConfigUrl -Headers $Headers -OutFile "config.jsonl"
    }
    else {
        Write-Host "==> Vorhandene config.jsonl uebernommen (Werte bleiben unveraendert)."
        Add-MissingConfigKeys -Url "https://api.github.com/repos/$Repo/contents/config.jsonl?ref=$Ref" -Headers $Headers
    }

    $EnvIsNew = -not (Test-Path ".env")
    if ($EnvIsNew) {
        Copy-Item ".env.example" ".env"
        Write-Host "==> .env aus Vorlage angelegt (nur Geheimnisse). Ports, Impressum usw. stehen in config.jsonl."
    }
    else {
        Write-Host "==> Vorhandene .env unveraendert uebernommen."
    }

    $EnvValues = @{}
    Get-Content ".env" | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $EnvValues[$Matches[1]] = $Matches[2]
        }
    }
    Import-ConfigJsonl
    Confirm-LicenseServerPrivacy
    Initialize-PostgresPassword
    Initialize-JwtSecret

    # Inferenz-Backend abfragen (s. docs/plan-llamacpp-migration/00-overview.md) - nur bei einer
    # frisch geladenen config.jsonl, damit ein erneuter Lauf (idempotent) nicht erneut fragt bzw. einen
    # bewusst gesetzten LLM_SERVER-Wert nicht ueberschreibt.
    if ($ConfigIsNew -and -not (Select-String -Path ".env" -Pattern '^\s*LLM_SERVER\s*=' -Quiet)) {
        Write-Host ""
        Write-Host "Welches Inferenz-Backend soll laufen?"
        Write-Host "  0 = Ollama (Standard, unveraendertes Verhalten)"
        Write-Host "  1 = llama.cpp (neu, s. docs/plan-llamacpp-migration)"
        $Choice = Read-Host "LLM_SERVER [0]"
        if ($Choice -ne "1") { $Choice = "0" }
        Set-ConfigValue "LLM_SERVER" $Choice
    }
    $LlmServer = if ($EnvValues["LLM_SERVER"]) { $EnvValues["LLM_SERVER"] } else { "0" }

    $ComposeFiles = @("-f", "docker-compose.yml", "-f", "docker-compose.images.yml")
    $ComposeArgs = @()
    $LocalLlamaCpp = $false

    switch ($LlmServer) {
        "0" {
            # Ollama laeuft nativ auf dem Host (kein Container), s. docs/pläne/chat-voice-dokumente-ollama-native.
            Install-NativeOllama

            # GPU-Durchreichung fuer voice-worker (STT/TTS) und GPU-Erkennung im Backend (Nvidia). Ollama selbst
            # laeuft nativ und braucht das Overlay nicht. ROCm-Overlay gibt es hier bewusst nicht (nur nativer Linux-Host).
            if ((Test-NvidiaGpu) -and (Test-NvidiaDockerReachable)) {
                Write-Host "GPU erkannt: Nvidia - reiche sie an voice-worker/backend durch (docker-compose.nvidia.yml)"
                $ComposeFiles += @("-f", "docker-compose.nvidia.yml")
                Confirm-XttsLicense
            }
        }
        "1" {
            Write-LlamaCppAmdWarning
            $LocalLlamaCpp = $true
            $ComposeArgs += @("--profile", "local-llamacpp")
            $ComposeFiles += @("-f", "docker-compose.local-llamacpp.yml")

            if (Test-NvidiaGpu) {
                Write-Host "GPU erkannt: Nvidia (nvidia-smi vorhanden) - nutze docker-compose.cuda.yml"
                $ComposeFiles += @("-f", "docker-compose.cuda.yml")
            }
            elseif (Test-AmdGpu) {
                Write-Host "GPU erkannt: AMD (Win32_VideoController) - nutze docker-compose.vulkan.yml (bekannte Einschraenkung: erreicht die GPU aktuell noch nicht, s. docs/plan-llamacpp-migration/01-spike-verifikation.md)"
                $ComposeFiles += @("-f", "docker-compose.vulkan.yml")
            }
            else {
                Write-Host "Keine unterstuetzte GPU erkannt - llama.cpp laeuft im CPU-Modus"
            }
        }
        default {
            Write-Error "Nicht unterstuetzter Wert fuer LLM_SERVER: '$LlmServer'. Unterstuetzt werden aktuell 0 (Ollama) und 1 (llama.cpp)."
            exit 1
        }
    }

    $env:SOVEREIGNMIND_VERSION = $Version
    $env:LLM_SERVER = $LlmServer

    Write-Host "==> Ziehe Images (Version: $Version)"
    docker compose @ComposeFiles @ComposeArgs pull

    if ($LocalLlamaCpp) {
        # Kein separater Pull-Container noetig - llm-chat/llm-embed laden ihr Modell selbst beim
        # ersten Start (s. scripts/install.sh/compose-up.sh).
        $VramGb = Get-VramGb
        $Model16Gb = if ($EnvValues["LLM_CHAT_MODEL_16GB"]) { $EnvValues["LLM_CHAT_MODEL_16GB"] } else { "qwen2.5-14b-instruct-q4_k_m" }
        $Model8Gb = if ($EnvValues["LLM_CHAT_MODEL_8GB"]) { $EnvValues["LLM_CHAT_MODEL_8GB"] } else { "qwen2.5-7b-instruct-q4_k_m" }
        $ChatModelKey = if ($VramGb -ge 16) { $Model16Gb } else { $Model8Gb }

        $env:LLM_CHAT_MODEL_KEY = $ChatModelKey
        $env:LLM_CHAT_HF_REPO = if ($EnvValues["LLM_CHAT_HF_REPO"]) { $EnvValues["LLM_CHAT_HF_REPO"] } else { Get-LlamaCppCatalogRepo $ChatModelKey }
        $env:LLM_CHAT_HF_FILE = if ($EnvValues["LLM_CHAT_HF_FILE"]) { $EnvValues["LLM_CHAT_HF_FILE"] } else { Get-LlamaCppCatalogFile $ChatModelKey }

        $VramGbLabel = if ($null -ne $VramGb) { $VramGb } else { "unbekannt" }
        Write-Host "Zu ladendes Chat-Modell: $ChatModelKey (erkannte VRAM-Menge: $VramGbLabel GB)"
        Write-Host "Hinweis: llm-chat/llm-embed laden ihr Modell beim ersten Start automatisch von Hugging Face (kann mehrere Minuten dauern) - Fortschritt mit 'docker compose logs -f llm-chat' verfolgen."
    }

    Write-Host "==> Starte Stack"
    docker compose @ComposeFiles @ComposeArgs up -d

    # Modelle der Worker liegen in Volumes, nicht im Image (analog zu ollama pull). Fehlschlag = nur
    # Warnung, die Worker laden bei Bedarf nach.
    foreach ($Worker in @("ingestion-worker", "voice-worker")) {
        Write-Host "==> Lade Modelle: $Worker (beim ersten Mal mehrere Minuten)"
        docker exec "sovereignmind-$Worker" python -m app.prefetch
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Modell-Download fuer $Worker fehlgeschlagen - spaeter manuell nachholen: docker exec sovereignmind-$Worker python -m app.prefetch"
        }
    }

    Install-HardwareAgent

    $FrontendPort = if ($EnvValues["FRONTEND_PORT"]) { $EnvValues["FRONTEND_PORT"] } else { "3000" }
    Write-Host ""
    Write-Host "Fertig. Chat-UI: http://localhost:$FrontendPort"
    Write-Host "Erster Start: die Seite oeffnen - sie fuehrt auf /setup (Lizenzschluessel einfuegen, Admin-Passwort vergeben)."
    Write-Host "Erneut ausfuehren aktualisiert auf die neueste Version (idempotent, .env und config.jsonl bleiben erhalten)."
}
finally {
    Pop-Location
}
