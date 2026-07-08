# Kampfplan: autohelfer.ch auf das naechste Level

Stand: 8. Juli 2026, Nachtschicht. Vision des Inhabers: iPad-first —
Mechaniker arbeiten am iPad in der Werkstatt (grosse Ansicht, «Weiter»
statt Navigation), der Geschaeftsfuehrer ist mobil mit dem iPad im
Betrieb, Fotos und Notizen fliessen direkt in die Auftraege, und die
Tagesuebersicht ist das taegliche Cockpit (wer kommt, wann bereit,
was in Arbeit, welcher Mechaniker).

---

## 1. Heute Nacht bereits umgesetzt

| Commit | Verbesserung |
|---|---|
| `5b1ce46` | **Tagesuebersicht**: Mechaniker-Chip pro Auftrag, oranger «in Arbeit»-Balken + Hintergrund, Bereit-bis-Zeit fett |
| `cb2658b` | **Mechaniker «Weiter»-Button**: grosser oranger Button (44px) im Vollbild-Auftrag springt zum naechsten offenen Auftrag — von Auftrag zu Auftrag ohne Umweg ueber die Uebersicht |

Bereits vorhanden (gute Basis): Vollbild-Auftragsansicht fuer Mechaniker
mit Timer, Checkliste, Kamera-Fotos (`capture="environment"` oeffnet
direkt die iPad-Kamera), Sprachnotizen; Homescreen-Metadaten fuer iOS.

## 2. Befund Design (iPad-Tauglichkeit)

- **Schriftgroessen zu klein fuer Werkstatt-Distanz**: Tagesuebersicht
  arbeitet mit 9–11px (Chips, Zeiten, Status-Badges). Auf dem iPad auf
  der Werkbank ist das nicht auf Armlaenge lesbar. Ziel: Kerninfo
  (Kunde, Kennzeichen, Zeiten, Status) 14–17px, Chips min. 12px.
- **Touch-Ziele unter Apple-Minimum**: «Details»-Button 10px Schrift,
  ~26px Hoehe (Apple HIG: 44×44pt). Ganze Auftragszeile sollte
  antippbar sein statt eines kleinen Buttons.
- **Dunkles Theme ist richtig** fuer die Werkstatt (Blendung), Kontraste
  passen; Orange als einzige Signalfarbe funktioniert — «in Arbeit»
  (orange) vs. «Wartekunde» (rot) ist jetzt klar getrennt.
- **App-Icon**: apple-touch-icon ist als SVG hinterlegt — iOS rendert
  nur PNG. Fuer den Homescreen ein 180×180-PNG erzeugen.

## 3. Befund UX-Psychologie (wenig Klicks)

Prinzipien, auf denen der Plan aufbaut:

- **Hicks Gesetz** (Auswahlzeit waechst mit Optionen): Der Mechaniker
  soll pro Bildschirm EINE primaere Aktion sehen. Der neue
  «Weiter»-Button setzt genau das um: keine Auswahl, nur Vorwaerts.
- **Fitts Gesetz** (grosse, nahe Ziele sind schneller): grosse Buttons
  am unteren Bildschirmrand (Daumenzone am iPad), 44px+.
- **Zeigarnik-Effekt** (Offenes bleibt im Kopf): offene Auftraege und
  laufende Timer immer sichtbar — erledigt = sichtbar abgehakt.
- **Default-Automatismen statt Klicks**: Oeffnen eines Auftrags setzt
  schon heute automatisch «in Arbeit». Naechster Schritt: Timer beim
  Oeffnen automatisch starten (1 Klick weniger, zigmal pro Tag).
- **Klickpfade heute** (gezaehlt): Mechaniker von «Auftrag fertig» zu
  «naechster Auftrag begonnen»: vorher 4 Taps (schliessen, Liste,
  Auftrag suchen, oeffnen) — jetzt 1 Tap («Weiter»). Geschaeftsfuehrer
  Foto in Auftrag: heute 4–5 Taps ueber die Mechaniker-Vollbildansicht;
  Ziel 2 Taps (Kamera-Button direkt in der Tagesuebersicht-Zeile).

## 4. Die unbequeme Wahrheit: Multi-iPad braucht das Backend

**Alle Daten liegen heute in localStorage — pro Geraet, pro Browser.**
Wenn morgen drei iPads in der Werkstatt laufen, hat jedes iPad seine
eigene, getrennte Datenwelt: Der Auftrag, den der Geschaeftsfuehrer am
iPad erfasst, existiert auf dem iPad des Mechanikers nicht. Die
iPad-Vision steht und faellt mit der Migration localStorage → Supabase
(Login existiert bereits). Zusaetzlich: Fotos als Base64 in
localStorage sprengen das Speicherlimit (~5–10 MB) nach wenigen Tagen
Werkstattbetrieb — Fotos gehoeren in Supabase Storage.

## 5. Phasenplan

### Phase 0 — Quick Wins (diese Woche, klein)
1. ~~Tagesuebersicht: Mechaniker + in Arbeit + Bereit-bis~~ ✓ erledigt
2. ~~«Weiter»-Navigation Mechaniker~~ ✓ erledigt (v1)
3. iPad-Lesbarkeits-Pass Tagesuebersicht: Schriftgroessen rauf,
   ganze Zeile antippbar (seitengescopte Aenderung)
4. PNG-App-Icon (180×180) fuer den iPad-Homescreen
5. Timer-Autostart beim Oeffnen eines Auftrags (mit Abschalt-Option)

### Phase 1 — Mechaniker-iPad-Modus komplett (1–2 Wochen)
6. Tagesliste des Mechanikers als grosse Karten (eine Karte = ein
   Auftrag, Status/Zeit/Fahrzeug in 16px+), «Tag starten»-Knopf
   oeffnet den ersten Auftrag → «Weiter»-Kette bis Feierabend
7. Abschluss-Schritt im «Weiter»-Fluss: Checkliste offen? Foto fehlt?
   → ein Bestaetigungs-Screen statt verstreuter Tabs
8. Schnellfoto fuer den Geschaeftsfuehrer: Kamera-Knopf direkt in
   jeder Zeile der Tagesuebersicht (Foto → landet im Auftrag)
9. Schnellnotiz ebenso (Text oder Diktat — Spracherkennung existiert)

### Phase 2 — Das Fundament: echtes Multi-Device (2–4 Wochen, strategisch)
10. Datenmigration localStorage → Supabase (Modelle sind API-ready
    angelegt; Login existiert) — danach sehen alle iPads dieselben Daten
11. Fotos/Dokumente → Supabase Storage statt Base64
12. Rollen: Mechaniker-Login sieht seine Auftraege, Admin alles
13. Live-Aktualisierung der Tagesuebersicht (Supabase Realtime):
    Status-Wechsel des Mechanikers erscheint sofort beim Chef

### Phase 3 — Absicherung & Politur (parallel/danach)
14. Claude-API-Key aus dem Browser in eine Supabase Edge Function
15. Offline-Faehigkeit (Service Worker): Werkstatt-WLAN-Aussetzer
    duerfen keine Daten kosten
16. GARAGE/FIRMA-Datenmodell vereinheitlichen (bekannter Befund V2)

## 6. Risiken

- **localStorage-Quota** (Fotos!) — bis Phase 2 gilt: Fotoflut vermeiden
- Single-File-App waechst (~25'400 Zeilen) — bei Phase 2 Modul-Schnitt
  pruefen, aber erst wenn das Backend steht (Stabilitaet vor Umbau)
- Jede Phase: kleine, isolierte Commits, `node --check`, Browser-Beleg
