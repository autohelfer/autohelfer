// Lokaler Integrationstest: echte PostgreSQL-Funktionen, simulierte Auth-/Realtime-Transportschicht.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {workshopDatabase,seedWorkshop,users,garages} from './workshop-db.mjs';

const database=await workshopDatabase();
const events=new Set();
const profiles={
  [users.admin]:{id:users.admin,garage_id:garages.own,rolle:'admin',vorname:'Test',nachname:'Leitung'},
  [users.pascal]:{id:users.pascal,garage_id:garages.own,rolle:'mechaniker',vorname:'Pascal',nachname:'Runser'},
  [users.ruben]:{id:users.ruben,garage_id:garages.own,rolle:'mechaniker',vorname:'Ruben',nachname:'Costa'},
  [users.other]:{id:users.other,garage_id:garages.other,rolle:'admin',vorname:'Andere',nachname:'Garage'},
};
const sdk=`
const testProfiles=${JSON.stringify(profiles)};
window.supabase={createClient:()=>({
  auth:{getSession:async()=>({data:{session:{user:{id:sessionStorage.getItem('test-user')}}}}),signOut:async()=>{}},
  from:table=>({select(){return this;},eq(){return this;},single:async()=>({data:table==='profile'?testProfiles[sessionStorage.getItem('test-user')]:{id:testProfiles[sessionStorage.getItem('test-user')].garage_id,name:'Testgarage'},error:null})}),
  rpc:async(name,args={})=>{const response=await fetch('/__test/rpc',{method:'POST',headers:{'content-type':'application/json','x-test-user':sessionStorage.getItem('test-user')},body:JSON.stringify({name,args})});return response.json();},
  channel:()=>{const channel={callback:null,eventSource:null,on(event,filter,callback){this.callback=callback;return this;},subscribe(callback){this.eventSource=new EventSource('/__test/events');this.eventSource.onmessage=()=>this.callback?.({});setTimeout(()=>callback?.('SUBSCRIBED'),0);return this;}};return channel;},
  removeChannel:async channel=>channel.eventSource?.close()
})};`;

const server=http.createServer(async(request,response)=>{
  try {
    const url=new URL(request.url,'http://localhost');
    if(url.pathname==='/__test/events') {
      response.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-cache','connection':'keep-alive'});
      response.write(': ready\n\n');events.add(response);request.on('close',()=>events.delete(response));return;
    }
    if(url.pathname==='/__test/sdk.js') {response.writeHead(200,{'content-type':'text/javascript'});response.end(sdk);return;}
    if(url.pathname==='/__test/seed') {response.writeHead(200,{'content-type':'application/json'});response.end(JSON.stringify({data:seedWorkshop(),users}));return;}
    if(url.pathname==='/__test/rpc') {
      const user=request.headers['x-test-user'];
      if(!profiles[user]) {response.writeHead(401,{'content-type':'application/json'});response.end(JSON.stringify({error:{message:'Login required',code:'42501'}}));return;}
      let body='';for await(const part of request)body+=part;
      const {name,args}=JSON.parse(body);
      try {
        const data=await database.rpc(name,args,user);
        response.writeHead(200,{'content-type':'application/json'});response.end(JSON.stringify({data,error:null}));
        if(!['ah_workshop_snapshot','ah_workshop_command_status'].includes(name))for(const target of events)target.write('data: {}\n\n');
      } catch(error) {response.writeHead(200,{'content-type':'application/json'});response.end(JSON.stringify({data:null,error:{message:error.message,code:error.code}}));}
      return;
    }
    if(url.pathname==='/'||url.pathname==='/index.html') {response.writeHead(200,{'content-type':'text/html'});response.end(await readFile(new URL('../../index.html',import.meta.url)));return;}
    response.writeHead(404);response.end();
  } catch(error) {response.writeHead(500);response.end(JSON.stringify({error:String(error)}));}
});
server.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({port:server.address().port})));
process.on('SIGTERM',()=>{for(const response of events)response.end();server.close();void database.close().finally(()=>process.exit());});
