-- Zeitpunkte erst nach der Geraete-Sperre bestimmen: auch wartende Anfragen
-- stoppen die alte und starten die neue Session zum gleichen Zeitpunkt.
begin;
create or replace function public.ah_workshop_import(p_data jsonb,p_request_id uuid) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; a jsonb; s jsonb; m jsonb; kind text;
  t timestamptz; running boolean; st timestamptz; sp timestamptz; highest bigint;
begin
  if not (c->>'admin')::boolean then raise exception 'AH_ADMIN_REQUIRED' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  t:=clock_timestamp();
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

create or replace function public.ah_workshop_patch(p_operations jsonb,p_request_id uuid) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; op jsonb; kind text; old jsonb; desired jsonb; current jsonb;
  merged jsonb; field text; pos integer; oid bigint; t timestamptz;
begin
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  t:=clock_timestamp();
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

create or replace function public.ah_workshop_time(p_action text,p_order_id bigint,p_request_id uuid,p_mechanic_name text default null,p_reason text default null,p_minutes integer default null,p_session_id uuid default null) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public as $$
declare c jsonb:=public._ah_context(); g text:=c->>'garage'; d jsonb; a jsonb; m jsonb; pos integer; other record;
  active public.ah_workshop_sessions; t timestamptz; args jsonb;
begin
  args:=jsonb_build_object('action',p_action,'order',p_order_id,'name',p_mechanic_name,'reason',p_reason,'minutes',p_minutes,'session',p_session_id);
  perform pg_advisory_xact_lock(hashtextextended(g,0));
  t:=clock_timestamp();
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
notify pgrst, 'reload schema';
commit;
