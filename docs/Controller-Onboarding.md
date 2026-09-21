# Controller-Erkennung, Firmware und portable LED-Profile

Stand: 21.09.2026 · Entwurf für Ambient Lighting 3

## Ausgangspunkt

Die bisherige FastLED-Firmware versteht nur `led`-Farbpakete und `les` zum Anzeigen eines Bildes. Sie meldet keine Geräteidentität und speichert keine Einstellungen. Die App hält Raster, Anzahl, Startversatz, Richtung und Farbkorrektur derzeit in einer lokalen JSON-Datei. Ein neues Gerät oder ein anderer Mac kann diese Daten deshalb nicht selbstständig übernehmen.

Die App zeigt ab diesem Stand ausschließlich serielle Ports mit einem USB-Elternknoten und USB Vendor/Product ID an. Sie öffnet beim Suchen keinen Port. Das blendet virtuelle Bluetooth- und Systemports aus. Eine USB-Seriell-Kennung allein beweist **nicht**, dass dahinter ein ESP oder überhaupt ein Microcontroller steckt: CP210x-, CH34x- und FTDI-Brücken können an sehr unterschiedlichen Geräten hängen. Es gibt auch kein verlässliches Merkmal eines passiven „USB-Kabeltyps“. Automatische Verbindung oder automatisches Flashen allein aufgrund eines Namens oder einer VID/PID bleiben ausgeschlossen.

## 1. Geräteauswahl ohne ungewolltes Flashen

1. **Nur lesen:** IOKit ermittelt USB Vendor ID, Product ID, Produktname und, falls vorhanden, Seriennummer für `/dev/cu.*`. Massenspeicher ohne serielle Schnittstelle und Bluetooth-Ports erscheinen nicht. Neue Ports dürfen erst nach einer Nutzeraktion geöffnet werden.
2. **Port bewusst wählen:** Die Oberfläche zeigt USB-Kennung und Gerätenamen. Bei mehreren Kandidaten gibt es keine automatische Auswahl. Der Port wird unmittelbar vor dem Öffnen erneut gegen diese Kennung geprüft, damit ein inzwischen neu eingestecktes Gerät nicht einen alten Pfad übernimmt.
3. **Eigene Firmware erkennen:** Nach explizitem Verbinden sendet die App eine harmlose, versionsgebundene `AL3?`-Anfrage und wartet mit kurzer Frist auf `AL3!` mit Geräte-ID, Firmware-Version und Fähigkeiten. Die alte `led`/`les`-Firmware ignoriert diese Zeichenfolge. Ohne gültige Antwort bleibt das Gerät im Legacy-Modus; es gibt keinen Profilzugriff und keinen automatischen Flash.
4. **Vor einem Firmware-Update:** Die App beendet den LED-Stream und gibt den Port frei. Ein getrenntes Flash-Werkzeug prüft am **ausdrücklich gewählten** Port den wirklichen Espressif-Chip und die Flash-Eigenschaften. Danach muss die Chipfamilie zum ausgewählten, versionierten Firmware-Artefakt passen. Bei Abweichung bricht der Vorgang vor jedem Schreibzugriff ab. Das Werkzeug bekommt immer `--port`; es darf nie seine automatische Suche über alle seriellen Ports verwenden.
5. **Flashen als eigener Vorgang:** Der Nutzer sieht Board, Chip, Port, Firmware-Version und die Auswirkungen auf ein vorhandenes Profil, bevor er „Firmware installieren“ auslöst. Nach dem Schreiben folgen Verifikation, Neustart, `AL3`-Handshake und gegebenenfalls Wiederherstellung des Profils. Keine Funktion „gesamten Flash löschen“ im normalen Ablauf.

Ein explizit gewählter generischer USB-Seriell-Adapter ist noch kein verifiziertes Board. Die Chip-Prüfung kann den Controller zurücksetzen und darf daher erst im Flash-Dialog erfolgen. Das aktuelle Filtern ist eine erste Schutzschicht, keine Garantie für die Identität der Hardware.

## 2. Profil auf dem Controller

Ein Controller erhält eine dauerhafte Geräte-ID und ein versioniertes Profil. Die App lädt es nach einem erfolgreichen `AL3`-Handshake automatisch. Das Profil ist die maßgebliche Quelle für die tragbaren LED-Einstellungen; lokale Einstellungen bleiben für alte Firmware und vor dem ersten Speichern erhalten.

| Auf dem Controller | Weiterhin lokal auf dem Mac |
| --- | --- |
| Physische und aktive LED-Anzahl, Zeilen, Spalten, Startversatz, Richtung | macOS-`displayID`, zuletzt gewählter Port |
| Schwarze Ränder berücksichtigen; Sättigung, Gamma, RGB-Gains, Helligkeit, Glättung | Aufnahmeauflösung und Ziel-Bildrate |
| Profil-Schema, Revision, Prüfsumme, optionale Monitor-Kennung | Fensterzustand und Berechtigungen |

Die LED-Pinbelegung, der LED-Typ und die Farbreihenfolge stehen zunächst im **Board-spezifischen Firmware-Manifest**. Sie lassen sich mit FastLED nicht für jedes Board gefahrlos zur Laufzeit wechseln. Die Firmware meldet diese Werte an die App. Eine spätere dynamische Pinwahl braucht gesonderte Hardwaretests.

Die optionale Monitor-Kennung kann Hersteller, Produkt und die EDID-Seriennummer enthalten. Wenn genau ein passendes Display und ein Controller verbunden sind, wird das Profil automatisch angewandt. Fehlt eine eindeutige Seriennummer oder gibt es mehrere Displays/Controller, verlangt die App einmalig eine Zuordnung. Ein macOS-`displayID` allein ist kein transportabler Schlüssel.

**Speichervorgang:** Änderungen an Slidern bleiben zunächst im RAM und in der lokalen Rückfallkopie. Erst „Auf Controller speichern“ validiert alle Felder, sendet eine vollständige Profilversion und wartet auf eine Bestätigung mit Revision und Prüfsumme. Anschließend liest die App das Profil zurück und meldet Erfolg erst bei Übereinstimmung. Gleiche Daten werden nicht erneut in Flash geschrieben. So belasten Live-Regler das Flash nicht.

**Speichertechnik:** Für ESP32 bietet `Preferences` den NVS-Speicher für kleine Blobs; NVS ist auf Konfigurationswerte und Stromausfälle ausgelegt. Für ESP8266 eignet sich LittleFS mit einer versionierten Profil-Datei besser als ein `EEPROM.commit()` bei jeder Änderung, da EEPROM-Emulation Flash-Sektoren umschreibt. Das konkrete A/B- bzw. temporäre-Datei-Verfahren wird mit Stromunterbrechungstests festgelegt. Unbekannte Schema-Versionen werden gelesen und angezeigt, aber nicht blind überschrieben.

## 3. Firmware-Build und In-App-Flashen

**PlatformIO ist für den Build geeignet.** Beide Plattformen unterstützen das Arduino-Framework; FastLED unterstützt ESP32 und ESP8266. Der vorhandene Sketch kann als Ausgangspunkt für gemeinsames C++ dienen. `FastLED.addLeds`, `Serial` und das alte Farbprotokoll bleiben erhalten. Board-spezifisch werden LED-Pin, Boot-Verhalten, Speicheradapter und gegebenenfalls FastLED-Ausgabetreiber. Als erste getestete Umgebungen genügen ein konkretes ESP32-DevKit und ein konkretes ESP8266-Board; weitere ESP32-S2/S3/C3-Varianten erhalten eigene Images, sobald reale Boards geprüft sind.

PlatformIO soll **Firmware beim Entwickeln bauen**, aber ein Anwender braucht es nicht parallel zur App zu installieren. Ein Release enthält vorgebaute Images samt Manifest, Hash, unterstützten Chipfamilien, Flash-Layout und Firmware-Protokollversion. Die App nutzt zum Flashen einen mitgelieferten, signierten `esptool`-Helper und ruft ihn mit festem Port und passenden Image-Adressen auf. Die genaue Packaging-Lösung für Python/esptool muss beim Release-Build und bei der macOS-Signierung geprüft werden. Ein beliebiges `.bin` aus dem Dateidialog erhält keinen Ein-Klick-Flash-Pfad.

Ein Firmware-Update darf die Profil-Partition nicht absichtlich löschen. Vor dem Flash wird ein vorhandenes Profil in der App gesichert; nach dem Update wird es per Handshake geprüft und bei Bedarf wiederhergestellt. Auf ESP8266 muss das gewählte Flash-/Dateisystem-Layout stabil bleiben, da ein Layoutwechsel gespeicherte Daten gefährden kann.

## Reihenfolge und Abnahme

1. **Jetzt:** USB-Seriell-Erkennung und erneute Portprüfung in der App; Bluetooth-/Systemports verschwinden aus der Liste. Kein automatisches Öffnen, Flashen oder Schreiben auf Geräte.
2. **Profil-Protokoll:** `AL3`-Handshake, getrennte Gerätekonfiguration, alte Farbpakete als Legacy-Fallback, ESP32-/ESP8266-Firmware und expliziter Speichern/Laden-Ablauf. Beide Firmware-Images bauen, Profil über Neustart und anderen Mac prüfen.
3. **Flasher:** Board-Manifeste, geprüfte Release-Images, Chip-Probe am gewählten Port, sichere Prozesszeitgrenzen, Backup/Restore, Fortschritt und Fehlerbehandlung. Erst nach erfolgreichen Hardwaretests in der App freischalten.

Abnahmeszenarien: Bluetooth-Ports und ein gewöhnlicher USB-Stick werden nicht angeboten; ein unbekannter USB-Seriell-Adapter wird nie automatisch geöffnet oder geflasht; ein falscher Chip wird vor dem Schreiben abgewiesen; ein unantwortender Port blockiert nicht die Oberfläche; ein gespeichertes Profil überlebt Neustart, Firmware-Update und Laptop-Wechsel; bei zwei möglichen Monitoren fragt die App nach der Zuordnung.

## Technische Quellen

- [Apple IOKit USB-Deskriptoren](https://developer.apple.com/documentation/iokit/usbspec_h_user-space/usb_descriptor_and_ioregistry_constants)
- [Espressif esptool: Port-Auswahl und automatische Suche](https://docs.espressif.com/projects/esptool/en/latest/esp8266/esptool/basic-options.html)
- [PlatformIO ESP32](https://docs.platformio.org/en/latest/platforms/espressif32.html) und [ESP8266](https://docs.platformio.org/en/latest/platforms/espressif8266.html)
- [FastLED-Plattformen](https://github.com/FastLED/FastLED/blob/master/src/platforms/readme.md)
- [ESP32 Preferences/NVS](https://docs.espressif.com/projects/arduino-esp32/en/latest/tutorials/preferences.html) und [ESP8266 LittleFS](https://arduino-esp8266.readthedocs.io/en/latest/filesystem.html)
