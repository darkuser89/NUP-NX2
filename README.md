# NUP Studio

Native SwiftUI-App für Apple-Silicon-Macs zum Arbeiten mit dem NUP-Containerformat von [a55uka/nup](https://github.com/a55uka/nup).

[![macOS Build und Release](https://github.com/darkuser89/NUP-NX2/actions/workflows/macos.yml/badge.svg)](https://github.com/darkuser89/NUP-NX2/actions/workflows/macos.yml)

Fertige, von GitHub Actions gebaute App: **[Releases herunterladen](https://github.com/darkuser89/NUP-NX2/releases/latest)**. ZIP entpacken und **NUP Studio.app** in Programme kopieren. Die App ist ad-hoc signiert, ohne Developer-ID-Signatur und Apple-Notarisierung.

## Automatische GitHub-Builds und Releases

GitHub Actions führt bei Pushes nach `main`, Pull Requests und Versions-Tags die Tests aus und baut danach die Release-App auf einem ARM64-Mac-Runner. ZIP und SHA-256-Datei sind anschließend sieben Tage als Workflow-Artefakt verfügbar. Nur erfolgreiche Versions-Tag-Builds veröffentlichen zusätzlich ein dauerhaftes GitHub-Release. Der Release-Job lädt ausschließlich das im selben Workflow gebaute Artefakt und prüft dessen SHA-256; lokale Apps werden nicht hochgeladen. Für die Automation reicht GitHubs eingebautes `GITHUB_TOKEN`, ohne eigene Zugangsdaten im Repository.

Neue Version veröffentlichen:

```sh
git push origin main
git tag v1.0.1
git push origin v1.0.1
```

Das Versions-Tag hat das Format `vMAJOR.MINOR.PATCH`. Die App erhält die Tag-Version und GitHubs Laufnummer als Buildnummer. Ein bereits veröffentlichtes Release wird nicht ersetzt. Unter **Actions → macOS Build und Release → Run workflow** lässt sich zusätzlich ein Build ohne Veröffentlichung starten. `script/ci_build.sh` ist ausschließlich für GitHub Actions vorgesehen; der lokale Run-Button bleibt unverändert.

## Öffnen und starten

1. `NUPStudio.xcodeproj` in Xcode öffnen.
2. Scheme **NUPStudio**, Ziel **My Mac** auswählen.
3. Mit **⌘R** bauen und starten.

Benötigt macOS 14 oder neuer, einen Apple-Silicon-Mac und Xcode 15 oder neuer. Das Projekt ist auf `arm64` eingestellt und verwendet für lokale Builds Ad-hoc-Signierung ohne Entwicklerteam. Für die Weitergabe außerhalb des eigenen Macs eigene Signierung und Notarisierung einrichten.

Der komplette Quellcode einschließlich Zstandard ist enthalten. Kein Python, Homebrew oder Paketdownload zum Bauen oder Ausführen erforderlich. XcodeGen ist nur nötig, wenn `project.yml` geändert und das Projekt neu generiert werden soll. Das fertige Xcode-Projekt ist bereits enthalten.

Alternativ:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --build-only
```

Das Skript verwendet genau einen stabilen Buildbaum unter `../../builds/NUPStudio`, außerhalb der Projektquellen. Mit `NUP_BUILD_DIR=/absoluter/externer/Pfad` lässt sich diese Ablage ändern. Keine Buildablage innerhalb von Code- oder Auditordnern wählen. Der Codex-Run-Button verwendet dasselbe Skript.

## Bedienung

- **Container**: NUP öffnen oder in das Fenster ziehen; Paket auswählen, Dateibaum durchsuchen und Metadaten bearbeiten.
- **Bibliothek**: **NUP-Ordner** auswählen (⇧⌘O). Alle regulären `.nup`-/`.NUP`-Dateien einschließlich Unterordnern erscheinen mit Pfad und Größe. Nach Spielname, Dateiname oder Pfad filtern, eine Zeile auswählen und **Öffnen** anklicken oder die Zeile doppelklicken. **Neu einlesen** aktualisiert die Liste; **Zur Bibliothek** führt vom geöffneten Container zurück. Symbolische Links werden übersprungen. Der zuletzt erfolgreich eingelesene Ordner wird gespeichert und beim nächsten App-Start automatisch neu eingelesen. Ist das Laufwerk getrennt, bleibt die Auswahl erhalten; nach dem Verbinden **Erneut versuchen** wählen. Die Ordnersuche liest zuerst nur Namen und Dateiattribute. Anschließend werden Spielnamen und Cover im Hintergrund aus den NUP-Metadaten nachgeladen. Die Spieldaten werden dafür nicht gelesen oder entpackt. Ordner, die außerhalb von **Erstellen** ins Fenster gezogen werden, öffnen ebenfalls die Bibliothek.
- **Prüfen**: vollständige SHA-256-Prüfung aller Dateien. Das Aktionsmenü bietet zusätzlich eine reine Strukturprüfung.
- **Entpacken**: das ausgewählte Paket oder nur ExeFS/RomFS in einen neuen Ordner schreiben. Geschriebene Inhalte werden per SHA-256 geprüft.
- **Erstellen**: Dump-Ordner wählen, Metadaten ergänzen, Kompressionsstufe einstellen und außerhalb des Quellordners speichern.
- **Cover direkt in der Bibliothek**: Auf das Cover/den Platzhalter klicken oder eine NUP markieren und **Cover …** bzw. im Kontextmenü **Cover hinzufügen / ändern …** wählen. Paket prüfen, PNG/JPEG auswählen und **Cover speichern** anklicken. Das Cover wird über die direkte Metadaten-Transaktion in derselben NUP gespeichert; kein Kopieren der Spielinhalte. Nur das Cover-Feld des gewählten Pakets wird ersetzt. Titel, Publisher, Sprachblöcke und unbekannte Felder bleiben bytegenau erhalten. Die Bibliothek bleibt geöffnet und aktualisiert Cover und Dateigröße. Geänderte Quelldateien und Nicht-Bild-Daten im Cover-Feld werden vor dem Schreiben abgewiesen.
- **Metadaten**: Titel, Publisher, Version, Icon, Sprachtitel und Sprach-Icons ändern. **Änderungen übernehmen** aktualisiert Metadaten direkt in der geöffneten Datei, ohne die Spielinhalte zu kopieren. **Speichern unter …** erzeugt eine neue NUP-Datei und erhält das Original.
- **Dateien hinzufügen/entfernen**: Unter **Inhalte** Paket und Zielordner auswählen, dann **Dateien hinzufügen …** wählen. Mehrere reguläre Dateien sind möglich. Bei markierter Datei ist deren übergeordneter Ordner das Ziel; ohne Auswahl standardmäßig RomFS, sonst ExeFS oder Paketwurzel. Bereits vorhandene Namen werden abgewiesen. Zum Entfernen eine oder mehrere Dateien markieren, **Dateien entfernen …** wählen und die angezeigten Namen bestätigen. Änderungen werden sofort in der geöffneten NUP gespeichert. Leere Ordner bleiben erhalten.
- **⌘O** öffnen, **⌘N** erstellen, **⇧⌘R** prüfen, **⇧⌘E** entpacken, **⌘.** abbrechen.

Unterstützte Quellstruktur:

```text
dump/
  base/exefs/…
  base/romfs/…
  updates/458752/exefs/…
  updates/458752/romfs/…
  dlc/040074a01bf13001/0/romfs/…
```

Auch einzelne Inhaltsordner mit `exefs/` oder `romfs/` sowie reine Update-Sammlungen werden erkannt. Leere Basispakete werden übersprungen; Updates ohne Basis erhalten das Standalone-Flag. `.listing` wird standardmäßig ausgelassen, `.DS_Store` immer. Symbolische Links und Spezialdateien werden abgewiesen.

## Metadaten nach Spezifikation v1

Die gesamte native App verwendet ausschließlich die einbasierten TLV-Kennungen aus `SPEC.md`. Das gilt für direktes Öffnen, zuletzt geöffnete Dateien, Bibliothek, Packen, Metadatenbearbeitung und direktes Cover-Speichern. Es gibt keine Profilwahl und keine automatische Umdeutung mehr. Alte Profil-Einstellungen werden beim Start entfernt; bestehende Dateien werden dabei nicht konvertiert oder verändert.

| Kennung | Bedeutung |
| --- | --- |
| 1 | NPDM |
| 2 | NACP |
| 3 | Cover/Icon |
| 4 | Angezeigte Version |
| 5 | Spielname |
| 6 | Publisher |
| 7 | Build-ID |
| 8 | Quelle |
| 9 | Sprachtitel |
| 10 | Sprach-Cover |

Unbekannte Kennungen bleiben bei Bearbeitungen erhalten und beeinflussen die Interpretation der bekannten Felder nicht. Ein Eintrag mit Kennung 0 löst keinen Formatwechsel aus. Die abweichende nullbasierte Metadatenbelegung des ursprünglichen Python-Tools wird nicht als App-Format angeboten; unveränderte Originalcontainer bleiben ausschließlich strukturelle/Streaming-Testfixtures.

## Dateiverarbeitung

Die Bibliothek zeigt Spielnamen und 48-Punkt-Cover aus den lokalen Metadaten. Die Originaldateinamen und Pfade bleiben sichtbar. Eine serielle Hintergrund-Warteschlange liest über den bestehenden NUP-Leser Header, TOC und Metadaten; sie führt keine Journal-Wiederherstellung und keine Schreibzugriffe aus. Cover werden mit ImageIO auf höchstens 128 Pixel verkleinert. Der flüchtige NSCache verwendet 32 MiB Kostenlimit und 512 Einträge; sichtbare Zeilen halten ihre Vorschaubilder zusätzlich. Keine Coverkopien auf Datenträger, kein Download aus dem Internet. Fehlende oder beschädigte Metadaten behalten einen Dateinamen und Platzhalter. Alle Angaben verwenden fest Spezifikation v1. Titel aus Sprachdaten bevorzugen de/de-de, dann en/en-us; Basispakete haben Vorrang. Die Vorschau ist keine vollständige Integritätsprüfung der Spielinhalte.

Ordnersuche und Suchfilter laufen im Hintergrund. Der Dateibaum wird pro geöffnetem Container und Paket einmal aufgebaut und bei Ansichtsaktualisierungen wiederverwendet. Die TOC liest Ganzzahlen ohne temporäre Datenkopien; die gleichen Bereichs- und Integritätsprüfungen bleiben aktiv.

Die Oberfläche bleibt während der Verarbeitung bedienbar. Dateien werden blockweise verarbeitet; SHA-256 nutzt CryptoKit, Zstandard 1.5.7 wird aus den mitgelieferten C-Quellen statisch eingebunden. Identische Dateiinhalte teilen sich einen Datenbereich. Unwirksame Kompression fällt auf RAW zurück. NUP-Inhalte werden weder entschlüsselt noch ausgeführt.

Beim Packen, Entpacken und bei **Speichern unter …** werden vorhandene Ausgabedateien und Zielordner nicht ersetzt. Diese Vorgänge verwenden temporäre Ausgaben neben dem Ziel und veröffentlichen sie nach erfolgreichem Abschluss.

**Änderungen übernehmen** bzw. **⌘S** liest und schreibt ausschließlich Verwaltungs- und Metadaten. Die Spielinhalte werden dabei weder kopiert noch dekomprimiert. Geschrieben werden der geänderte Metadatenblock, sein 64-Byte-Paketdatensatz und der 128-Byte-Header mit aktualisierter TOC-Prüfsumme und Dateigröße. Ein aktiver Metadatenblock am Dateiende wird wiederverwendet und kann wachsen oder schrumpfen. Liegt der Block innerhalb der Datei, wird die neue Fassung ans Ende angehängt; der frühere innere Block bleibt unreferenziert erhalten. Die Spielinhalte behalten ihre Offsets. Unveränderte Metadaten lösen keinen Schreibvorgang aus.

Vor dem ersten Schreibzugriff wird neben der NUP ein prüfsummengeschütztes Wiederherstellungsprotokoll angelegt. Es enthält nur die betroffenen Verwaltungsdaten sowie alte und neue Metadaten, maximal etwa 128 MiB; bei kleinen Textänderungen ist es typischerweise wenige KiB groß. Es wird nach erfolgreicher Strukturprüfung entfernt. Dateiinode, Zugriffsrechte, ACLs und erweiterte Attribute bleiben durch die Aktualisierung derselben Datei erhalten. Ein exklusives Dateilock verhindert gleichzeitige Schreibvorgänge anderer NUP-Studio-Instanzen. Ein veralteter Dateistand wird vor dem Schreiben abgewiesen.

Bei einem Fehler wird die Änderung zurückgenommen. Wird die App während des Schreibens beendet, stellt sie beim nächsten Öffnen anhand des Protokolls den vorherigen Stand wieder her oder übernimmt einen bereits als abgeschlossen markierten Stand. NUP und verbliebenes Protokoll dafür zusammen im selben Ordner lassen und die NUP bis zur Wiederherstellung nicht umbenennen. Das ist kein atomarer Austausch der gesamten Datei; andere Programme sollten sie während des Speicherns nicht verändern. Eine vollständige Garantie gegen Stromausfall oder defekte Speichermedien ist damit nicht verbunden.


Ressourcenlimits: 256 MiB TOC, 64 MiB Metadaten pro Paket und insgesamt 256 MiB Metadaten, 256 Verzeichnisebenen, 128 MiB maximales Zstandard-Fenster. Die Dateigröße selbst hat kein solches RAM-Limit. Namenskollisionen durch Groß-/Kleinschreibung oder Unicode-Normalisierung werden beim Entpacken konservativ abgewiesen. Es wird kein freier Speicherplatz reserviert; Schreibfehler werden gemeldet und temporäre Ausgaben entfernt.

Beim **Hinzufügen/Entfernen von Dateien** wird nur das Inhaltsverzeichnis neu aufgebaut. Nur neue Dateien werden komprimiert und angehängt; vorhandene komprimierte Inhalte bleiben bytegleich. Wächst das Inhaltsverzeichnis in belegte Datenbereiche hinein, werden die betroffenen Datenblöcke unverändert ans Ende verschoben. Eine vollständige NUP-Kopie ist nicht erforderlich; bei einem großen betroffenen Datenblock kann dennoch entsprechend viel kopiert werden. Entfernen löscht die Einträge, verkleinert die NUP aber nicht und ist kein sicheres Löschen der alten Datenbytes.

Die Vorbereitung benötigt temporären Platz nur für die neuen komprimierten Dateien. Ein separates, gestreamtes Wiederherstellungsprotokoll sichert den überschriebenen Dateianfang und die neue TOC, maximal etwa 513 MiB. Es wird vor dem ersten Container-Schreibzugriff veröffentlicht und nach Prüfung entfernt. Verschobene Bytes werden zurückgelesen und verglichen; neue Dateien werden vollständig per SHA-256 geprüft. Abbruch und Wiederherstellung verwenden dieselbe Inode und ein exklusives Lock. Für ein verbliebenes `.nup-files-….pending`/`.committed` gelten dieselben Hinweise zur gemeinsamen Aufbewahrung und zu Stromausfall wie beim Metadaten-Protokoll. Bibliotheksvorschauen stellen keine Protokolle automatisch wieder her.

## Tests

Mit **⌘U** in Xcode oder:

```sh
xcodebuild -project NUPStudio.xcodeproj -scheme NUPStudio \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../../builds/NUPStudio test
```

Die Tests benötigen weder Netzwerk noch Python. Kleine eingebettete Referenzcontainer wurden mit dem unveränderten Python-Original erzeugt; darunter ist ein Zstandard-Streaming-Frame mit 270 MiB unkomprimiertem Inhalt. Spezifische Regressionstests prüfen sämtliche Standard-Kennungen, alte Profileinstellungen und alle App-Workflows trotz einer unbekannten Kennung 0. Weitere Fälle prüfen Roundtrips, Deduplizierung, Metadaten, Abbruch, beschädigte Container, unsichere Namen und vorhandene Ziele.

Dateibearbeitungstests decken Hinzufügen/Entfernen über mehrere Pakete, geteilte Datenblöcke, erhaltene Metadaten und gespeicherte Bytes, Kollisionen, fremde Dateistände, Locks, Abbruch, unterbrochene Schreibphasen und widersprüchliche Protokolle ab. Ein synthetischer 4-GiB-Sparse-Fall prüft Struktur, unveränderten Originaloffset, Sentinel und geringen belegten Speicher; dessen künstlicher Original-Payload wird nicht vollständig gehasht. Normale Testcontainer werden vollständig geprüft.

## Aufbau und Lizenzen

`Sources/Core` enthält den Swift-Dateikern, `Sources/Views` die SwiftUI-Oberfläche, `Sources/Stores` den Zustand und die Hintergrundaufträge. AppKit bleibt auf Dateidialoge, Bildvorschau und Finder-Anzeige begrenzt.

- NUP-Format und Referenz: [a55uka/nup](https://github.com/a55uka/nup), Stand `d40d9cfa50792ba8021d2967d994d1b1c25d62b0`, MIT; siehe `Licenses/NUP-MIT.txt`.
- Zstandard 1.5.7: [facebook/zstd](https://github.com/facebook/zstd/tree/v1.5.7), Stand `f8745da6ff1ad1e7bab384bd1f9d742439278e99`, BSD; siehe `Licenses/Zstandard-BSD.txt`. Die benötigten Bibliotheksquellen liegen unter `Vendor/zstd`; sie wurden nicht funktional verändert.
