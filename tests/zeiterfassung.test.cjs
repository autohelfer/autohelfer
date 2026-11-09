const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

// Die produktiven Funktionen direkt aus der Single-File-App pruefen.
const html = readFileSync(join(__dirname, '..', 'index.html'), 'utf8');
function section(start, end) {
  const from = html.indexOf(start);
  const to = html.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Quellabschnitt fehlt: ${start}`);
  return html.slice(from, to);
}
const source = section('function saveDb(){', 'function nextId(t)') + '\n' +
  section('function mechIstArbeitsauftrag(a)', '// ---- Timer-Uhr starten');

function fixture() {
  let now = Date.parse('2026-11-09T09:00:00Z');
  let fail = false;
  class TestDate extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }
  const personal = [
    { id: 1, vorname: 'Pascal', nachname: 'Runser' },
    { id: 2, vorname: 'Ruben', nachname: 'Costa' },
    { id: 3, vorname: 'Ammar', nachname: 'Demir' },
  ];
  const storage = new Map([['ah_mitarbeiter', JSON.stringify(personal)]]);
  const job = (id, name) => ({ id, fahrzeugId:id, status:'geplant', mechanikerName:name, zeiterfassung:[] });
  const db = { auftraege:[job(1,'Pascal Runser'),job(2,'Pascal Runser'),job(3,'Ruben Costa'),job(4,'Ammar Demir')] };
  const context = vm.createContext({
    db, Date:TestDate, STORAGE_KEY:'autohelfer_v4', Event,
    MECHANIC_SESSION:{ mechFilter:'team', mechaniker:{name:''} },
    CURRENT_PROFILE:null, _mfsAuftragId:null,
    localStorage:{
      getItem:key => storage.get(key) || null,
      setItem:(key,value) => { if(fail) throw new Error('QuotaExceededError'); storage.set(key,value); },
    },
    document:{ dispatchEvent() {} },
    el:() => ({ classList:{ contains:() => false } }),
    renderMechanik() {}, mfsOpen() {}, mfsRender() {},
    showToast() {}, console:{ error() {} },
  });
  vm.runInContext(source, context);
  return { context, db, storage, advance:ms => { now += ms; }, failStorage:() => { fail = true; } };
}

test('Fahrzeugwechsel pausiert die alte und startet die neue Uhr ohne Ueberlappung', () => {
  const {context:c,db,advance,storage} = fixture();
  assert.equal(c.mechStarteArbeit(1),true);
  advance(90000);
  assert.equal(c.mechStarteArbeit(2),true);
  const [old,current] = db.auftraege;
  assert.equal(old.zeiterfassung[0].stop,current.zeiterfassung[0].start);
  assert.equal(old.zeitPause.grund,'Fahrzeug gewechselt');
  assert.equal(c.mechCalcGesamtzeit(old),90000);
  assert.equal(c.mechHatLaufendeSession(old),false);
  assert.equal(c.mechHatLaufendeSession(current),true);
  const saved=JSON.parse(storage.get('autohelfer_v4'));
  assert.equal(saved.auftraege[0].zeiterfassung[0].stop,saved.auftraege[1].zeiterfassung[0].start);
});

test('Rueckwechsel erhaelt die Arbeitszeit und rechnet die Pause nicht hinzu', () => {
  const {context:c,db,advance} = fixture();
  c.mechStarteArbeit(1); advance(60000);
  c.mechStarteArbeit(2); advance(180000);
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[0]),60000);
  c.mechStarteArbeit(1); advance(30000);
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[0]),90000);
  assert.equal(db.auftraege[0].zeiterfassung.length,2);
  assert.equal(db.auftraege[0].zeitPause,undefined);
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[1]),180000);
});

test('Wiederholte Auswahl desselben Auftrags setzt die laufende Session nicht zurueck', () => {
  const {context:c,db,advance} = fixture();
  c.mechStarteArbeit(1);
  const start=db.auftraege[0].zeiterfassung[0].start;
  advance(15000); c.mechStarteArbeit(1);
  assert.equal(db.auftraege[0].zeiterfassung.length,1);
  assert.equal(db.auftraege[0].zeiterfassung[0].start,start);
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[0]),15000);
});

test('Uhren anderer Mechaniker bleiben beim Wechsel unveraendert', () => {
  const {context:c,db,advance} = fixture();
  c.mechStarteArbeit(3);
  const before=JSON.stringify(db.auftraege[2]);
  c.mechStarteArbeit(1); advance(30000); c.mechStarteArbeit(2);
  assert.equal(JSON.stringify(db.auftraege[2]),before);
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[2]),30000);
});

test('Manuelle Pause bleibt beim erneuten Pausieren unveraendert', () => {
  const {context:c,db,advance} = fixture();
  c.mechStarteArbeit(1); advance(60000); c.mechPausiereArbeit(1);
  const pause=JSON.stringify(db.auftraege[0].zeitPause);
  advance(120000);
  assert.equal(c.mechPausiereArbeit(1),false);
  assert.equal(JSON.stringify(db.auftraege[0].zeitPause),pause);
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[0]),60000);
});

test('Pausegrund aendert weder Pausenbeginn noch erfasste Arbeitszeit', () => {
  const {context:c,db,advance} = fixture();
  c.mechStarteArbeit(1); advance(60000); c.mechPausiereArbeit(1);
  const since=db.auftraege[0].zeitPause.start;
  advance(60000); c.mechSetzePausengrund(1,'Warten auf Ersatzteil');
  assert.equal(db.auftraege[0].zeitPause.start,since);
  assert.equal(db.auftraege[0].zeitPause.grund,'Warten auf Ersatzteil');
  assert.equal(c.mechCalcGesamtzeit(db.auftraege[0]),60000);
});

test('Alte Buchungen behalten nach einer Uebergabe ihren urspruenglichen Mechaniker', () => {
  const {context:c,db,advance} = fixture();
  db.auftraege[0].zeiterfassung=[{start:'2026-11-09T08:30:00Z',stop:'2026-11-09T08:45:00Z'}];
  c.mechStarteArbeit(1); advance(60000);
  c.mechUebergebeAuftrag(db.auftraege[0],'Ruben Costa');
  assert.equal(c.mechHatLaufendeSession(db.auftraege[0]),false);
  assert.equal(db.auftraege[0].zeiterfassung[0].mechanikerName,'Pascal Runser');
  assert.equal(db.auftraege[0].zeiterfassung[1].mechanikerId,1);
  c.mechStarteArbeit(1);
  assert.equal(db.auftraege[0].zeiterfassung[2].mechanikerName,'Ruben Costa');
  assert.equal(db.auftraege[0].zeiterfassung[2].mechanikerId,2);
});

test('Legacy-Parallelstempelungen werden beim naechsten Arbeitswechsel beendet', () => {
  const {context:c,db} = fixture();
  for(const a of db.auftraege.slice(0,2)) {
    a.status='in_arbeit'; a.zeiterfassung=[{start:'2026-11-09T08:30:00Z',stop:null}];
  }
  c.mechStarteArbeit(2);
  assert.equal(db.auftraege.filter(c.mechHatLaufendeSession).length,1);
  assert.equal(c.mechHatLaufendeSession(db.auftraege[1]),true);
});

test('Ein Speicherfehler nimmt den gesamten Fahrzeugwechsel im Arbeitsspeicher zurueck', () => {
  const {context:c,db,storage,failStorage} = fixture();
  c.mechStarteArbeit(1);
  const before=JSON.stringify(db), saved=storage.get('autohelfer_v4');
  failStorage();
  assert.equal(c.mechStarteArbeit(2),false);
  assert.equal(JSON.stringify(db),before);
  assert.equal(storage.get('autohelfer_v4'),saved);
});

test('Abschluss, Fakturierung und Loeschen stoppen auch mehrere alte offene Sessions', () => {
  for(const status of ['fertig','freigegeben','erledigt','fakturiert','storniert','geloescht']) {
    const {context:c,db} = fixture();
    const a=db.auftraege[0];
    a.zeiterfassung=[{start:'2026-11-09T08:30:00Z',stop:null},{start:'2026-11-09T08:40:00Z',stop:null}];
    a.zeitPause={start:'2026-11-09T08:00:00Z',grund:'Manuell pausiert'};
    if(status==='geloescht') a.geloescht=true; else a.status=status;
    c.saveDb();
    assert.equal(c.mechHatLaufendeSession(a),false,status);
    assert.equal(a.zeitPause,undefined,status);
  }
});

test('Geschlossene Auftraege und fehlende Mechaniker starten keine Uhr', () => {
  const {context:c,db} = fixture();
  db.auftraege[0].status='erledigt';
  assert.equal(c.mechStarteArbeit(1),false);
  db.auftraege[1].mechanikerName='';
  assert.equal(c.mechStarteArbeit(2),false);
  assert.equal(db.auftraege.some(c.mechHatLaufendeSession),false);
});

test('Mechaniker-Login bestimmt den ausfuehrenden Mechaniker', () => {
  const {context:c,db} = fixture();
  c.CURRENT_PROFILE={rolle:'mechaniker',vorname:'Ammar',nachname:'Demir',garage_id:'garage-test'};
  c.mechStarteArbeit(1);
  assert.equal(db.auftraege[0].mechanikerName,'Ammar Demir');
  const s=db.auftraege[0].zeiterfassung[0];
  assert.equal(s.mechanikerId,3);
  assert.equal(s.garageId,'garage-test');
});

test('Beim Speicherfehler bleibt auch eine noch offene alte Abschlussbuchung unveraendert', () => {
  const {context:c,db,failStorage} = fixture();
  db.auftraege[2].status='erledigt';
  db.auftraege[2].zeiterfassung=[{start:'2026-11-09T08:30:00Z',stop:null}];
  const before=JSON.stringify(db);
  failStorage();
  assert.equal(c.mechStarteArbeit(1),false);
  assert.equal(JSON.stringify(db),before);
});

test('Die Auswahl einer fremden laufenden Arbeit veraendert keine Stempelung', () => {
  const {context:c,db} = fixture();
  c.mechStarteArbeit(3);
  c.CURRENT_PROFILE={rolle:'mechaniker',vorname:'Pascal',nachname:'Runser'};
  const before=JSON.stringify(db);
  assert.equal(c.mechStarteArbeit(3),false);
  assert.equal(JSON.stringify(db),before);
});
