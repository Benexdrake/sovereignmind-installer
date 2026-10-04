# Zertifikat oder config.jsonl verloren – was tun?

Die Datei `config.jsonl` im Installationsverzeichnis enthält Geheimnisse, ohne die einige Daten nicht mehr lesbar sind,
vor allem das **DataProtection-Zertifikat** (`DATAPROTECTION_CERT_PFX` / `DATAPROTECTION_CERT_PASSWORD`).
Das Backend läuft in diesem Fall weiter (Chat und Login funktionieren), der Admin-Bereich zeigt aber ein Warnbanner
„Schlüsselring nicht lesbar“. Es werden nie stillschweigend neue Schlüssel erzeugt und nichts überschrieben.

## Was passiert bei Verlust?

| Wert | Folge |
|---|---|
| Lizenzprüfung, `license.dat` | keine, liegt im Image bzw. im Volume `/data` |
| `LICENSE_SERVER_URL` / `LICENSE_KEY` | Heartbeat und Paketschlüssel-Abruf stoppen, die Lizenz läuft aus |
| `JWT_SECRET` | alle Anmeldungen werden ungültig, keine Datenverluste |
| `GHCR_TOKEN` | keine Updates, Betrieb läuft |
| **DataProtection-Zertifikat** | Schlüsselring unlesbar: Paketschlüssel und Connector-Geheimnisse (API-Keys) sind weg |

## Entscheidungsbaum

1. **Haben Sie ein Recovery-Kit (`sovereignmind-recovery-<datum>.smrk`) und die Passphrase?**
   Ja: Kit zurückspielen (siehe unten). Danach läuft alles wie vorher.
2. **Kein Kit, Installation mit Online-Lizenz (`LICENSE_SERVER_URL` gesetzt)?**
   - Neues Zertifikat bzw. neue `config.jsonl` anlegen (Installer erneut ausführen erzeugt ein neues Zertifikat).
   - Connector-Geheimnisse im Admin-Bereich neu eintragen (die alten sind nicht wiederherstellbar).
   - Paketschlüssel holt sich die Installation nach der Neuanlage automatisch vom Lizenzserver, solange die Lizenz gültig ist.
3. **Kein Kit, Offline-Lizenz (`.smkey`-Pakete)?**
   Beim Anbieter eine neue `.smkey` mit dem neuen Fingerprint anfordern (Admin-Bereich, Wissenspakete, „Installationsschlüssel anzeigen“; der Fingerabdruck steht dort und im Recovery-Kit-Export).
   Connector-Geheimnisse ebenfalls neu eintragen.

Wichtig: Ist das Warnbanner sichtbar, **nicht** das Volume `backend-data` löschen und nicht `keys/` von Hand ändern.

## Recovery-Kit anlegen (jetzt, nicht erst im Notfall)

Im Installationsverzeichnis, bei laufendem Stack:

```bash
bash recovery-kit.sh export          # Linux/macOS
.\recovery-kit.ps1 export            # Windows
```

- Sie wählen eine Passphrase (mindestens 12 Zeichen). Nur Sie kennen sie, der Anbieter hat keinen Zugriff.
- Ergebnis: `recovery-kit/sovereignmind-recovery-<datum>.smrk` plus ausgegebener Fingerprint der Installation.
- **Datei an einem anderen Ort ablegen als das Volume und die Backups** (z. B. verschlüsselter USB-Stick, Tresor, Passwortmanager).
- Danach `recovery-kit.sh confirm` ausführen, damit die Erinnerung im Admin-Bereich verschwindet.
- Nach Änderungen an Zertifikat oder Lizenzschlüssel neu exportieren.

## Recovery-Kit zurückspielen

```bash
bash recovery-kit.sh import <Datei.smrk>
.\recovery-kit.ps1 import <Datei.smrk>
```

Das Skript prüft zuerst Passphrase und Datei, dann ob das enthaltene Zertifikat zum vorhandenen Schlüsselring passt.
Erst danach wird `config.jsonl` geschrieben (Sicherung als `config.jsonl.bak-<Zeit>`). Bei einem Fehler bleibt
`config.jsonl` unverändert. Anschließend das Backend neu erzeugen:

```bash
docker compose up -d --force-recreate backend
```

## Backups und Recovery-Kit

`backup-db` sichert Datenbank, Schlüsselordner, Lizenz und Dokumente, **aber keine Zertifikate und nicht die
`config.jsonl`**. Ohne Zertifikat sind die gesicherten Schlüssel nutzlos. Bewahren Sie deshalb `config.jsonl` und das
Recovery-Kit getrennt vom Backup-Ordner auf.
