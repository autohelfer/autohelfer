import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {workshopDatabase,seedWorkshop,users} from './support/workshop-db.mjs';

let database;
before(async()=>{database=await workshopDatabase();});
after(async()=>{await database.close();});
const rpc=(name,args={},user=users.admin)=>database.rpc(name,args,user);
const time=(action,order,name='Pascal Runser',extra={},user=users.admin)=>rpc('ah_workshop_time',{p_action:action,p_order_id:order,p_mechanic_name:name,p_request_id:randomUUID(),...extra},user);
const running=s=>s.data.auftraege.flatMap(a=>a.zeiterfassung.filter(t=>!t.stop).map(t=>({order:a.id,...t})));

test('Import erhaelt vorhandene IDs und Kunden-/Fahrzeugbezug',async()=>{
  const data=seedWorkshop();
  data.auftraege[0].zeiterfassung=[{start:'2026-11-01T08:00:00Z',stop:'2026-11-01T08:30:00Z',manuell:true,notiz:'Bestandszeit'}];
  const s=await rpc('ah_workshop_import',{p_data:data,p_request_id:randomUUID()});
  assert.equal(s.data.auftraege.length,4);
  assert.equal(s.data.auftraege[0].kundeId,1);
  assert.equal(s.data.auftraege[0].zeiterfassung[0].notiz,'Bestandszeit');
  assert.equal(s.data.auftraege[0].zeiterfassung[0].mechanikerName,'Pascal Runser');
  assert.ok(s.serverTime);
});

test('Fahrzeugwechsel pausiert und startet serverseitig zum selben Zeitpunkt',async()=>{
  await time('start',1);
  const s=await time('start',2);
  const old=s.data.auftraege.find(a=>a.id===1),active=s.data.auftraege.find(a=>a.id===2);
  assert.equal(old.zeiterfassung.at(-1).stop,active.zeiterfassung.at(-1).start);
  assert.equal(old.zeitPause.grund,'Fahrzeug gewechselt');
  assert.equal(running(s).filter(t=>t.mechanikerName==='Pascal Runser').length,1);
});

test('Wiederholung nach unsicherer Verbindung fuehrt denselben Befehl nur einmal aus',async()=>{
  const args={p_action:'start',p_order_id:1,p_mechanic_name:'Pascal Runser',p_request_id:randomUUID()};
  await rpc('ah_workshop_time',args);
  await time('start',2);
  const s=await rpc('ah_workshop_time',args);
  assert.equal(running(s).find(t=>t.mechanikerName==='Pascal Runser').order,2);
  await assert.rejects(rpc('ah_workshop_time',{...args,p_order_id:2}),/AH_REQUEST_REUSED/);
});

test('Gleichzeitige Anfragen zweier Geraete erzeugen keine zweite laufende Uhr',async()=>{
  await Promise.all([time('start',1),time('start',2),time('start',3,'Ruben Costa')]);
  const s=await rpc('ah_workshop_snapshot');
  assert.equal(running(s).filter(t=>t.mechanikerName==='Pascal Runser').length,1);
  assert.equal(running(s).filter(t=>t.mechanikerName==='Ruben Costa').length,1);
});

test('Servervorbehalt fuer neue IDs verhindert Kollisionen zweier Geraete',async()=>{
  const [a,b]=await Promise.all([rpc('ah_workshop_reserve_ids',{p_request_id:randomUUID()}),rpc('ah_workshop_reserve_ids',{p_request_id:randomUUID()})]);
  for(const key of ['k','f','a','m']) assert.ok(a[key].end<b[key].next||b[key].end<a[key].next);
});

test('Unabhaengige Feldaenderungen werden zusammengefuehrt; Konflikte bleiben sichtbar',async()=>{
  const base=(await rpc('ah_workshop_snapshot')).data.auftraege[0];
  const patch=after=>rpc('ah_workshop_patch',{p_request_id:randomUUID(),p_operations:[{kind:'auftraege',id:base.id,before:base,after}]});
  await patch({...base,notizen:'Telefon mit Kunde',updatedAt:'2026-11-09T09:00:00Z'});
  await patch({...base,abholung:'17:00',updatedAt:'2026-11-09T09:01:00Z'});
  let s=await rpc('ah_workshop_snapshot');
  assert.equal(s.data.auftraege[0].notizen,'Telefon mit Kunde');
  assert.equal(s.data.auftraege[0].abholung,'17:00');
  await assert.rejects(patch({...base,notizen:'Anderer Text'}),/AH_CONFLICT/);
  s=await rpc('ah_workshop_snapshot');
  assert.equal(s.data.auftraege[0].notizen,'Telefon mit Kunde');
});

test('Ein Geraete-Snapshot kann serverseitige Stempelzeiten nicht ueberschreiben',async()=>{
  let s=await time('start',1);
  const before=s.data.auftraege[0];
  s=await rpc('ah_workshop_patch',{p_request_id:randomUUID(),p_operations:[{kind:'auftraege',id:1,before,after:{...before,zeiterfassung:[],zeitPause:{start:new Date().toISOString(),grund:'Falsch'}}}]});
  assert.equal(running(s).filter(t=>t.order===1).length,1);
});

test('Eine Garage kann weder den Bestand noch die Zeiten einer anderen Garage lesen',async()=>{
  assert.equal(await rpc('ah_workshop_snapshot',{},users.other),null);
  const rows=await database.authenticated(users.other,async tx=>(await tx.query('select * from public.ah_workshops')).rows);
  assert.equal(rows.length,0);
  const sessions=await database.authenticated(users.other,async tx=>(await tx.query('select * from public.ah_workshop_sessions')).rows);
  assert.equal(sessions.length,0);
});

test('Mechaniker duerfen nur ihre eigenen Auftraege stempeln und keine Personen einschleusen',async()=>{
  await assert.rejects(time('start',3,'Pascal Runser',{},users.pascal),/AH_OWN_ORDER_REQUIRED/);
  const s=await time('start',1,'Ruben Costa',{},users.pascal);
  assert.equal(running(s).find(t=>t.order===1).mechanikerName,'Pascal Runser');
  await assert.rejects(rpc('ah_workshop_import',{p_data:seedWorkshop(),p_request_id:randomUUID()},users.pascal),/AH_ADMIN_REQUIRED/);
  await assert.rejects(database.authenticated(users.pascal,tx=>tx.query("update public.ah_workshop_sessions set stopped_at=null")),/permission denied/);
});

test('Abschluss stoppt die Uhr atomar; alte Befehle starten keinen erledigten Auftrag',async()=>{
  const before=(await time('start',2)).data.auftraege.find(a=>a.id===2);
  const s=await rpc('ah_workshop_patch',{p_request_id:randomUUID(),p_operations:[{kind:'auftraege',id:2,before,after:{...before,status:'erledigt'}}]});
  assert.equal(running(s).some(t=>t.order===2),false);
  assert.equal(s.data.auftraege.find(a=>a.id===2).zeitPause,undefined);
  await assert.rejects(time('start',2),/AH_ORDER_CLOSED/);
});

test('Datenbankindex verhindert eine zweite Uhr auch bei direktem administrativem SQL',async()=>{
  await time('start',3,'Ruben Costa');
  await assert.rejects(database.db.query(`insert into public.ah_workshop_sessions(garage_id,order_id,mechanic_key,mechanic_name,started_at,actor_id)
    select garage_id,99999,mechanic_key,mechanic_name,clock_timestamp(),actor_id from public.ah_workshop_sessions where stopped_at is null and voided_at is null limit 1`),/duplicate key value/);
});

test('Unklar bestaetigte Befehle lassen sich ohne erneute Ausfuehrung pruefen',async()=>{
  const id=randomUUID();
  assert.equal((await rpc('ah_workshop_command_status',{p_request_id:id})).applied,false);
  await rpc('ah_workshop_time',{p_action:'pause',p_order_id:3,p_mechanic_name:'Ruben Costa',p_request_id:id});
  const status=await rpc('ah_workshop_command_status',{p_request_id:id});
  assert.equal(status.applied,true);
  assert.equal(running(status.snapshot).some(t=>t.order===3),false);
  await assert.rejects(rpc('ah_workshop_reserve_ids',{p_request_id:id}),/AH_REQUEST_REUSED/);
});

test('Erneuter Import ersetzt keinen bereits vorhandenen gemeinsamen Bestand',async()=>{
  const s=await rpc('ah_workshop_snapshot');
  const after=await rpc('ah_workshop_import',{p_data:{kunden:[],fahrzeuge:[],auftraege:[],mitarbeiter:[]},p_request_id:randomUUID()});
  assert.deepEqual(after.data,s.data);
});

test('Eine Eigenprofil-Aenderung kann keine fremde Garage oder Rolle freischalten',async()=>{
  await assert.rejects(database.authenticated(users.pascal,tx=>tx.query("update public.profile set rolle='admin' where id=$1",[users.pascal])),/AH_PROFILE_ADMIN_REQUIRED/);
  await assert.rejects(database.authenticated(users.pascal,tx=>tx.query("update public.profile set vorname='Ruben',nachname='Costa' where id=$1",[users.pascal])),/AH_PROFILE_ADMIN_REQUIRED/);
  await assert.rejects(database.authenticated(users.pascal,tx=>tx.query("update public.profile set garage_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' where id=$1",[users.pascal])),/AH_PROFILE_ADMIN_REQUIRED/);
});

test('Realtime-Nachrichten enthalten nur eine geschuetzte Revisionsnummer',async()=>{
  const snapshot=await rpc('ah_workshop_snapshot');
  const rows=await database.authenticated(users.admin,async tx=>(await tx.query('select * from public.ah_workshop_revisions')).rows);
  assert.equal(rows.length,1);
  assert.equal(Number(rows[0].revision),snapshot.revision);
  assert.deepEqual(Object.keys(rows[0]).sort(),['garage_id','revision']);
  const other=await database.authenticated(users.other,async tx=>(await tx.query('select * from public.ah_workshop_revisions')).rows);
  assert.equal(other.length,0);
});
