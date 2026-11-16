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

### Geöffnete NUP prüfen und Befunde auswählen

**Prüfen** bzw. **⇧⌘R** prüft die gespeicherte NUP vollständig und zeigt eine Befundliste. Die Prüfung streamt die Inhalte lokal, sammelt Datei-/Hash-/Dekompressionsfehler und läuft nach einem einzelnen Dateifehler weiter. Paket und vollständiger interner Pfad stehen beim Befund. Bei mehr als 10.000 Dateifehlern werden alle Dateien geprüft, aber nur die ersten 10.000 Details angezeigt. Strukturfehler, die keinen sicheren Dateibaum zulassen, werden gesondert gemeldet; dann gibt es keine Zusage einer vollständigen Inhaltsprüfung.

Dateifehler auswählen und **In Dateiliste auswählen** markieren die betroffenen Dateien eines Pakets. Es wird nichts gelöscht. **Prüfergebnis** öffnet den letzten Bericht ohne erneutes Lesen der Spieldaten; **Alle Dateien zeigen** kehrt zur normalen Inhaltsliste zurück. Sichere Paket-/RomFS-/UUID-Korrekturen lassen sich per Auswahlkästchen und **Auswahl reparieren** gezielt anwenden. Notwendige Abhängigkeiten werden vor dem Schreiben geprüft. Prüfsummen und UUID werden passend zur Auswahl aktualisiert. Beschädigte Dateiinhalte werden nicht erfunden oder durch neue Hashes als intakt ausgegeben.

Die Prüfung erhält offene Entwürfe und verändert die NUP nicht. Vor einer Reparatur muss der Entwurf übernommen oder verworfen und erneut geprüft werden. Ein zwischenzeitlich geänderter Dateistand macht die Schreibvorschau ungültig.

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

Unter **NUP Studio → Einstellungen** (`⌘,`) wählst du **Systemsprache**, **Deutsch**, **Română** oder **English**. Automatisch verwendet die App die erste bevorzugte macOS-Sprache, bei anderen Sprachen Englisch. Die Auswahl wirkt sofort und wird für den nächsten Start gespeichert.

- **Container**: NUP öffnen oder in das Fenster ziehen; Paket auswählen, Dateibaum durchsuchen und Metadaten bearbeiten.
- **Bibliothek**: **NUP-Ordner** auswählen (⇧⌘O). Alle regulären `.nup`-/`.NUP`-Dateien einschließlich Unterordnern erscheinen mit Pfad und Größe. Nach Spielname, Dateiname oder Pfad filtern, eine Zeile auswählen und **Öffnen** anklicken oder die Zeile doppelklicken. **Neu einlesen** aktualisiert die Liste; **Zur Bibliothek** führt vom geöffneten Container zurück. Symbolische Links werden übersprungen. Der zuletzt erfolgreich eingelesene Ordner wird gespeichert und beim nächsten App-Start automatisch neu eingelesen. Ist das Laufwerk getrennt, bleibt die Auswahl erhalten; nach dem Verbinden **Erneut versuchen** wählen. Die Ordnersuche liest zuerst nur Namen und Dateiattribute. Anschließend werden Spielnamen und Cover im Hintergrund aus den NUP-Metadaten nachgeladen. Die Spieldaten werden dafür nicht gelesen oder entpackt. Ordner, die außerhalb von **Erstellen** ins Fenster gezogen werden, öffnen ebenfalls die Bibliothek.
- **Prüfen**: vollständige SHA-256-Prüfung aller Dateien. Das Aktionsmenü bietet zusätzlich eine reine Strukturprüfung.
- **Diagnose / Reparatur**: Über die Werkzeugleiste, **Container → NUP diagnostizieren / reparieren …** (⇧⌘D) oder das Kontextmenü einer Bibliothekszeile aufrufen. Scheitert das Öffnen, erscheint die Diagnose automatisch. Die Vorschau zeigt alte und vorgeschlagene Titel-IDs, Paketarten, interne NCM-Versionen und Standalone-Flags samt Belegdateien. Für eindeutig wiederherstellbare leere RomFS-Einträge zeigt sie außerdem **/romfs wieder verbinden**, die korrigierte Eintragszahl und vorhandene Namen. Erst **Direkt reparieren** schreibt. **Neu diagnostizieren** liest den aktuellen Stand erneut ein.
- **Entpacken**: das ausgewählte Paket oder nur ExeFS/RomFS in einen neuen Ordner schreiben. Geschriebene Inhalte werden per SHA-256 geprüft.
- **Erstellen**: Dump-Ordner wählen, Metadaten ergänzen, Kompressionsstufe einstellen und außerhalb des Quellordners speichern.
- **Cover in der Bibliothek vormerken**: Auf Cover/Platzhalter oder **Cover …** klicken, Paket und PNG/JPEG wählen, **Cover vormerken**. Das Cover landet im gemeinsamen Entwurf. Erst **Übernehmen** speichert es zusammen mit anderen Änderungen. Der Spielname und die Bibliothekszeile werden nach erfolgreichem Speichern aktualisiert.
- **Metadaten**: Titel, Publisher, angezeigte Version, Cover, Sprachtitel/-Cover, Quelle und Build-ID bearbeiten. **Cover kopieren** übernimmt das aktuelle Cover eines anderen Pakets oder gibt es an ausgewählte Pakete im selben Container weiter. **Aus Quelle lesen** ergänzt leere Felder und fehlende Sprachtitel aus eingebetteten NACP-Metadaten, einer control.nacp im Paket oder einer separat ausgewählten .nacp-Datei. Titel und Publisher lassen sich auch aus einem anderen Paket ergänzen. **Übernehmen** speichert den gemeinsamen Entwurf. Titel-ID, Paketart und interne Version bleiben geschützt. Unveränderte und unbekannte Metadaten werden bytegenau erhalten, auch wenn einzelne vorhandene Sprach-/Bildfelder nicht lesbar sind.
- **Dateien hinzufügen/entfernen**: Unter **Inhalte** Paket/Zielordner wählen und Dateien hinzufügen oder zum Entfernen vormerken. Neue Dateien erscheinen mit Plus-Markierung, geplante Entfernungen durchgestrichen. **Entfernen zurücknehmen** hebt die Vormerkung auf; das Entfernen einer vorgemerkten neuen Datei nimmt nur sie aus dem Entwurf. Dateien mit gleichem Namen können ersetzt werden, indem die alte Datei zum Entfernen und die neue zum Hinzufügen vorgemerkt wird. Die Auswahl der Quelle wird bei Übernehmen erneut auf Veränderungen geprüft.
- **Gemeinsam speichern**: Die dauerhaft sichtbare Entwurfsleiste gilt für alle Pakete der geöffneten NUP. **Übernehmen** (⌘S) speichert Metadaten und Dateiänderungen gemeinsam direkt in der Originaldatei, mit Rücknahme bei Abbruch/Fehler. Bis dahin bleibt die NUP unverändert. **Verwerfen** setzt nur den Entwurf zurück. **Speichern unter …** (⇧⌘S) speichert den gesamten Entwurf in einer neuen NUP und kopiert dafür deren Spielinhalte; das Original bleibt erhalten. Beim Öffnen einer anderen Datei, Diagnose, Erstellen, Schließen oder Beenden fragt die App nach Übernehmen/Verwerfen/Abbrechen. Ein Entwurf bleibt bei einem Fehler erhalten; nach bestätigter Rücknahme kann er erneut übernommen werden. Nicht übernommene Entwürfe werden nicht über einen erzwungenen Prozessabbruch hinweg gespeichert.
- **Finder-Doppelklick**: NUP-Dateien werden über die native macOS-Dateiübergabe angenommen. Beim App-Start wird der Dateiwunsch bis zur Anbindung des Fensters gepuffert; bei laufenden Vorgängen wird er anschließend geöffnet. Ein geschlossenes Hauptfenster wird wieder angezeigt. Offene Entwürfe bleiben durch die bestehende Rückfrage geschützt.
- **⌘O** öffnen, **⌘N** erstellen, **⌘S** übernehmen, **⇧⌘S** speichern unter, **⇧⌘R** prüfen, **⇧⌘E** entpacken, **⌘.** abbrechen.

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

Metadatenblöcke dürfen auch im freien Bereich nach der TOC und vor `blob_offset` liegen: `meta_offset` ist ein absoluter Dateioffset. Der Leser prüft weiterhin Header-/TOC-Grenzen und sämtliche Überlappungen. Das gilt für Öffnen, Bibliothek, Diagnose und Bearbeitung. Solche Dateien müssen nicht umgepackt oder an ihren Headern verändert werden.

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

Die gemeinsame Übernahme verwendet für reine Metadatenänderungen eines einzelnen Pakets weiter das kleine Metadaten-Protokoll. Kombinierte Datei-/Metadatenänderungen und Änderungen an mehreren Paketen verwenden eine gemeinsame begrenzte Datei-Transaktion. Sie hängt neue Daten/Metadaten an, baut bei Dateiänderungen die TOC einmal neu auf und schützt den überschriebenen Anfang im bestehenden gestreamten Rücknahmeprotokoll. Vorhandene Spielinhalte werden nicht neu komprimiert; nur Blöcke, die durch eine wachsende TOC überdeckt würden, müssen an das Dateiende verschoben werden. Entfernen verkleinert die NUP nicht. Nach nachgewiesener Rücknahme wird der Entwurf auf die neue Dateirevision gesetzt, damit ein erneuter Versuch möglich bleibt; fremde Änderungen werden nicht stillschweigend übernommen.

## Diagnose und direkte Reparatur

Die Diagnose prüft ausgewählte echte `exefs/main.npdm`- und `meta/*.cnmt`-Dateien einschließlich ihrer gespeicherten SHA-256-Werte. Nur eindeutige, untereinander passende Angaben werden übernommen. NPDM-Offsets werden aus dem META-Header gelesen; Dateinamen oder eine gefundene Zeichenfolge allein reichen nicht als Beleg. `0100…`/`0400…` werden nicht pauschal umgeschrieben. Widersprüchliche Belege, eine beschädigte TOC-Prüfsumme oder nicht eindeutig auflösbare Mehrfach-Basispakete sperren die Reparatur. Die normale Öffnen-/Bearbeiten-Prüfung bleibt strikt; Diagnose-Snapshots sind für normale Schreibaktionen gesperrt.

Bei **„Unbenutzte Kindknotenplätze“** kann die Diagnose eine versehentlich auf 0 gesetzte Eintragszahl eines direkten Paket-Ordners `/romfs` wiederherstellen. Dessen deklarierter Startplatz muss exakt eine vollständige unbenutzte, zusammenhängende Spanne verankern und genau einem leeren RomFS zugeordnet sein. Danach müssen alle Knoten wieder genau einmal erreichbar, Namen sortiert, Bereiche gültig und sämtliche übrigen Strukturprüfungen erfolgreich sein. Das korrigiert den Kirby-Fehlertyp ohne Raten anhand von Dateinamen. Echte leere Ordner bleiben leer. Fehlende Daten, mehrdeutige Zuordnungen, nicht-null abgeschnittene Eintragszahlen, Zyklen oder sonstige Strukturfehler bleiben gesperrt.

Eine bestätigte Reparatur schreibt ausschließlich geänderte 64-Byte-Paketdatensätze, belegte 4-Byte-RomFS-Eintragszahlen und den 128-Byte-Header. Alle Spieldaten, Metadaten-TLVs und Dateioffsets bleiben erhalten. Die interne NCM-Version kann anders aussehen als die angezeigte Version; Letztere bleibt unverändert. Vor dem Schreiben werden Vorschau, Dateirevision und Belege erneut geprüft. Ein begrenztes `.nup-repair-….pending`/`.committed`-Protokoll (maximal 590.168 Byte bei zusammen 4096 Korrekturen) schützt die Schreibbereiche. Das Format v2 enthält explizite Datensatzlängen; Paket-Protokolle aus v1 bleiben lesbar. Eine Wiederherstellung prüft RomFS-Offsets und Eintragszahlen erneut gegen den ursprünglichen Dateibaum, bevor sie schreibt. Bei Abbruch wird zurückgenommen; beim erneuten Öffnen nach einem Prozessabbruch wird der frühere Stand wiederhergestellt oder ein bereits abgeschlossen markierter Stand behalten. NUP und verbliebenes Protokoll dafür gemeinsam im selben Ordner lassen und nicht umbenennen. Es gibt keine Garantie gegen Stromausfall/Medienfehler und keine automatische Reparatur beschädigter Spielinhalte oder Bestätigung eines Spielstarts.

Diagnose-Limits: 4 MiB unkomprimiert/8 MiB gespeichert je Belegdatei, zusammen 64 MiB Lese-/Ausgabebudget und höchstens 256 Belegdateien. Ein überschrittenes Limit sperrt die Reparatur. Die Vorschau und Bibliotheksvorschauen stellen keine Protokolle automatisch wieder her; das normale erneute Öffnen übernimmt die Wiederherstellung.

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
