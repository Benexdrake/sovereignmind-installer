# SovereignMind – Installer

<p align="center"><img src="logo.svg" alt="SovereignMind" width="300"></p>

**On-Premise KI-Assistent für den DACH-Mittelstand.** SovereignMind ist ein DSGVO-konformer
Chat-Assistent über die eigenen Firmendokumente (RAG), der komplett lokal beim Kunden läuft.
Dokumente und Prompts verlassen das Netzwerk nicht, es gibt keine Anbindung an OpenAI, Google
oder andere Cloud-KI-APIs.

Dieses Repo enthält nur das, was für die Installation gebraucht wird. Der Quellcode ist nicht Teil davon.

Präsentation: [SovereignMind Präsentation](https://claude.ai/artifact/D8hR37cBCNKZLZEfdcZSXo) (12 Folien zu Problem, Lösung, Architektur, Funktionen, Tech-Stack und Geschäftsmodell).

## Wofür ist das gedacht?

Kanzleien, Personalabteilungen, Gesundheitswesen, Industrie: Überall liegen sensible Dokumente
(Verträge, Handbücher, Akten, Fertigungspläne), die nicht in eine US-Cloud dürfen. Ohne
freigegebene Alternative landen sie oft trotzdem in privaten ChatGPT-Accounts. SovereignMind
ist die selbst gehostete Alternative.

## Funktionen

- **Lokale KI:** Sprachmodell und Embeddings laufen auf der Hardware des Kunden (Ollama nativ
  auf dem Rechner). Das Chat-Modell wird automatisch nach
  verfügbarem VRAM gewählt (NVIDIA, AMD, sonst CPU) und kann der Admin im Bereich
  „KI-Einstellungen“ wechseln.
- **Chat mit Quellenbelegen:** Fragen in natürlicher Sprache, Antworten mit klickbaren
  Verweisen ins Originaldokument. Antworten immer auf Deutsch.
- **Dokumentenverwaltung:** PDF, DOCX, Tabellen u. a. werden automatisch geparst und
  durchsuchbar gemacht. Kategorien, Duplikaterkennung, Verarbeitungsstatus.
- **Mehrere Nutzer und Rollen:** Admin und Member, eigenes Branding pro Unternehmen.
- **Assistenten und Prompt-Bibliothek:** Vorkonfigurierte Assistenten und wiederverwendbare
  Vorlagen für das ganze Team.
- **Anbindung interner Systeme:** HTTP-Schnittstellen (DMS, ERP, Fachdatenbanken) lassen sich
  als Werkzeuge einbinden, die das Modell bei Bedarf selbst aufruft.
- **Dateien im Chat:** Dokumente direkt in einer Unterhaltung hochladen, ohne sie dauerhaft
  abzulegen.
- **Sprache:** Diktat und Vorlesen, lokal verarbeitet; der Admin schaltet beides pro
  Unternehmen frei.
- **Wissenspakete:** Vorverarbeitete Gesetze und Regelwerke als signierte Pakete, die der Admin
  aus dem Katalog installiert oder als Datei importiert.
- **Themes:** Jeder Nutzer wählt Stil, Hell/Dunkel und Akzentfarbe; das Unternehmen kann eine
  Akzentfarbe vorgeben.
- **Support-Nachrichten:** Nutzer schreiben dem Admin über ein Kontaktformular.
- **Admin-Bereich:** Nutzer, Dokumente, Branding, Lizenz, KI-Einstellungen (Modelle, Assistenten,
  Vorlagen, Sprache), Wissenspakete, Support, Nutzungsstatistik, Logs, Hardware-Dashboard
  (unter Windows auf Wunsch mit Companion-Agent für genaue Host-Werte).

## Architektur in Kürze

```
Web-Oberfläche ──> Backend (Auth, Rollen, Lizenz, Mandanten)
                      ├─ Inferenz (Ollama)
                      ├─ Vektordatenbank (Qdrant)
                      ├─ Dokumentenverarbeitung (Docling)
                      ├─ Sprache (Diktat/Vorlesen)
                      └─ PostgreSQL
```

Alles läuft nach der Installation als Dienst im Hintergrund. Es ist weder Docker noch WSL noch
sonst eine Vorarbeit nötig; Ollama und die Modelle liefert der Installer mit.

## Voraussetzungen

- Windows 10 (1809) / 11 / Server 2019+ (x64) oder Ubuntu 24.04 / Debian 12 (x64)
- Administratorrechte (Windows) bzw. `sudo` (Linux)
- Für gute Antwortzeiten eine GPU mit ausreichend VRAM; ohne GPU läuft alles auf der CPU, deutlich langsamer
- Ein Lizenzschlüssel (Token) und die E-Mail-Adresse, auf die er ausgestellt wurde (vom Anbieter)

## Installation

Windows: `SovereignMind-Setup-<Version>.exe` aus den Releases herunterladen und ausführen.

Linux:

```bash
sudo apt install ./sovereignmind-models_*.deb ./sovereignmind_*.deb
```

Danach ist die Oberfläche unter <http://localhost:5043> erreichbar. Beim ersten Aufruf führt die App
durch die Einrichtung (Lizenzschlüssel, Unternehmen, Admin-Passwort). Die Aktivierung läuft offline.

Vor der Installation ist der Endnutzer-Lizenzvertrag (EULA) zu bestätigen: Das Windows-Setup zeigt ihn als Lizenzseite,
das Linux-Paket fragt per debconf (`sovereignmind/accept-eula`). Ohne Zustimmung wird nicht installiert. Automatisierte
Installation: Windows `/VERYSILENT` (gilt als Zustimmung), Linux vorab
`echo 'sovereignmind sovereignmind/accept-eula boolean true' | sudo debconf-set-selections`.

Prüfsummen stehen in `SHA256SUMS.txt` neben den Downloads.

## Betrieb

Update, Sicherung, Wiederherstellung (Recovery-Kit) und Deinstallation beschreibt das Betreiber-Handbuch,
das mit dem Anbieter-Support ausgeliefert wird.
