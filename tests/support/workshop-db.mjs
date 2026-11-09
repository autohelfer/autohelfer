import { PGlite } from '@electric-sql/pglite';
import { readFile,readdir } from 'node:fs/promises';

export const users = {
  admin:'11111111-1111-4111-8111-111111111111',
  pascal:'22222222-2222-4222-8222-222222222222',
  ruben:'33333333-3333-4333-8333-333333333333',
  other:'44444444-4444-4444-8444-444444444444',
};
export const garages = { own:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', other:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' };
const signatures = {
  ah_workshop_snapshot:{},
  ah_workshop_command_status:{p_request_id:'uuid'},
  ah_workshop_import:{p_data:'jsonb',p_request_id:'uuid'},
  ah_workshop_reserve_ids:{p_request_id:'uuid',p_size:'integer'},
  ah_workshop_patch:{p_operations:'jsonb',p_request_id:'uuid'},
  ah_workshop_time:{p_action:'text',p_order_id:'bigint',p_request_id:'uuid',p_mechanic_name:'text',p_reason:'text',p_minutes:'integer',p_session_id:'uuid'},
};

export function seedWorkshop() {
  const employees=[{id:1,vorname:'Pascal',nachname:'Runser'},{id:2,vorname:'Ruben',nachname:'Costa'},{id:3,vorname:'Ammar',nachname:'Demir'}];
  return {
    kunden:[{id:1,vorname:'Sandra',nachname:'Meier',firma:'',kundenArt:'privat',telefon:'',mobile:'',email:''}],
    fahrzeuge:['VW Golf','Audi A3','Peugeot Boxer','Škoda Octavia'].map((name,i)=>({id:i+1,kundeId:1,marke:name.split(' ')[0],modell:name.split(' ').slice(1).join(' '),kennzeichen:'BL'+(123450+i),status:'aktiv'})),
    auftraege:[1,2,3,4].map(id=>({id,kundeId:1,fahrzeugId:id,datum:new Date().toLocaleDateString('sv-SE',{timeZone:'Europe/Zurich'}),status:'geplant',mechanikerName:id<3?'Pascal Runser':id===3?'Ruben Costa':'Ammar Demir',beschreibung:['Service','Bremsen vorne','Klimaservice','Diagnose'][id-1],geplantH:2,ankunft:'08:00',abholung:'16:00',positionen:[],material:[],diverses:[],zeiterfassung:[],checkliste:[],mechFotos:[],mechNotizen:'',kosten:0})),
    mitarbeiter:employees,_c:{k:1,f:4,a:4,m:3},
  };
}

export async function workshopDatabase() {
  const db = new PGlite();
  await db.exec(`create role anon;create role authenticated;create schema auth;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create table public.profile(id uuid primary key,garage_id uuid,rolle text,vorname text,nachname text,aktiv boolean default true);
    alter table public.profile enable row level security;
    grant select,update on public.profile to authenticated;
    create policy own_profile_read on public.profile for select to authenticated using(id=auth.uid());
    create policy own_profile_update on public.profile for update to authenticated using(id=auth.uid());
    grant usage on schema auth to authenticated;`);
  await db.query(`insert into public.profile(id,garage_id,rolle,vorname,nachname) values ($1,$5,'admin','Test','Leitung'),($2,$5,'mechaniker','Pascal','Runser'),($3,$5,'mechaniker','Ruben','Costa'),($4,$6,'admin','Andere','Garage')`,[...Object.values(users),garages.own,garages.other]);
  const migrations=new URL('../../supabase/migrations/',import.meta.url);
  for(const file of (await readdir(migrations)).filter(file=>file.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(file,migrations),'utf8'));
  async function authenticated(user,fn) {
    return db.transaction(async tx=>{
      await tx.query("select set_config('request.jwt.claim.sub',$1,true)",[user||'']);
      await tx.exec('set local role authenticated');
      return fn(tx);
    });
  }
  async function rpc(name,args={},user=users.admin) {
    const signature=signatures[name];
    if(!signature) throw new Error('Unknown test RPC');
    const entries=Object.entries(args);
    for(const [key] of entries) if(!signature[key]) throw new Error('Unknown argument: '+key);
    const params=entries.map(([key],i)=>`${key}=>$${i+1}::${signature[key]}`).join(',');
    return authenticated(user,async tx=>(await tx.query(`select public.${name}(${params}) as result`,entries.map(([key,value])=>signature[key]==='jsonb'?JSON.stringify(value):value))).rows[0].result);
  }
  return {db,rpc,authenticated,close:()=>db.close()};
}
