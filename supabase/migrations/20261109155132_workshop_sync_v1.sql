-- Einmalig als Datenbankadministrator im vorhandenen Supabase-Projekt ausfuehren.
-- Voraussetzung: public.profile mit id, garage_id, rolle, vorname, nachname.
-- Keine bestehenden Tabellen oder lokalen Bestandsdaten werden ersetzt.
begin;

create table public.ah_workshops (
  garage_id text primary key,
  revision bigint not null default 0,
  document jsonb not null,
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid not null,
  check (jsonb_typeof(document) = 'object')
);
-- Realtime uebertraegt nur die Revisionsnummer, keine grossen Foto-/Auftragsdaten.
create table public.ah_workshop_revisions (
  garage_id text primary key references public.ah_workshops(garage_id),
  revision bigint not null
);
create function public._ah_publish_revision() returns trigger language plpgsql security definer
set search_path=pg_catalog,public as $$
begin
  insert into public.ah_workshop_revisions(garage_id,revision) values(new.garage_id,new.revision)
    on conflict(garage_id) do update set revision=excluded.revision;
  return new;
end $$;
create trigger ah_publish_revision after insert or update on public.ah_workshops for each row execute function public._ah_publish_revision();
revoke execute on function public._ah_publish_revision() from public,anon,authenticated;
create table public.ah_workshop_sessions (
  id uuid primary key default gen_random_uuid(),
  garage_id text not null references public.ah_workshops(garage_id),
  order_id bigint not null,
  mechanic_key text not null,
  mechanic_id text,
  mechanic_name text not null,
  started_at timestamptz not null,
  stopped_at timestamptz,
  stop_reason text,
  extra jsonb not null default '{}',
  actor_id uuid not null,
  voided_at timestamptz,
  check (stopped_at is null or stopped_at >= started_at)
);
create unique index ah_one_active_job_per_mechanic on public.ah_workshop_sessions(garage_id, mechanic_key)
  where stopped_at is null and voided_at is null;
create unique index ah_one_active_mechanic_per_job on public.ah_workshop_sessions(garage_id, order_id)
  where stopped_at is null and voided_at is null;
create index ah_workshop_session_history on public.ah_workshop_sessions(garage_id, order_id, started_at);
create table public.ah_workshop_requests (
  garage_id text not null references public.ah_workshops(garage_id),
  request_id uuid not null,
  actor_id uuid not null,
  arguments jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key(garage_id, request_id)
);

create function public._ah_context() returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public as $$
declare p jsonb;
begin
  if auth.uid() is null then raise exception 'AH_LOGIN_REQUIRED' using errcode='42501'; end if;
  select to_jsonb(profile) into p from public.profile where id=auth.uid();
  if p is null or nullif(p->>'garage_id','') is null or coalesce((p->>'aktiv')::boolean,true)=false or coalesce(p->>'rolle','') not in ('admin','mechaniker') then
    raise exception 'AH_PROFILE_REQUIRED' using errcode='42501';
  end if;
  return jsonb_build_object('garage',p->>'garage_id','actor',auth.uid(),'admin',p->>'rolle'='admin',
    'name',btrim(coalesce(p->>'vorname','')||' '||coalesce(p->>'nachname','')));
end $$;

-- Die vorhandene Eigenprofil-UPDATE-Regel darf keine fremde Garage, Rolle
-- oder Mechanikeridentitaet freischalten. Verwaltungszugriffe bleiben moeglich.
create function public._ah_protect_profile() returns trigger language plpgsql
set search_path = pg_catalog, public as $$
begin
  if current_setting('role',true) in ('authenticated','anon') and (
    (to_jsonb(new)->'id') is distinct from (to_jsonb(old)->'id') or
    (to_jsonb(new)->'garage_id') is distinct from (to_jsonb(old)->'garage_id') or
    (to_jsonb(new)->'rolle') is distinct from (to_jsonb(old)->'rolle') or
    (to_jsonb(new)->'aktiv') is distinct from (to_jsonb(old)->'aktiv') or
    old.rolle='mechaniker' and (new.vorname is distinct from old.vorname or new.nachname is distinct from old.nachname)) then
    raise exception 'AH_PROFILE_ADMIN_REQUIRED' using errcode='42501';
  end if;
  return new;
end $$;
create trigger ah_protect_profile before update on public.profile for each row execute function public._ah_protect_profile();
revoke execute on function public._ah_protect_profile() from public,anon,authenticated;

create function public._ah_garage() returns text language sql stable security definer
set search_path = pg_catalog, public as $$ select public._ah_context()->>'garage' $$;

alter table public.ah_workshops enable row level security;
alter table public.ah_workshop_revisions enable row level security;
alter table public.ah_workshop_sessions enable row level security;
alter table public.ah_workshop_requests enable row level security;
create policy ah_workshop_read on public.ah_workshops for select to authenticated using (garage_id=public._ah_garage());
create policy ah_revision_read on public.ah_workshop_revisions for select to authenticated using (garage_id=public._ah_garage());
create policy ah_session_read on public.ah_workshop_sessions for select to authenticated using (garage_id=public._ah_garage());
grant select on public.ah_workshops,public.ah_workshop_revisions,public.ah_workshop_sessions to authenticated;

create function public._ah_mechanic(d jsonb, n text) returns jsonb language plpgsql immutable
set search_path = pg_catalog, public as $$
declare m jsonb; clean text:=btrim(regexp_replace(coalesce(n,''),'\s+',' ','g'));
begin
  if clean='' then raise exception 'AH_MECHANIC_REQUIRED'; end if;
  select value into m from jsonb_array_elements(coalesce(d->'mitarbeiter','[]'))
    where lower(btrim(coalesce(value->>'vorname','')||' '||coalesce(value->>'nachname','')))=lower(clean) limit 1;
  return jsonb_build_object('key',case when m->>'id' is not null then 'id:'||(m->>'id') else 'name:'||lower(clean) end,
    'id',m->'id','name',clean);
end $$;

create function public._ah_snapshot(g text) returns jsonb language sql stable security definer
set search_path = pg_catalog, public as $$
  select jsonb_build_object('revision',w.revision,'serverTime',clock_timestamp(),'data',jsonb_set(w.document,'{auftraege}',
    coalesce((select jsonb_agg(a.value||jsonb_build_object('zeiterfassung',coalesce((
      select jsonb_agg(s.extra||jsonb_build_object('id',s.id,'start',s.started_at,'stop',s.stopped_at,
        'stopGrund',s.stop_reason,'mechanikerId',s.mechanic_id,'mechanikerName',s.mechanic_name,'garageId',s.garage_id)
        order by s.started_at,s.id) from public.ah_workshop_sessions s
        where s.garage_id=g and s.order_id=(a.value->>'id')::bigint and s.voided_at is null),'[]'))
      order by a.ordinality) from jsonb_array_elements(w.document->'auftraege') with ordinality a(value,ordinality)),'[]')))
  from public.ah_workshops w where w.garage_id=g
$$;

create function public._ah_request(g text,r uuid,args jsonb) returns boolean language plpgsql security definer
set search_path = pg_catalog, public as $$
declare previous public.ah_workshop_requests;
begin
  if r is null then raise exception 'AH_REQUEST_ID_REQUIRED'; end if;
  select * into previous from public.ah_workshop_requests where garage_id=g and request_id=r;
  if found then
    if previous.actor_id<>auth.uid() or previous.arguments<>args then raise exception 'AH_REQUEST_REUSED'; end if;
    return true;
  end if;
  insert into public.ah_workshop_requests(garage_id,request_id,actor_id,arguments) values(g,r,auth.uid(),args);
  return false;
end $$;

create function public._ah_pause_order(d jsonb,g text,oid bigint,t timestamptz,reason text) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare item record; person record; n integer;
begin
  select * into person from public.ah_workshop_sessions where garage_id=g and order_id=oid and stopped_at is null and voided_at is null limit 1;
  update public.ah_workshop_sessions set stopped_at=greatest(t,started_at),stop_reason=reason
    where garage_id=g and order_id=oid and stopped_at is null and voided_at is null;
  get diagnostics n=row_count;
  if n>0 then
    for item in select value,ordinality from jsonb_array_elements(d->'auftraege') with ordinality loop
      if (item.value->>'id')::bigint=oid then
        d:=jsonb_set(d,array['auftraege',(item.ordinality-1)::text],item.value||jsonb_build_object('updatedAt',t,'zeitPause',
          jsonb_build_object('start',t,'grund',reason,'mechanikerId',person.mechanic_id,'mechanikerName',person.mechanic_name)));
        exit;
      end if;
    end loop;
  end if;
  return d;
end $$;

create function public.ah_workshop_snapshot() returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public as $$
begin return public._ah_snapshot(public._ah_context()->>'garage'); end $$;

create function public.ah_workshop_command_status(p_request_id uuid) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare g text:=public._ah_context()->>'garage';
begin
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  return jsonb_build_object('applied',exists(select 1 from public.ah_workshop_requests where garage_id=g and request_id=p_request_id and actor_id=auth.uid()),'snapshot',public._ah_snapshot(g));
end $$;

create function public.ah_workshop_import(p_data jsonb,p_request_id uuid) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; a jsonb; s jsonb; m jsonb; kind text;
  t timestamptz:=clock_timestamp(); running boolean; st timestamptz; sp timestamptz; highest bigint;
begin
  if not (c->>'admin')::boolean then raise exception 'AH_ADMIN_REQUIRED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  if exists(select 1 from public.ah_workshops where garage_id=g) then return public._ah_snapshot(g); end if;
  d:=jsonb_build_object('kunden','[]'::jsonb,'fahrzeuge','[]'::jsonb,'auftraege','[]'::jsonb,'mitarbeiter','[]'::jsonb,'_c','{}'::jsonb);
  foreach kind in array array['kunden','fahrzeuge','auftraege','mitarbeiter'] loop
    if jsonb_typeof(p_data->kind) is distinct from 'array' then raise exception 'AH_INVALID_IMPORT: %',kind; end if;
    if exists(select 1 from jsonb_array_elements(p_data->kind) x where jsonb_typeof(x)<>'object' or coalesce(x->>'id','')!~'^[1-9][0-9]*$') or
       exists(select 1 from jsonb_array_elements(p_data->kind) x group by x->>'id' having count(*)>1) then raise exception 'AH_DUPLICATE_IMPORT_ID: %',kind; end if;
    d:=jsonb_set(d,array[kind],p_data->kind);
  end loop;
  insert into public.ah_workshops(garage_id,document,updated_by) values(g,d,auth.uid());
  perform public._ah_request(g,p_request_id,jsonb_build_object('action','import'));
  -- Legacy-Sessions bleiben erhalten. Von parallelen offenen Uhren wird nur die
  -- zuletzt gestartete uebernommen; die anderen enden zum Importzeitpunkt.
  for a in select value from jsonb_array_elements(d->'auftraege') loop
    for s in select value from jsonb_array_elements(coalesce(a->'zeiterfassung','[]')) order by value->>'start' loop
      st:=(s->>'start')::timestamptz; sp:=(s->>'stop')::timestamptz;
      if st is null or st>t or (sp is not null and sp<st) then raise exception 'AH_INVALID_SESSION: %',a->>'id'; end if;
      m:=public._ah_mechanic(d,coalesce(nullif(s->>'mechanikerName',''),nullif(a->>'mechanikerName',''),a->>'internMech'));
      running:=sp is null and not coalesce((a->>'geloescht')::boolean,false) and a->>'status' in ('offen','geplant','in_arbeit');
      if sp is null and not running then sp:=t; end if;
      if running then
        if exists(select 1 from public.ah_workshop_sessions where garage_id=g and mechanic_key=m->>'key' and stopped_at is null) then
          -- Die neuere Session gewinnt, auch wenn Auftraege anders sortiert sind.
          if exists(select 1 from public.ah_workshop_sessions where garage_id=g and mechanic_key=m->>'key' and stopped_at is null and started_at>st) then
            sp:=t; running:=false;
            d:=jsonb_set(d,array['auftraege',((select ordinality-1 from jsonb_array_elements(d->'auftraege') with ordinality where (value->>'id')::bigint=(a->>'id')::bigint))::text,'zeitPause'],jsonb_build_object('start',t,'grund','Parallele Stempelung beim Import beendet','mechanikerName',m->>'name'));
          else
            d:=public._ah_pause_order(d,g,(select order_id from public.ah_workshop_sessions where garage_id=g and mechanic_key=m->>'key' and stopped_at is null),t,'Parallele Stempelung beim Import beendet');
          end if;
        end if;
        if running then d:=public._ah_pause_order(d,g,(a->>'id')::bigint,t,'Doppelte Stempelung beim Import beendet'); end if;
      end if;
      insert into public.ah_workshop_sessions(garage_id,order_id,mechanic_key,mechanic_id,mechanic_name,started_at,stopped_at,stop_reason,extra,actor_id)
        values(g,(a->>'id')::bigint,m->>'key',m->>'id',m->>'name',st,sp,s->>'stopGrund',s-array['start','stop','id','mechanikerId','mechanikerName','garageId','stopGrund'],auth.uid());
    end loop;
  end loop;
  -- Zeiterfassung wird ausschliesslich aus der Session-Tabelle gelesen.
  d:=jsonb_set(d,'{auftraege}',coalesce((select jsonb_agg(value-'zeiterfassung') from jsonb_array_elements(d->'auftraege')),'[]'));
  foreach kind in array array['kunden','fahrzeuge','auftraege','mitarbeiter'] loop
    select coalesce(max((value->>'id')::bigint),0) into highest from jsonb_array_elements(d->kind);
    d:=jsonb_set(d,array['_c',case kind when 'kunden' then 'k' when 'fahrzeuge' then 'f' when 'auftraege' then 'a' else 'm' end],to_jsonb(highest));
  end loop;
  update public.ah_workshops set document=d,revision=1 where garage_id=g;
  return public._ah_snapshot(g);
end $$;

create function public.ah_workshop_reserve_ids(p_request_id uuid,p_size integer default 16) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; k text; n bigint; blocks jsonb:='{}'; old jsonb;
begin
  if p_size<1 or p_size>128 then raise exception 'AH_INVALID_RESERVATION'; end if;
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  select document into d from public.ah_workshops where garage_id=g for update;
  if d is null then raise exception 'AH_IMPORT_REQUIRED'; end if;
  select arguments into old from public.ah_workshop_requests where garage_id=g and request_id=p_request_id and actor_id=auth.uid();
  if found then
    if old->>'action'<>'reserve' or (old->>'size')::integer<>p_size then raise exception 'AH_REQUEST_REUSED'; end if;
    return old->'blocks';
  end if;
  foreach k in array array['k','f','a','m'] loop
    n:=coalesce((d->'_c'->>k)::bigint,0);
    blocks:=blocks||jsonb_build_object(k,jsonb_build_object('next',n+1,'end',n+p_size));
    d:=jsonb_set(d,array['_c',k],to_jsonb(n+p_size));
  end loop;
  perform public._ah_request(g,p_request_id,jsonb_build_object('action','reserve','size',p_size,'blocks',blocks));
  update public.ah_workshops set document=d,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid() where garage_id=g;
  return blocks;
end $$;

-- Drei-Wege-Abgleich je Feld: unabhaengige Aenderungen werden zusammengefuehrt,
-- konkurrierende Aenderungen am selben Feld werden niemals still ueberschrieben.
create function public.ah_workshop_patch(p_operations jsonb,p_request_id uuid) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; op jsonb; kind text; old jsonb; desired jsonb; current jsonb;
  merged jsonb; field text; pos integer; oid bigint; t timestamptz:=clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  select document into d from public.ah_workshops where garage_id=g for update;
  if d is null then raise exception 'AH_IMPORT_REQUIRED'; end if;
  if public._ah_request(g,p_request_id,jsonb_build_object('action','patch','operations',p_operations)) then return public._ah_snapshot(g); end if;
  if jsonb_typeof(p_operations)<>'array' or jsonb_array_length(p_operations)>200 then raise exception 'AH_INVALID_PATCH'; end if;
  for op in select value from jsonb_array_elements(p_operations) loop
    kind:=op->>'kind'; old:=nullif(op->'before','null'); desired:=nullif(op->'after','null');
    if kind not in ('kunden','fahrzeuge','auftraege','mitarbeiter') or (desired is not null and (desired->>'id')::bigint<> (op->>'id')::bigint) then raise exception 'AH_INVALID_PATCH'; end if;
    select value,ordinality-1 into current,pos from jsonb_array_elements(d->kind) with ordinality where value->>'id'=op->>'id';
    if desired is null then
      if not (c->>'admin')::boolean then raise exception 'AH_ADMIN_REQUIRED' using errcode='42501'; end if;
      if current is null then continue; end if;
      if old is null or current-array['zeiterfassung','zeitPause','updatedAt'] is distinct from old-array['zeiterfassung','zeitPause','updatedAt'] then raise exception 'AH_CONFLICT: %/%',kind,op->>'id'; end if;
      if kind='auftraege' then d:=public._ah_pause_order(d,g,(op->>'id')::bigint,t,'Auftrag gelöscht'); end if;
      d:=jsonb_set(d,array[kind],(d->kind)-pos);
      continue;
    end if;
    if not (c->>'admin')::boolean then
      if kind<>'auftraege' or (current is not null and lower(coalesce(current->>'mechanikerName',''))<>lower(c->>'name')) or lower(coalesce(desired->>'mechanikerName',''))<>lower(c->>'name') then
        raise exception 'AH_ADMIN_REQUIRED' using errcode='42501';
      end if;
    end if;
    old:=old-'updatedAt'; desired:=desired-'updatedAt';
    if kind='auftraege' then old:=old-array['zeiterfassung','zeitPause']; desired:=desired-array['zeiterfassung','zeitPause']; end if;
    if current is null then
      if old is not null then raise exception 'AH_CONFLICT: %/%',kind,op->>'id'; end if;
      if coalesce((d->'_c'->>(case kind when 'kunden' then 'k' when 'fahrzeuge' then 'f' when 'auftraege' then 'a' else 'm' end))::bigint,0)<(op->>'id')::bigint then raise exception 'AH_ID_NOT_RESERVED'; end if;
      d:=jsonb_set(d,array[kind],(d->kind)||jsonb_build_array(desired||jsonb_build_object('updatedAt',t)));
    else
      if old is null then
        if current-array['zeiterfassung','zeitPause','updatedAt']<>desired then raise exception 'AH_CONFLICT: %/%',kind,op->>'id'; end if;
      else
        merged:=current;
        for field in select jsonb_object_keys(old||desired) loop
          if old->field is distinct from desired->field then
            if current->field is distinct from old->field and current->field is distinct from desired->field then raise exception 'AH_CONFLICT: %/%/%',kind,op->>'id',field; end if;
            if desired ? field then merged:=jsonb_set(merged,array[field],desired->field); else merged:=merged-field; end if;
          end if;
        end loop;
        if kind='auftraege' and current->>'mechanikerName' is distinct from merged->>'mechanikerName' then
          d:=public._ah_pause_order(d,g,(op->>'id')::bigint,t,'Auftrag weitergegeben');
          merged:=merged||jsonb_build_object('zeitPause',(d->kind->pos)->'zeitPause');
        end if;
        d:=jsonb_set(d,array[kind,pos::text],merged||jsonb_build_object('updatedAt',t));
      end if;
    end if;
  end loop;
  for current in select value from jsonb_array_elements(d->'auftraege') loop
    if coalesce((current->>'geloescht')::boolean,false) or current->>'status' not in ('offen','geplant','in_arbeit') then
      oid:=(current->>'id')::bigint;
      d:=public._ah_pause_order(d,g,oid,t,'Auftrag abgeschlossen');
      select ordinality-1 into pos from jsonb_array_elements(d->'auftraege') with ordinality where (value->>'id')::bigint=oid;
      d:=jsonb_set(d,array['auftraege',pos::text],(d->'auftraege'->pos)-'zeitPause');
    end if;
  end loop;
  update public.ah_workshops set document=d,revision=revision+1,updated_at=t,updated_by=auth.uid() where garage_id=g;
  return public._ah_snapshot(g);
end $$;

create function public.ah_workshop_time(p_action text,p_order_id bigint,p_request_id uuid,p_mechanic_name text default null,p_reason text default null,p_minutes integer default null,p_session_id uuid default null) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; a jsonb; m jsonb; pos integer; other record;
  active public.ah_workshop_sessions; t timestamptz:=clock_timestamp(); args jsonb;
begin
  args:=jsonb_build_object('action',p_action,'order',p_order_id,'name',p_mechanic_name,'reason',p_reason,'minutes',p_minutes,'session',p_session_id);
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  select document into d from public.ah_workshops where garage_id=g for update;
  if d is null then raise exception 'AH_IMPORT_REQUIRED'; end if;
  if public._ah_request(g,p_request_id,args) then return public._ah_snapshot(g); end if;
  select value,ordinality-1 into a,pos from jsonb_array_elements(d->'auftraege') with ordinality where (value->>'id')::bigint=p_order_id;
  if a is null then raise exception 'AH_ORDER_MISSING'; end if;
  m:=public._ah_mechanic(d,case when (c->>'admin')::boolean then coalesce(nullif(p_mechanic_name,''),a->>'mechanikerName') else c->>'name' end);
  if not (c->>'admin')::boolean and lower(coalesce(a->>'mechanikerName',''))<>lower(c->>'name') then raise exception 'AH_OWN_ORDER_REQUIRED' using errcode='42501'; end if;
  if coalesce((a->>'geloescht')::boolean,false) or a->>'status' not in ('offen','geplant','in_arbeit') then raise exception 'AH_ORDER_CLOSED'; end if;
  select * into active from public.ah_workshop_sessions where garage_id=g and order_id=p_order_id and stopped_at is null and voided_at is null;
  if active.id is not null and active.mechanic_key<>m->>'key' then raise exception 'AH_OTHER_MECHANIC_ACTIVE'; end if;
  if p_action='start' then
    for other in select distinct order_id from public.ah_workshop_sessions where garage_id=g and order_id<>p_order_id and stopped_at is null and voided_at is null and (mechanic_key=m->>'key' or lower(mechanic_name)=lower(m->>'name')) loop
      d:=public._ah_pause_order(d,g,other.order_id,t,'Fahrzeug gewechselt');
    end loop;
    if active.id is null then insert into public.ah_workshop_sessions(garage_id,order_id,mechanic_key,mechanic_id,mechanic_name,started_at,actor_id)
      values(g,p_order_id,m->>'key',m->>'id',m->>'name',t,auth.uid()); end if;
    a:=(a-'zeitPause')||jsonb_build_object('status','in_arbeit','mechanikerName',m->>'name','updatedAt',t);
    d:=jsonb_set(d,array['auftraege',pos::text],a);
  elsif p_action='pause' then d:=public._ah_pause_order(d,g,p_order_id,t,'Manuell pausiert');
  elsif p_action='reason' then
    if active.id is not null or a->'zeitPause' is null or p_reason not in ('Manuell pausiert','Warten auf Ersatzteil','Warten auf Kundenfreigabe','Fahrzeug gewechselt','Auftrag weitergegeben') then raise exception 'AH_INVALID_PAUSE_REASON'; end if;
    d:=jsonb_set(d,array['auftraege',pos::text,'zeitPause','grund'],to_jsonb(p_reason));
  elsif p_action='transfer' then
    perform public._ah_mechanic(d,p_reason);
    d:=public._ah_pause_order(d,g,p_order_id,t,'Auftrag weitergegeben');
    d:=jsonb_set(d,array['auftraege',pos::text,'mechanikerName'],to_jsonb(p_reason));
  elsif p_action='add_time' then
    if p_minutes is null or p_minutes<1 or p_minutes>1440 then raise exception 'AH_INVALID_MINUTES'; end if;
    insert into public.ah_workshop_sessions(garage_id,order_id,mechanic_key,mechanic_id,mechanic_name,started_at,stopped_at,extra,actor_id)
      values(g,p_order_id,m->>'key',m->>'id',m->>'name',t-make_interval(mins=>p_minutes),t,'{"manuell":true,"notiz":"Zusatzzeit"}',auth.uid());
  elsif p_action='void_time' then
    update public.ah_workshop_sessions set voided_at=t,stopped_at=coalesce(stopped_at,greatest(t,started_at)),stop_reason='Zeitbuchung entfernt'
      where id=p_session_id and garage_id=g and order_id=p_order_id and ((c->>'admin')::boolean or mechanic_key=m->>'key');
    if not found then raise exception 'AH_SESSION_MISSING'; end if;
  else raise exception 'AH_INVALID_ACTION'; end if;
  update public.ah_workshops set document=d,revision=revision+1,updated_at=t,updated_by=auth.uid() where garage_id=g;
  return public._ah_snapshot(g);
end $$;

-- Nur kontrollierte RPCs koennen schreiben. Ein Browser erhaelt
-- niemals einen service_role- oder Datenbankadministratorschluessel.
revoke all on public.ah_workshops,public.ah_workshop_sessions,public.ah_workshop_requests from anon;
revoke all on public.ah_workshop_revisions from anon;
revoke insert,update,delete,truncate on public.ah_workshops,public.ah_workshop_sessions,public.ah_workshop_requests from authenticated;
revoke insert,update,delete,truncate on public.ah_workshop_revisions from authenticated;
revoke execute on function public._ah_context(),public._ah_garage(),public._ah_mechanic(jsonb,text),public._ah_snapshot(text),public._ah_request(text,uuid,jsonb),public._ah_pause_order(jsonb,text,bigint,timestamptz,text) from public,anon,authenticated;
grant execute on function public._ah_garage() to authenticated;
revoke execute on function public.ah_workshop_snapshot(),public.ah_workshop_command_status(uuid),public.ah_workshop_import(jsonb,uuid),public.ah_workshop_reserve_ids(uuid,integer),public.ah_workshop_patch(jsonb,uuid),public.ah_workshop_time(text,bigint,uuid,text,text,integer,uuid) from public,anon;
grant execute on function public.ah_workshop_snapshot(),public.ah_workshop_command_status(uuid),public.ah_workshop_import(jsonb,uuid),public.ah_workshop_reserve_ids(uuid,integer),public.ah_workshop_patch(jsonb,uuid),public.ah_workshop_time(text,bigint,uuid,text,text,integer,uuid) to authenticated;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(
    select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='ah_workshop_revisions') then
    alter publication supabase_realtime add table public.ah_workshop_revisions;
  end if;
end $$;
notify pgrst, 'reload schema';
commit;
