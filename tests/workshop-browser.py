"""Zwei isolierte Browser sprechen ueber RPC mit denselben PostgreSQL-Funktionen.
Ausfuehren: python3 tests/workshop-browser.py (Playwright + Chromium erforderlich).
"""
import json,subprocess,urllib.request,os,shutil
from pathlib import Path
from playwright.sync_api import sync_playwright

root=Path(__file__).resolve().parents[1]
artifacts=Path(os.environ.get('TEST_ARTIFACT_DIR',str(root/'test-results')))
artifacts.mkdir(parents=True,exist_ok=True)
server=subprocess.Popen(['node','tests/support/workshop-server.mjs'],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
contexts=[];errors=[];results=[]
try:
    line=server.stdout.readline()
    if not line: raise RuntimeError(server.stderr.read())
    base='http://127.0.0.1:'+str(json.loads(line)['port'])
    fixture=json.load(urllib.request.urlopen(base+'/__test/seed'))
    with sync_playwright() as p:
        browser=p.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH') or shutil.which('chromium'),headless=True,args=['--no-sandbox'])
        def open_page(user,legacy=False,width=1440):
            context=browser.new_context(viewport={'width':width,'height':1000},timezone_id='Europe/Zurich')
            contexts.append(context)
            init="sessionStorage.setItem('test-user',"+json.dumps(fixture['users'][user])+");"
            if legacy:
                source={**fixture['data'],'rechnungen':[],'verbrauchsmaterial':[]}
                init+="if(!localStorage.getItem('autohelfer_v4')){localStorage.setItem('autohelfer_v4',JSON.stringify("+json.dumps(source)+"));localStorage.setItem('ah_mitarbeiter',JSON.stringify("+json.dumps(fixture['data']['mitarbeiter'])+"));}"
            context.add_init_script(init)
            def route(request):
                url=request.request.url
                if url.startswith(base): request.continue_()
                elif url.startswith('https://cdn.jsdelivr.net/npm/@supabase/'):
                    request.fulfill(status=200,content_type='text/javascript',body=urllib.request.urlopen(base+'/__test/sdk.js').read().decode())
                else: request.fulfill(status=200,body='',content_type='text/css')
            context.route('**/*',route)
            page=context.new_page();page.set_default_timeout(7000)
            page.on('pageerror',lambda error:errors.append(str(error)))
            page.goto(base,wait_until='load')
            return page,context
        admin,admin_context=open_page('admin',legacy=True)
        admin.get_by_role('button',name='Daten dieses Geräts übernehmen',exact=True).click()
        admin.wait_for_function("AH_SYNC.phase==='ready' && !!AH_SYNC.channel")
        assert admin.locator('.wl-mechanic').count()==3
        legacy_backup=admin.evaluate("localStorage.getItem('autohelfer_v4')")
        mechanic,mechanic_context=open_page('pascal',width=390)
        mechanic.wait_for_function("AH_SYNC.phase==='ready' && !!AH_SYNC.channel")
        assert mechanic.locator('.mech-card').count()==2
        assert admin.evaluate('db.auftraege.length')==mechanic.evaluate('db.auftraege.length')==4
        results.append('Erstimport und neuer Browser laden denselben Bestand; alter lokaler Bestand bleibt erhalten')

        mechanic.locator('[data-work-action="work"][data-work-id="1"]').click()
        admin.wait_for_function('mechHatLaufendeSession(db.auftraege.find(a=>a.id===1))')
        assert admin.locator('[data-wl-job="1"] .wl-clock').is_visible()
        mechanic.evaluate('mfsClose()')
        mechanic.locator('[data-work-action="work"][data-work-id="2"]').click()
        admin.wait_for_function('mechIstPausiert(db.auftraege.find(a=>a.id===1)) && mechHatLaufendeSession(db.auftraege.find(a=>a.id===2))')
        assert admin.evaluate('db.auftraege[0].zeiterfassung.at(-1).stop===db.auftraege[1].zeiterfassung.at(-1).start')
        assert admin.locator('[data-wl-job="1"] .wl-reason').inner_text()=='Fahrzeug gewechselt'
        results.append('Stempelung und Fahrzeugwechsel am Mechaniker-Geraet erscheinen ohne Neuladen im Chef-Dashboard')

        mechanic.locator('.mfs-btn-stop').click()
        admin.wait_for_function('mechIstPausiert(db.auftraege.find(a=>a.id===2))')
        mechanic.locator('#mfs-pause-grund').select_option('Warten auf Ersatzteil')
        admin.wait_for_function('db.auftraege[1].zeitPause.grund==="Warten auf Ersatzteil"')
        results.append('Pausen und Pausengruende erscheinen auf beiden Geraeten')

        first=admin.evaluate('''async()=>{await mechStarteArbeit(3);return true;}''')
        assert first
        mechanic.evaluate('mfsClose()')
        # Zwei unabhaengige HTTP-Anfragen werden gleichzeitig abgegeben.
        admin.evaluate('window.parallelStart=mechStarteArbeit(1)')
        mechanic.evaluate('window.parallelStart=mechStarteArbeit(2)')
        admin.evaluate('async()=>await window.parallelStart')
        mechanic.evaluate('async()=>await window.parallelStart')
        admin.evaluate('async()=>await ahSyncRefresh()')
        mechanic.evaluate('async()=>await ahSyncRefresh()')
        assert admin.evaluate("db.auftraege.flatMap(a=>a.zeiterfassung).filter(s=>!s.stop&&s.mechanikerName==='Pascal Runser').length")==1
        assert mechanic.evaluate("db.auftraege.flatMap(a=>a.zeiterfassung).filter(s=>!s.stop&&s.mechanikerName==='Pascal Runser').length")==1
        assert admin.evaluate('mechHatLaufendeSession(db.auftraege.find(a=>a.id===3))')
        results.append('Gleichzeitige Fahrzeugauswahl bleibt auf eine Uhr begrenzt; anderer Mechaniker laeuft weiter')

        # Allgemeine Auftragsaenderungen benutzen dieselbe gemeinsame Datenbasis.
        admin.evaluate("db.auftraege[0].notizen='Kunde ruft um 15 Uhr an';saveDb();")
        admin.evaluate('async()=>await ahSyncFlush()')
        mechanic.wait_for_function("db.auftraege[0].notizen==='Kunde ruft um 15 Uhr an'")
        assert admin.evaluate("localStorage.getItem('autohelfer_v4')")==legacy_backup
        mechanic.reload(wait_until='load')
        mechanic.wait_for_function("AH_SYNC.phase==='ready' && !!AH_SYNC.channel")
        assert mechanic.evaluate("db.auftraege[0].notizen")== 'Kunde ruft um 15 Uhr an'
        results.append('Auftragsaenderungen werden geteilt und ueberstehen einen Neustart')

        # Offline wird kein scheinbar erfolgreicher lokaler Stempelwechsel erzeugt.
        before=mechanic.evaluate('JSON.stringify(db.auftraege.map(a=>a.zeiterfassung))')
        mechanic_context.set_offline(True)
        assert mechanic.evaluate('async()=>await mechStarteArbeit(1)') is False
        assert mechanic.evaluate('JSON.stringify(db.auftraege.map(a=>a.zeiterfassung))')==before
        mechanic_context.set_offline(False)
        mechanic.evaluate('async()=>await ahSyncRetry()')
        results.append('Offline bleibt die letzte bestaetigte Stempelung unveraendert')

        second_admin,second_context=open_page('admin')
        second_admin.wait_for_function("AH_SYNC.phase==='ready' && !!AH_SYNC.channel")
        second_context.set_offline(True)
        second_admin.evaluate("db.auftraege[0].notizen='Offline-Aenderung';saveDb();")
        second_admin.evaluate('async()=>{try{await ahSyncFlush();}catch(e){}}')
        admin.evaluate("db.auftraege[0].notizen='Telefonnotiz Leitung';saveDb();")
        admin.evaluate('async()=>await ahSyncFlush()')
        second_context.set_offline(False)
        second_admin.evaluate('async()=>await ahSyncRetry()')
        second_admin.wait_for_function('AH_SYNC.conflict===true')
        assert second_admin.evaluate('AH_SYNC.outbox.length')==1
        assert admin.evaluate('db.auftraege[0].notizen')=='Telefonnotiz Leitung'
        # Ein Notizkonflikt darf eine notwendige Pause nicht blockieren.
        assert second_admin.evaluate('async()=>await mechPausiereArbeit(3)') is True
        admin.wait_for_function('mechIstPausiert(db.auftraege[2])')
        assert second_admin.evaluate('AH_SYNC.conflict') is True
        with second_admin.expect_download():
            second_admin.evaluate('async()=>await ahSyncResolveConflict()')
        assert second_admin.evaluate('AH_SYNC.outbox.length')==0
        assert second_admin.evaluate('db.auftraege[0].notizen')=='Telefonnotiz Leitung'
        assert second_admin.evaluate("async()=>!!(await ahSyncRead(AH_SYNC.conflictArchiveKey))")
        results.append('Parallele widerspruechliche Notizen bleiben gesichert; Pausieren funktioniert trotz Konflikt')

        first_id=admin.evaluate('''async()=>{const id=nextId('a');db.auftraege.push({...structuredClone(db.auftraege[0]),id,status:'geplant',beschreibung:'Neuer Auftrag A',zeiterfassung:[],zeitPause:null});saveDb();await ahSyncFlush();return id;}''')
        second_id=second_admin.evaluate('''async()=>{const id=nextId('a');db.auftraege.push({...structuredClone(db.auftraege[0]),id,status:'geplant',beschreibung:'Neuer Auftrag B',zeiterfassung:[],zeitPause:null});saveDb();await ahSyncFlush();return id;}''')
        assert first_id!=second_id
        admin.wait_for_function('db.auftraege.length===6')
        mechanic.wait_for_function('db.auftraege.length===6')
        second_context.set_offline(True)
        second_admin.evaluate("db.auftraege[1].mechNotizen='Nach Neustart noch offen';saveDb();")
        second_admin.evaluate('async()=>{try{await ahSyncFlush();}catch(e){}}')
        second_context.set_offline(False)
        second_admin.reload(wait_until='load')
        second_admin.wait_for_function("AH_SYNC.phase==='ready' && AH_SYNC.outbox.length===0")
        admin.wait_for_function("db.auftraege[1].mechNotizen==='Nach Neustart noch offen'")
        results.append('Nummern bleiben auf getrennten Geraeten eindeutig; ausstehende Aenderungen ueberstehen einen Neustart')

        # Noch lokale Module duerfen durch die neue gemeinsame Ablage nichts verlieren.
        admin.evaluate("db.rechnungen.push({id:1,notizen:'Lokale Rechnung bleibt erhalten'});db.testLargeAttachment='A'.repeat(6*1024*1024);saveDb();")
        admin.evaluate('async()=>await AH_SYNC.persist')
        assert admin.evaluate("async()=>((await ahSyncRead(ahSyncCacheKey())).app.testLargeAttachment.length)")==6*1024*1024
        admin.reload(wait_until='load')
        admin.wait_for_function("AH_SYNC.phase==='ready' && !!AH_SYNC.channel")
        assert admin.evaluate('db.rechnungen[0].notizen')=='Lokale Rechnung bleibt erhalten'
        assert admin.evaluate('db.testLargeAttachment.length')==6*1024*1024
        results.append('Auch lokale Zusatzdaten und ein Bestand ueber dem localStorage-Limit bleiben nach Neuladen erhalten')

        foreign,_=open_page('other')
        foreign.get_by_role('button',name='Mit leerem gemeinsamen Bestand starten',exact=True).click()
        foreign.wait_for_function("AH_SYNC.phase==='ready'")
        assert foreign.evaluate('db.auftraege.length')==0
        assert foreign.evaluate('db.kunden.length')==0
        results.append('Ein Benutzer einer anderen Garage bekommt keine fremden Auftraege oder Kunden')

        admin.locator('#dash-werkstatt-wrap').screenshot(path=str(artifacts/'werkstatt-zwei-geraete.png'))
        mechanic.evaluate('async()=>await doLogout()')
        assert mechanic.evaluate('db.auftraege.length')==0
        assert mechanic.locator('#login-screen').is_visible()
        results.append('Abmelden trennt Realtime und entfernt den geladenen Garagenbestand aus der Ansicht')
        assert not errors,errors
        browser.close()
finally:
    server.terminate()
    try:server.wait(timeout=10)
    except subprocess.TimeoutExpired:server.kill()
print(json.dumps({'passed':results,'browser_errors':errors},ensure_ascii=False,indent=2))
