# CLAUDE.md — Verbindliche Projektregeln

Diese Regeln gelten fuer **jede** Arbeit an diesem Projekt. Sie haben Vorrang vor
allgemeinen Konventionen. Lies sie vor jeder Aenderung.

## 1. Was ist autohelfer.ch

- **autohelfer.ch** ist eine Schweizer Garagen-Software (Werkstatt-/Betriebssoftware).
- Technisch eine **Single-File-App**: die gesamte Anwendung liegt in `index.html`
  (~24'500 Zeilen HTML + CSS + JavaScript in einer Datei).
- **Produktiv im Einsatz** bei der **Garage Fuoco GmbH, Muttenz**. Es ist keine
  Spielwiese — Fehler treffen echte Kunden und echten Betrieb.
- **Ziel**: spaeter Verkauf als SaaS (Multi-Tenant).

## 2. Oberste Regel: STABILITAET VOR ALLEM

- **Keine Experimente. Keine Umbauten ohne Auftrag.**
- Im Zweifel: nichts aendern und nachfragen.
- Jede Aenderung muss den bestehenden, produktiven Zustand respektieren.

## 3. Nur isolierte, gezielte Edits

- **Keine globalen CSS-Aenderungen.** Bestehende Klassen werden **nicht** angefasst.
- **Neue CSS-Klassen nur mit seitenspezifischem Prefix**, gescopt auf die Seite.
  Beispiel: `#page-debitoren .deb-...`, `#page-rechnungen .rech-...`.
- Aenderungen bleiben lokal auf die betroffene Seite/Funktion begrenzt.
  Keine Nebenwirkungen auf andere Seiten.

## 4. Vorgehen bei jeder Aenderung

1. **Vor jedem Styling-Fix zuerst die HTML-Struktur pruefen** (welche Elemente,
   welche Klassen/IDs, welcher Container) — nicht blind CSS schreiben.
2. **Vor der Aenderung kurz zeigen, was genau geaendert wird** (welche Zeilen,
   welcher Effekt), bevor der Edit ausgefuehrt wird.
3. Aenderung durchfuehren — moeglichst klein und isoliert.
4. **Nach JEDER Aenderung: JavaScript mit `node --check` validieren.**
   - Bei Fehler: **Aenderung sofort zuruecknehmen** (revert), Ursache pruefen.
   - Nie einen fehlerhaften Zustand stehen lassen.

> Hinweis Werkzeug: `node --check` prueft eine `.js`-Datei. Da die App eine
> Single-File-`index.html` ist, wird zur Validierung der betroffene `<script>`-Block
> in eine temporaere `.js`-Datei extrahiert und mit `node --check` geprueft.
> **Node.js muss dafuer installiert sein** (siehe Abschnitt 9).

## 5. Design & UI

- **Mobile-First.** Professionelle **SaaS-Optik**, sauber und ruhig.
- **Icons: Stroke-Breite 1.75.**
- **Einziger Akzentfarbe: Orange `#e8a020`.** Keine weiteren Akzentfarben einfuehren.

## 6. Backend & Datenmodelle

- **Backend: Supabase.** Login ist bereits umgesetzt.
- **Datenmodelle API-ready halten** fuer die spaetere Multi-Tenant-SaaS:
  saubere, stabile Feldnamen; mandantenfaehig denkbar (z.B. Tenant-/Org-Bezug);
  keine Modelle bauen, die einem spaeteren Multi-Tenant-Umbau im Weg stehen.

## 7. Schweizer Fachkontext

- **QR-Rechnung nach SIX-Standard v2.3.**
- **QRR-Referenz: 27-stellig, Pruefziffer nach Modulo-10 (rekursiv).**
- **Dreistufiges Mahnwesen** (1., 2., 3. Mahnung).
- **Sprache: Deutsch (Schweiz).** **Kein `ß`** — immer `ss`.

## 8. Seitenstruktur (Stand Ausgangszustand)

Alle Seiten sind `<div class="page" id="page-...">` innerhalb von `<main class="main">`.
Vorhandene Seiten: dashboard, kunden, kunden-detail, fahrzeug-detail, fahrzeuge,
reifenlager, auftraege, rechnungen, debitoren, mechaniker, mitarbeiter, lieferanten,
team, vorlagen, ersatzwagen, einstellungen.

## 9. Lokale Umgebung / Setup

- Diese Datei `index.html` ist statisch — kein Build-Schritt noetig.
- **Node.js ist auf dieser Maschine aktuell NICHT installiert** — die in Abschnitt 4
  geforderte `node --check`-Validierung kann erst laufen, wenn Node installiert ist.
  Bis dahin ist keine automatische JS-Validierung moeglich. Node.js installieren:
  <https://nodejs.org> (LTS).
