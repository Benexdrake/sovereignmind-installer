# SovereignMind Installer (Windows).
#
# Laedt die Compose-Dateien + .env-Vorlage + config.jsonl aus dem (privaten!) GitHub-Repo, loggt
# sich bei der privaten GHCR-Registry ein, pullt die vorgebauten Images und
# startet den kompletten Stack (Ollama, Qdrant, Ingestion-Worker, Backend,
# Frontend). Bash-Gegenstueck: 9.Support/scripts/install.sh - siehe dort fuer
# ausfuehrlichere Kommentare, dieses Skript spiegelt denselben Ablauf.
#
# Aufruf (PowerShell):
#   $env:SOVEREIGNMIND_GHCR_TOKEN = "<token>"
#   .\install.ps1
#
# Parameter/Env-Variablen: siehe 9.Support/scripts/install.sh (identische Namen/Defaults).
#
# GPU-Erkennung: Nvidia ueber nvidia-smi plus Test-NvidiaDockerReachable (ein Wegwerf-`docker run
# --gpus all`) - nur dann wird docker-compose.nvidia.yml angehaengt, sonst wuerde `docker compose up`
# an "could not select device driver nvidia" scheitern. AMD-GPUs werden nicht an Container
# durchgereicht (ROCm unter Docker Desktop/WSL2 ist auf eine enge Hardware-Liste begrenzt, s.
# docs/pläne/voice-tab-in-ki-einstellungen-und-gpu-diagnose.md); Ollama laeuft ohnehin nativ und
# erkennt die GPU selbst.

[CmdletBinding()]
param(
    [string]$Version = $(if ($env:SOVEREIGNMIND_VERSION) { $env:SOVEREIGNMIND_VERSION } else { "latest" }),
    [string]$TargetDir = $(if ($env:SOVEREIGNMIND_DIR) { $env:SOVEREIGNMIND_DIR } else { ".\sovereignmind" }),
    [string]$Ref = $(if ($env:SOVEREIGNMIND_REF) { $env:SOVEREIGNMIND_REF } else { "main" }),
    # Entfernt nur die geplante Backup-Aufgabe (Deinstallation) und beendet das Skript.
    [switch]$RemoveBackupTask
)

$ErrorActionPreference = "Stop"

# Der Name der Aufgabe in der Windows-Aufgabenplanung (docs/pläne/postgres-haertung-und-backup/phase-2-...).
$BackupTaskName = "SovereignMind-Backup"

if ($RemoveBackupTask) {
    if (Get-ScheduledTask -TaskName $BackupTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $BackupTaskName -Confirm:$false
        Write-Host "==> Aufgabe '$BackupTaskName' entfernt. Vorhandene Backups bleiben unveraendert."
    }
    else {
        Write-Host "==> Aufgabe '$BackupTaskName' ist nicht eingerichtet - nichts zu tun."
    }
    return
}

Write-Host ""
Write-Host "    .-`"`"-."
Write-Host "   /  ()  \    SovereignMind"
Write-Host "   \      /    On-Premise KI-Gateway"
Write-Host "    '-..-'"
Write-Host ""

$Repo = "Benexdrake/SovereignMind"
$Token = $env:SOVEREIGNMIND_GHCR_TOKEN
$GithubUser = if ($env:GITHUB_USER) { $env:GITHUB_USER } else { "Benexdrake" }

# Portal-Modus: Dateien und Images kommen vom Lizenzserver des Betreibers, der Lizenzschluessel ersetzt den GitHub-Token.
$PortalUrl = if ($env:SOVEREIGNMIND_PORTAL_URL) { $env:SOVEREIGNMIND_PORTAL_URL.TrimEnd('/') } else { "" }
$LicenseKey = $env:SOVEREIGNMIND_LICENSE_KEY
$PortalHost = if ($PortalUrl) { ($PortalUrl -replace '^[a-zA-Z]+://', '') } else { "" }

if ($PortalUrl) {
    if (-not $LicenseKey) {
        Write-Error "SOVEREIGNMIND_PORTAL_URL ist gesetzt, aber SOVEREIGNMIND_LICENSE_KEY fehlt."
        exit 1
    }
}
elseif (-not $Token) {
    Write-Error "SOVEREIGNMIND_GHCR_TOKEN nicht gesetzt. Siehe README.md, Abschnitt 'Installation beim Kunden'."
    exit 1
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-DockerDaemon([int]$TimeoutSeconds = 300) {
    # Windows PowerShell 5.1 macht aus stderr-Ausgaben nativer Programme (z. B. Docker-Warnungen) unter "Stop" einen Abbruch.
    $ErrorActionPreference = "Continue"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Install-Prerequisites {
    # Windows PowerShell 5.1 macht aus stderr-Ausgaben nativer Programme (z. B. Docker-Warnungen) unter "Stop" einen Abbruch.
    $ErrorActionPreference = "Continue"
    # Frisch aufgesetztes Windows: WSL2 und Docker Desktop werden bei Bedarf installiert (winget), Docker Desktop
    # gestartet und auf den Daemon gewartet. Idempotent - ist alles da, bleibt es bei Pruefungen. Nach der
    # WSL-/Docker-Erstinstallation ist oft ein Neustart noetig: dann Hinweis und Abbruch, danach erneut starten.
    # Nicht automatisch: der Nvidia-Treiber (nur Warnung).
    $DockerBin = "C:\Program Files\Docker\Docker\resources\bin"
    $DockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    $DockerKnown = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    wsl.exe --version 2>$null | Out-Null
    $WslOk = ($LASTEXITCODE -eq 0)
    if (-not $WslOk -or -not $DockerKnown) {
        if (-not (Test-IsElevated)) {
            Write-Error "WSL2/Docker Desktop fehlen und muessen installiert werden - bitte dieses Skript in einer PowerShell als Administrator starten."
            exit 1
        }
    }

    if (-not $WslOk) {
        Write-Host "==> Installiere WSL2 (wsl --install --no-distribution)"
        wsl.exe --install --no-distribution
        if ($LASTEXITCODE -ne 0) {
            Write-Error "WSL-Installation fehlgeschlagen (Virtualisierung im BIOS aktiv?). Danach Skript erneut starten."
            exit 1
        }
        Write-Warning "WSL2 wurde installiert. Bitte Windows NEU STARTEN und dieses Skript danach erneut ausfuehren."
        exit 0
    }
    else {
        # Docker Desktop braucht einen aktuellen WSL-Kernel (Daemon startet sonst nicht).
        wsl.exe --update 2>$null | Out-Null
    }

    if (-not $DockerKnown) {
        if (-not (Test-Path $DockerExe)) {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                Write-Error "Docker Desktop fehlt und winget ist nicht verfuegbar. Bitte manuell installieren: https://docs.docker.com/get-docker/"
                exit 1
            }
            Write-Host "==> Installiere Docker Desktop (winget)"
            Write-Host "    Hinweis: Docker Desktop ist fuer Unternehmen mit >250 Mitarbeitern oder >10 Mio. USD Umsatz kostenpflichtig."
            winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --silent
            if ($LASTEXITCODE -ne 0 -and -not (Test-Path $DockerExe)) {
                Write-Error "Installation von Docker Desktop fehlgeschlagen. Bitte manuell installieren: https://docs.docker.com/get-docker/"
                exit 1
            }
        }
        $env:Path += ";$DockerBin"
    }

    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $DockerExe) {
            Write-Host "==> Starte Docker Desktop und warte auf den Daemon (beim ersten Start ggf. Lizenzdialog in Docker Desktop bestaetigen)"
            Start-Process -FilePath $DockerExe
        }
        if (-not (Wait-DockerDaemon)) {
            Write-Error "Der Docker-Daemon ist nach 5 Minuten nicht erreichbar. Docker Desktop oeffnen, Lizenz bestaetigen bzw. ggf. Windows neu starten, dann Skript erneut ausfuehren."
            exit 1
        }
    }

    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue) -and
        (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' })) {
        Write-Warning "Nvidia-GPU gefunden, aber kein Nvidia-Treiber (nvidia-smi fehlt) - Treiber von https://www.nvidia.com/drivers installieren, sonst laeuft die Sprachausgabe auf der CPU."
    }
}

Install-Prerequisites

docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker-Compose-Plugin nicht gefunden ('docker compose'). Bitte Docker Desktop aktualisieren."
    exit 1
}

function Get-DownloadSource {
    # Quelle einer Repo-Datei: privates GitHub-Repo (Token) oder im Portal-Modus der Lizenzserver (Lizenzschluessel).
    param([string]$RepoPath)
    if ($PortalUrl) {
        return @{
            Url     = "$PortalUrl/api/dist/$(Split-Path $RepoPath -Leaf)"
            Headers = @{ "X-License-Key" = $LicenseKey }
        }
    }
    return @{
        Url     = "https://api.github.com/repos/$Repo/contents/${RepoPath}?ref=$Ref"
        Headers = @{ Authorization = "token $Token"; Accept = "application/vnd.github.raw" }
    }
}

function Save-RepoFile {
    param([string]$RepoPath, [string]$OutFile)
    $Source = Get-DownloadSource $RepoPath
    Invoke-WebRequest -Uri $Source.Url -Headers $Source.Headers -OutFile $OutFile
}

function Test-NvidiaGpu {
    return [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue) -and
        ((nvidia-smi -L 2>$null | Select-Object -First 1))
}

function Test-NvidiaDockerReachable {
    # Windows PowerShell 5.1 macht aus stderr-Ausgaben nativer Programme (z. B. Docker-Warnungen) unter "Stop" einen Abbruch.
    $ErrorActionPreference = "Continue"
    # Wegwerf-Container statt reiner nvidia-smi-Pruefung: nvidia-smi auf dem Host reicht nicht, Docker
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

function Get-VramGb {
    # Windows PowerShell 5.1 macht aus stderr-Ausgaben nativer Programme (z. B. Docker-Warnungen) unter "Stop" einen Abbruch.
    $ErrorActionPreference = "Continue"
    # Nvidia-VRAM in GB (gerundet), $null falls nicht ermittelbar. Gegenstueck zu detect_vram_gb in detect-vram.sh
    # (nur der Nvidia-Zweig: AMD wird unter Windows nicht an Container durchgereicht).
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $null }
    $Mib = (nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if ($Mib -and ("$Mib".Trim() -match '^\d+$')) { return [int][math]::Round([int]"$Mib".Trim() / 1024, [MidpointRounding]::AwayFromZero) }
    return $null
}

# XTTS-v2 steht unter der Coqui Public Model License (nicht-kommerziell) und braucht neben dem Chat-Modell viel VRAM (ca. 4 GB).
# Standard in config.jsonl ist XTTS_LICENSE_ACCEPTED="" (automatisch): bei mehr als 10 GB VRAM setzt der Installer 1 (GPU, mit
# Hinweis, ohne Rueckfrage), sonst bleibt es leer und die Sprachausgabe nutzt Piper (CPU). Ein gesetzter Wert (0/1) bleibt unangetastet.
$XttsMinVramGb = 10
function Confirm-XttsLicense {
    if (-not $EnvValues["XTTS_LICENSE_ACCEPTED"]) {
        $VramGb = Get-VramGb
        if ($null -ne $VramGb -and $VramGb -gt $XttsMinVramGb) {
            Set-ConfigValue "XTTS_LICENSE_ACCEPTED" "1"
            Write-Host "==> $VramGb GB VRAM erkannt - XTTS-v2 (GPU-Sprachausgabe) wird aktiviert (XTTS_LICENSE_ACCEPTED=1 in config.jsonl)."
        }
        else {
            $Shown = if ($null -ne $VramGb) { $VramGb } else { "unbekannt" }
            Write-Host "==> $Shown GB VRAM erkannt (Schwelle: mehr als $XttsMinVramGb GB) - Sprachausgabe laeuft mit Piper auf der CPU."
            return
        }
    }
    if ($EnvValues["XTTS_LICENSE_ACCEPTED"] -eq "0") { return }
    Write-Host "Hinweis: Die GPU-Sprachausgabe nutzt Coqui XTTS-v2 (CPML, nur nicht-kommerzielle Nutzung, https://coqui.ai/cpml). Abschalten: XTTS_LICENSE_ACCEPTED=0 in config.jsonl."
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

# Recovery-Kit (docs/plaene/schluesselverlust-wiederherstellung/02-phase-2-recovery-kit.md): Geheimnisse (Zertifikat,
# JWT_SECRET, Lizenz) getrennt vom Volume-Backup sichern. Nur mit Terminal (die Passphrase wird abgefragt), sonst Hinweis.
function Install-RecoveryKit {
    if (-not $EnvValues["DATAPROTECTION_CERT_PFX"] -and -not $env:DATAPROTECTION_CERT_PFX) { return }
    docker exec sovereignmind-backend test -f /data/recovery-kit.json 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    Write-Host ""
    Write-Host "WICHTIG - Recovery-Kit: Ohne eine getrennte Sicherung Ihrer Geheimnisse (DataProtection-Zertifikat, JWT_SECRET, Lizenz)"
    Write-Host "gehen bei Verlust der config.jsonl die Connector-Geheimnisse und Paketschluessel unwiederbringlich verloren."
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host "Das Kit wird jetzt mit einer Passphrase erstellt, die nur Sie kennen (der Betreiber kann sie nicht zuruecksetzen)."
        try { & (Join-Path (Get-Location) "recovery-kit.ps1") export }
        catch { Write-Warning "Recovery-Kit nicht erstellt - bitte nachholen: .\recovery-kit.ps1 export" }
    } else {
        Write-Host "Bitte in einem Terminal nachholen: .\recovery-kit.ps1 export"
    }
}

function Install-BackupTask {
    # Optionaler Schritt (docs/pläne/postgres-haertung-und-backup/phase-2-geplante-backups-und-aufbewahrung.md):
    # registriert die Aufgabe "SovereignMind-Backup", die taeglich scripts backup-db.ps1 ausfuehrt (Uhrzeit aus
    # BACKUP_TIME, Default 02:00). Laeuft unter dem aktuellen Benutzer, braucht keine Administrator-Rechte; verpasste
    # Laeufe (Rechner aus) werden beim naechsten Start nachgeholt. Existiert die Aufgabe schon, wird sie ohne
    # Nachfrage aktualisiert. Nicht interaktiv: SOVEREIGNMIND_BACKUP_SCHEDULE=yes|no.
    $Existing = Get-ScheduledTask -TaskName $BackupTaskName -ErrorAction SilentlyContinue
    if (-not $Existing) {
        $Answer = $env:SOVEREIGNMIND_BACKUP_SCHEDULE
        if (-not $Answer) {
            Write-Host ""
            Write-Host "Optional: Taegliches automatisches Backup einrichten (Datenbank, Schluessel, Dokumente; 7 taegliche,"
            Write-Host "4 woechentliche und 6 monatliche Staende werden aufbewahrt, Einstellungen in config.jsonl)."
            $Answer = Read-Host "Jetzt einrichten? [J/n]"
        }
        if ($Answer -match '^(n|no|nein)$') {
            Write-Host "==> Geplantes Backup uebersprungen. Erneuter Lauf dieses Skripts holt die Einrichtung jederzeit nach (manuell: backup-db.ps1)."
            return
        }
    }

    $Time = if ($EnvValues["BACKUP_TIME"]) { $EnvValues["BACKUP_TIME"] } else { "02:00" }
    if ($Time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        Write-Warning "BACKUP_TIME '$Time' ist keine Uhrzeit (HH:mm) - verwende 02:00."
        $Time = "02:00"
    }
    $Dir = (Get-Location).Path
    New-Item -ItemType Directory -Force "backups" | Out-Null
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Dir\backup-db.ps1`"" -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -Daily -At $Time
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    $Principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $BackupTaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal `
            -Description "Taegliches SovereignMind-Backup (backup-db.ps1) mit Aufbewahrung" -Force -ErrorAction Stop | Out-Null
        Write-Host "==> Aufgabe '$BackupTaskName' eingerichtet: taeglich um $Time. Entfernen: install.ps1 -RemoveBackupTask"
    }
    catch {
        Write-Warning "Aufgabe '$BackupTaskName' konnte nicht eingerichtet werden: $_"
    }
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
    if (-not $PortalUrl) {
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

    if ($PortalUrl) {
        # Portal-Modus: der Lizenzserver liefert die Binary aus, der Lizenzschluessel ersetzt den GitHub-Token.
        # X-Sha256 der Antwort muss zur geladenen Datei passen.
        Write-Host "==> Lade Hardware-Agent-Binary vom Lizenzserver ($PortalUrl)"
        $PortalRef = if ($Ref -ne "latest") { "?ref=$([uri]::EscapeDataString($Ref))" } else { "" }
        try {
            $Response = Invoke-WebRequest -Uri "$PortalUrl/api/dist/hardware-agent/$AssetName$PortalRef" `
                -Headers @{ "X-License-Key" = $LicenseKey } -OutFile $ExePath -PassThru
        }
        catch {
            Write-Warning "Hardware-Agent konnte nicht vom Lizenzserver geladen werden ($($_.Exception.Message)) - Installation uebersprungen."
            Remove-Item $ExePath -ErrorAction SilentlyContinue
            return
        }
        $Expected = @($Response.Headers["X-Sha256"])[0]
        $Actual = (Get-FileHash $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Expected -and $Expected -ne $Actual) {
            Write-Warning "Pruefsumme des Hardware-Agents stimmt nicht (erwartet $Expected, erhalten $Actual) - Installation uebersprungen."
            Remove-Item $ExePath -ErrorAction SilentlyContinue
            return
        }
        Write-Host "    SHA256 geprueft: $Actual"
    }
    else {
        Write-Host "==> Lade Hardware-Agent-Binary aus Release '$($Release.tag_name)'"
        $DownloadHeaders = @{
            Authorization = "token $Token"
            Accept        = "application/octet-stream"
        }
        Invoke-WebRequest -Uri $Asset.url -Headers $DownloadHeaders -OutFile $ExePath
    }

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

function Get-ComposeVolumeName([string]$Name) {
    # Volume-Name wie ihn docker compose vergibt: <Projektname>_<Name>. Projektname = COMPOSE_PROJECT_NAME oder
    # Verzeichnisname (klein, nur a-z0-9_-). Der Filter "name=backend-data$" traefe sonst auch Volumes
    # anderer Compose-Projekte auf demselben Rechner (z. B. die Dev-Installation).
    $Project = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { Split-Path -Leaf (Get-Location).Path }
    $Project = $Project.ToLower() -replace '[^a-z0-9_-]', ''
    return "${Project}_$Name"
}

function Initialize-PostgresPassword {
    # Stellt sicher, dass POSTGRES_PASSWORD gesetzt ist (docs/pläne/postgres-umstellung/phase-2-...).
    # Ist es leer, wird ein zufaelliges Passwort erzeugt und in config.jsonl gespeichert. Existiert
    # bereits ein postgres-data-Volume, wird NIE ein neues Passwort erzeugt - es passte nicht mehr
    # zum initialisierten Cluster.
    if ($EnvValues["POSTGRES_PASSWORD"]) { return }
    $Volume = docker volume ls -q --filter ("name=^" + (Get-ComposeVolumeName "postgres-data") + '$')
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

function Initialize-DataProtectionCertificate {
    # Stellt sicher, dass ein Zertifikat zur Verschluesselung des Data-Protection-Schluesselrings
    # vorhanden ist (docs/pläne/dataprotection-schluesselverschluesselung/02-phase-2-installer-doku.md).
    # Leer -> self-signed RSA-2048 (20 Jahre) als PFX (Base64) + zufaelliges Passwort in config.jsonl.
    # Ein zweiter Lauf erzeugt NIE ein neues Zertifikat, wenn Schluessel auf dem Volume liegen:
    #  - Volume mit Klartext-Schluesseln: Migrationsfall - Zertifikat erzeugen, das Backend migriert beim Start.
    #  - Volume mit verschluesselten Schluesseln, Wert fehlt: Zertifikat verloren -> Abbruch.
    if ($EnvValues["DATAPROTECTION_CERT_PFX"]) { return }
    $Volume = docker volume ls -q --filter ("name=^" + (Get-ComposeVolumeName "backend-data") + '$') | Select-Object -First 1
    if ($Volume) {
        # Keine Anfuehrungszeichen/spitzen Klammern im sh-Befehl: Windows PowerShell 5.1 entfernt eingebettete
        # Anfuehrungszeichen beim Aufruf nativer Programme, "<masterKey" wuerde als Umleitung gelesen (alles = "encrypted").
        $State = (docker run --rm -v "${Volume}:/data:ro" alpine sh -c 'ls /data/keys/*.xml >/dev/null 2>&1 || { echo none; exit 0; }; if grep -q masterKey /data/keys/*.xml; then echo plain; else echo encrypted; fi') | Select-Object -Last 1
        if ($State -eq "encrypted") {
            Write-Error ("DATAPROTECTION_CERT_PFX ist leer, aber das Volume backend-data enthaelt bereits verschluesselte Schluessel. " +
                "Das Zertifikat ging verloren - bitte DATAPROTECTION_CERT_PFX/DATAPROTECTION_CERT_PASSWORD aus der gesicherten config.jsonl eintragen. " +
                "Ohne Zertifikat sind die Connector-Geheimnisse nicht lesbar (Volume-Ordner keys/ verwerfen, Geheimnisse neu eingeben).")
            exit 1
        }
        if ($State -notin @("none", "plain")) {
            Write-Error "Zustand der Schluessel im Volume backend-data nicht pruefbar (docker run alpine fehlgeschlagen - das alpine-Image braucht beim ersten Mal Internetzugang zu Docker Hub) - Abbruch, um keine neuen Schluessel/Zertifikate ueber bestehende zu legen."
            exit 1
        }
        if ($State -eq "plain") {
            # Bestandsinstallation: Zertifikat erzeugen, das Backend verschluesselt den Schluesselring beim naechsten
            # Start selbst (DataProtectionKeyMigrator, nur mit Zertifikat).
            Write-Warning "Klartext-Schluessel auf dem Volume backend-data gefunden - es wird ein Zertifikat erzeugt, das Backend verschluesselt den Schluesselring beim naechsten Start (Migration). config.jsonl danach getrennt von Volume und Backups sichern."
        }
    }
    $Bytes = New-Object byte[] 48
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $Rng.GetBytes($Bytes)
    $Rng.Dispose()
    $Password = ([Convert]::ToBase64String($Bytes) -replace '[^A-Za-z0-9]', '')
    while ($Password.Length -lt 32) { $Password += ([char[]]'abcdefghjkmnpqrstuvwxyz23456789' | Get-Random) }
    $Password = $Password.Substring(0, 32)

    $Rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $Request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
        "CN=SovereignMind DataProtection", $Rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $Certificate = $Request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(20))
    $Pfx = $Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password)
    $Certificate.Dispose()
    $Rsa.Dispose()

    Set-ConfigValue "DATAPROTECTION_CERT_PFX" ([Convert]::ToBase64String($Pfx))
    Set-ConfigValue "DATAPROTECTION_CERT_PASSWORD" $Password
    Write-Host "==> DATAPROTECTION_CERT_PFX/-PASSWORD erzeugt und in config.jsonl gespeichert (config.jsonl getrennt von Volume und Backups sichern!)."
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

if ($PortalUrl) {
    # Registry-Proxy des Portals: Benutzername beliebig, Passwort = Lizenzschluessel (docker login verlangt HTTPS, ausser bei localhost).
    Write-Host "==> Login beim Lizenzserver ($PortalHost)"
    cmd /c "<nul set /p =$LicenseKey| docker login $PortalHost -u license --password-stdin"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker login bei $PortalHost fehlgeschlagen. Lizenzschluessel und Adresse pruefen (HTTPS noetig, ausser localhost)."
        exit 1
    }
}
else {
    Write-Host "==> Login bei ghcr.io"
    # cmd statt Pipe: Windows PowerShell 5.1 haengt der Pipe ein Zeilenende/BOM an, das Token wuerde ungueltig.
    cmd /c "<nul set /p =$Token| docker login ghcr.io -u $GithubUser --password-stdin"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker login bei ghcr.io fehlgeschlagen. SOVEREIGNMIND_GHCR_TOKEN (Scope read:packages) und GITHUB_USER pruefen."
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
Push-Location $TargetDir
try {
    if ($PortalUrl) { Write-Host "==> Lade Compose-Dateien vom Lizenzserver ($PortalUrl)" }
    else { Write-Host "==> Lade Compose-Dateien von GitHub (Ref: $Ref)" }
    $Files = @(
        "docker-compose.yml",
        "docker-compose.images.yml",
        "docker-compose.nvidia.yml",
        "docker-compose.rocm.yml",
        ".env.example"
    )
    foreach ($f in $Files) {
        Write-Host "    $f"
        Save-RepoFile "8.Docker/$f" $f
    }
    # Im Repo liegen die Compose-Dateien in 8.Docker/ (models.json und backups/ eine Ebene darueber), hier flach in einem
    # Ordner. Die vom Lizenzserver gelieferte Datei ist schon umgeschrieben, der Schritt idempotent.
    $ComposePath = Join-Path (Get-Location) "docker-compose.yml"
    $ComposeText = [System.IO.File]::ReadAllText($ComposePath) -replace '\.\./models\.json', './models.json' -replace '\.\./backups', './backups'
    [System.IO.File]::WriteAllText($ComposePath, $ComposeText, (New-Object System.Text.UTF8Encoding($false)))

    # Backup-/Restore-Skripte (liegen im Repo unter 9.Support/scripts/, hier flach neben den Compose-Dateien).
    foreach ($f in "backup-db.ps1", "backup-prune.ps1", "restore-db.ps1", "recovery-kit.ps1") {
        Write-Host "    $f"
        Save-RepoFile "9.Support/scripts/$f" $f
    }

    # models.json (Modell-Katalog, Phase 2a, docs/pläne/log-modelle-hardware-anpassungen/02a-...)
    # nur laden, wenn noch keine vorhanden ist - der Admin kann die Datei nach der Erstinstallation
    # bearbeiten (neues Modell ergaenzen, VRAM-Wert korrigieren), ein erneuter Installer-/Update-Lauf
    # soll das nicht ueberschreiben (anders als die Compose-Dateien, die immer den Release-Stand
    # bekommen).
    if (-not (Test-Path "models.json")) {
        Write-Host "    models.json"
        Save-RepoFile "models.json" "models.json"
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
        Save-RepoFile "8.Docker/config.jsonl" "config.jsonl"
    }
    else {
        Write-Host "==> Vorhandene config.jsonl uebernommen (Werte bleiben unveraendert)."
        $ConfigSource = Get-DownloadSource "8.Docker/config.jsonl"
        Add-MissingConfigKeys -Url $ConfigSource.Url -Headers $ConfigSource.Headers
    }

    $EnvIsNew = -not (Test-Path ".env")
    if ($EnvIsNew) {
        Copy-Item ".env.example" ".env"
        Write-Host "==> .env aus Vorlage angelegt (nur Geheimnisse). Ports, Impressum usw. stehen in config.jsonl."
    }
    else {
        Write-Host "==> Vorhandene .env unveraendert uebernommen."
    }

    # Portal-Modus: Images laufen ueber den Registry-Proxy des Lizenzservers, die Online-Aktivierung ist gleich mit eingerichtet.
    # Die Werte gehoeren in .env (nicht nur in die Sitzung), damit spaetere `docker compose`-Aufrufe und Updates dasselbe sehen.
    if ($PortalUrl) {
        $PortalValues = [ordered]@{
            SOVEREIGNMIND_REGISTRY = "$PortalHost/benexdrake"
            LICENSE_SERVER_URL     = $PortalUrl
            LICENSE_KEY            = $LicenseKey
        }
        $Kept = @(Get-Content ".env" -Encoding UTF8 | Where-Object { $Line = $_; -not ($PortalValues.Keys | Where-Object { $Line -match "^\s*$_\s*=" }) })
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $NewEnv = ($Kept + ($PortalValues.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path (Get-Location) ".env"), $NewEnv + "`n", $Utf8NoBom)
        Write-Host "==> Portal-Modus: Registry $PortalHost/benexdrake, Online-Aktivierung ueber $PortalUrl (in .env eingetragen)."
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
    Initialize-DataProtectionCertificate

    # Alte Installationen koennen noch LLM_SERVER=1 (llama.cpp) in config.jsonl/.env haben - der Pfad
    # ist entfernt, Ollama ist das einzige Backend. Nur ein Hinweis, kein Abbruch.
    $LegacyLlmServer = if ($EnvValues["LLM_SERVER"]) { $EnvValues["LLM_SERVER"] } elseif ($env:LLM_SERVER) { $env:LLM_SERVER } else { "0" }
    if ($LegacyLlmServer -ne "0") {
        Write-Warning "LLM_SERVER=$LegacyLlmServer wird ignoriert - llama.cpp wird nicht mehr unterstuetzt, es wird Ollama verwendet. Die Eintraege LLM_SERVER und LLM_CHAT_*/LLM_EMBED_* koennen Sie aus config.jsonl entfernen."
    }

    $ComposeFiles = @("-f", "docker-compose.yml", "-f", "docker-compose.images.yml")

    # Ollama laeuft nativ auf dem Host (kein Container), s. docs/pläne/chat-voice-dokumente-ollama-native.
    Install-NativeOllama

    # GPU-Durchreichung fuer voice-worker (STT/TTS) und GPU-Erkennung im Backend (Nvidia). Ollama selbst
    # laeuft nativ und braucht das Overlay nicht. ROCm-Overlay gibt es hier bewusst nicht (nur nativer Linux-Host).
    if ((Test-NvidiaGpu) -and (Test-NvidiaDockerReachable)) {
        Write-Host "GPU erkannt: Nvidia - reiche sie an voice-worker/backend durch (docker-compose.nvidia.yml)"
        $ComposeFiles += @("-f", "docker-compose.nvidia.yml")
        Confirm-XttsLicense
    }

    $env:SOVEREIGNMIND_VERSION = $Version

    Write-Host "==> Ziehe Images (Version: $Version)"
    docker compose @ComposeFiles pull
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker compose pull fehlgeschlagen - Abbruch (Registry-Zugang/Internet pruefen)."
        exit 1
    }

    Write-Host "==> Starte Stack"
    # --no-build: beim Kunden gibt es keine Build-Kontexte, die *-worker-base-Services aus docker-compose.yml
    # wuerden sonst einen Build versuchen und `up` scheitern lassen.
    docker compose @ComposeFiles up -d --no-build
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker compose up fehlgeschlagen - der Stack laeuft nicht. Ausgabe oben pruefen, danach den Installer erneut starten."
        exit 1
    }

    # Modelle der Worker liegen in Volumes, nicht im Image (analog zu ollama pull). Fehlschlag = nur
    # Warnung, die Worker laden bei Bedarf nach.
    foreach ($Worker in @("ingestion-worker", "voice-worker")) {
        Write-Host "==> Lade Modelle: $Worker (ca. 1,5 GB ingestion-worker, ca. 3,2 GB voice-worker; beim ersten Mal mehrere Minuten)"
        docker exec "sovereignmind-$Worker" python -m app.prefetch
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Modell-Download fuer $Worker fehlgeschlagen - spaeter manuell nachholen: docker exec sovereignmind-$Worker python -m app.prefetch"
        }
    }

    Install-HardwareAgent
    Install-RecoveryKit
    Install-BackupTask

    $FrontendPort = if ($EnvValues["FRONTEND_PORT"]) { $EnvValues["FRONTEND_PORT"] } else { "3000" }
    Write-Host ""
    Write-Host "Fertig. Chat-UI: http://localhost:$FrontendPort"
    Write-Host "Erster Start: die Seite oeffnen - sie fuehrt auf /setup (Lizenzschluessel einfuegen, Admin-Passwort vergeben)."
    Write-Host "Erneut ausfuehren aktualisiert auf die neueste Version (idempotent, .env und config.jsonl bleiben erhalten)."
}
finally {
    Pop-Location
}
