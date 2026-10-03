# SovereignMind Betreiber-Installer (Windows): Lizenzserver ("Portal") + Postgres (+ optional Caddy mit TLS).
#
# Nur fuer den Betreiber, nie beim Kunden. Bash-Gegenstueck: install-license-server.sh (dort ausfuehrlichere
# Kommentare), dieses Skript spiegelt denselben Ablauf. Der Kunden-Installer (install.ps1) bleibt unveraendert.
#
# Aufruf (PowerShell):
#   $env:SOVEREIGNMIND_GHCR_TOKEN = "<token>"
#   .\install-license-server.ps1
#   .\install-license-server.ps1 -Domain portal.example.com      # mit TLS (Caddy)
#
# Erneuter Aufruf = Update: .env und secrets\ bleiben unveraendert, Images werden neu gezogen.

[CmdletBinding()]
param(
    [string]$Version = $(if ($env:SOVEREIGNMIND_VERSION) { $env:SOVEREIGNMIND_VERSION } else { "latest" }),
    [string]$TargetDir = $(if ($env:SOVEREIGNMIND_DIR) { $env:SOVEREIGNMIND_DIR } else { ".\license-server" }),
    [string]$Ref = $(if ($env:SOVEREIGNMIND_REF) { $env:SOVEREIGNMIND_REF } else { "main" }),
    [string]$Domain = $(if ($env:PORTAL_DOMAIN) { $env:PORTAL_DOMAIN } else { "" })
)

$ErrorActionPreference = "Stop"

$Repo = "Benexdrake/SovereignMind"
$Token = $env:SOVEREIGNMIND_GHCR_TOKEN
$GithubUser = if ($env:GITHUB_USER) { $env:GITHUB_USER } else { "Benexdrake" }
$ComposeFile = "docker-compose.license-server.yml"

if (-not $Token) {
    Write-Error "SOVEREIGNMIND_GHCR_TOKEN nicht gesetzt."
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

function Protect-File {
    # Nur der aktuelle Benutzer darf die Datei lesen (Gegenstueck zu chmod 600).
    param([string]$Path)
    icacls $Path /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
}

Write-Host "==> Login bei ghcr.io"
$Token | docker login ghcr.io -u $GithubUser --password-stdin
if ($LASTEXITCODE -ne 0) { Write-Error "docker login fehlgeschlagen."; exit 1 }

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
Set-Location $TargetDir

Write-Host "==> Lade Compose-Datei von GitHub (Ref: $Ref)"
$Headers = @{ Authorization = "token $Token"; Accept = "application/vnd.github.raw" }
foreach ($File in @($ComposeFile, "Caddyfile.license-server", "scripts/backup-license-server.ps1")) {
    Write-Host "    $File"
    Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/contents/$File`?ref=$Ref" -Headers $Headers -OutFile (Split-Path $File -Leaf)
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path ".env")) {
    $Bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
    $Password = ($Bytes | ForEach-Object { $_.ToString("x2") }) -join ""
    $Lines = @(
        "# Betreiber-Stack (Lizenzserver). Enthaelt Geheimnisse - nie weitergeben.",
        "GITHUB_OWNER=$($GithubUser.ToLowerInvariant())",
        "SOVEREIGNMIND_VERSION=$Version",
        "PORTAL_POSTGRES_PASSWORD=$Password",
        "PORTAL_UPSTREAM_USER=$GithubUser",
        "PORTAL_UPSTREAM_TOKEN=$Token"
    )
    if ($Domain) { $Lines += "PORTAL_DOMAIN=$Domain"; $Lines += "PORTAL_PUBLIC_URL=https://$Domain" }
    else { $Lines += "PORTAL_PUBLIC_URL=http://localhost:5100" }
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) ".env"), (($Lines -join "`n") + "`n"), $Utf8NoBom)
    Protect-File ".env"
    Write-Host "==> .env angelegt."
}
else {
    Write-Host "==> Vorhandene .env unveraendert uebernommen."
    $EnvText = Get-Content ".env" -Raw
    if ($Domain -and $EnvText -notmatch '(?m)^PORTAL_DOMAIN=') {
        Add-Content ".env" -Value "PORTAL_DOMAIN=$Domain`nPORTAL_PUBLIC_URL=https://$Domain" -Encoding UTF8
    }
}

$ProfileArgs = @()
if ((Get-Content ".env" -Raw) -match '(?m)^PORTAL_DOMAIN=.+') {
    $ProfileArgs = @("--profile", "tls")
    Write-Host "==> TLS-Profil aktiv (Caddy, Domain aus .env)."
}

function Invoke-Compose {
    # docker schreibt Fortschritt nach stderr; unter Windows PowerShell 5.1 waere das mit "Stop" ein Abbruch.
    $ErrorActionPreference = "Continue"
    docker compose -f $ComposeFile @ProfileArgs @args
    if ($LASTEXITCODE -ne 0) { Write-Error "docker compose $($args -join ' ') fehlgeschlagen."; exit 1 }
}

Write-Host "==> Ziehe Images"
Invoke-Compose pull

Write-Host "==> Initialisiere Geheimnisse (nur beim ersten Mal)"
New-Item -ItemType Directory -Force -Path "secrets", "backups" | Out-Null
Invoke-Compose run --rm --no-deps license-server init --dir /secrets

Write-Host "==> Starte Stack"
Invoke-Compose up -d

Write-Host "==> Warte auf den Lizenzserver"
$Ready = $false
for ($i = 0; $i -lt 40; $i++) {
    $Health = docker compose -f $ComposeFile @ProfileArgs ps license-server --format '{{.Health}}' 2>$null
    if ($Health -match "healthy") { $Ready = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $Ready) {
    Write-Warning "Der Lizenzserver wurde nicht gesund. Logs: docker compose -f $ComposeFile logs license-server"
    exit 1
}

$PublicUrl = ((Get-Content ".env" | Where-Object { $_ -like "PORTAL_PUBLIC_URL=*" }) -replace '^PORTAL_PUBLIC_URL=', '')
Write-Host ""
Write-Host "Lizenzserver laeuft: $PublicUrl"
Write-Host "  - PackTool (Betreiber-Konsole): LicenseServer__BaseUrl=$PublicUrl  LicenseServer__AdminKey=<Admin-Schluessel von oben>"
Write-Host "  - Kunden-Installationen: License__ServerUrl=$PublicUrl, License__PublicKeyPem = secrets\license_public.pem"
Write-Host "  - Sichern: .\backup-license-server.ps1 (Datenbank, secrets\ mit Signaturschluessel, Katalog)"
