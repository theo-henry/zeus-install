// Executable PTY fixture. Each tab has its own server, input, and lifecycle records.
import http from 'node:http';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
if (!process.stdin.isTTY || !process.stdout.isTTY) process.exit(2);
// Like zeus, the terminal is in raw mode: each key comes in at once, and Enter is \r.
process.stdin.setRawMode(true);
const state = process.env.ZEUS_SIM_STATE;
const record = (event, detail = '') => fs.appendFileSync(`${state}/sessions`, `${process.pid} ${event} ${detail}\n`);
// EU mode (`zeus --eu`, zeus-editor src/chat/cli.js): its own editor state folder and workspace, a Google Cloud check
// before the start, and the session cost after each reply.
const eu = process.argv.includes('--eu');
record('start', eu ? 'eu' : 'standard');
if (eu) {
 // The EU preflight (zeus-editor src/eu/preflight.js): <state>/eu-preflight names the step that fails.
 let failing = '';
 try { failing = fs.readFileSync(`${state}/eu-preflight`, 'utf8').trim(); } catch {}
 const login = 'Run `gcloud auth application-default login`, then `gcloud auth application-default set-quota-project project-4bf0bacd-fec4-406b-a99`, and start EU mode again.';
 const failures = {
  signin: `You are not signed in to Google Cloud for EU mode. ${login}`,
  403: 'Your Google account sim@example.com has no access to the Apolix EU project. Ask the Zeus maintainer for the Vertex AI User role. Try again later.',
  404: 'The EU model claude-sonnet-5-5 is not available. Tell the Zeus maintainer. Try again later.',
  429: 'The EU project has no capacity for claude-sonnet-5-5 now. Try again later or tell the Zeus maintainer. Try again later.',
 };
 console.log('Zeus is checking your Google Cloud access for EU mode...');
 if (failures[failing]) {
  record('preflight-failed', failing);
  process.stderr.write(`zeus: ${failures[failing]}\n`);
  process.exit(3);
 }
}
// Like the launcher of zeus-editor: a Claude Code session id, which `restart {resume}` on the control socket replaces,
// and the text typed in the terminal that is not sent yet (Enter sends it).
let sessionId = crypto.randomUUID();
let terminalDraft = '';
record('session', sessionId);
// The project of each session, as the Zeus chat keeps it with the chat.
const projectFile = (id) => `${state}/project-${id}`;
const projectOf = (id) => { try { return fs.readFileSync(projectFile(id), 'utf8'); } catch { return 'No project'; } };
console.log('Checking for Zeus updates... (simulated)');
let busy = false;
// Like the mic of the Zeus chat and Zeus Editor: the dictated text replaces only its own span of the message box.
const speech = `window.speechEvents=[];let dictationStart=null,dictationLength=0;
window.speechStatus=null;window.speechSettings=null;window.speechModelStates=[];
window.zeusSpeech={onEvent(e){
 if(e.type==='status'){window.speechStatus=e;for(const m of e.models||[]){const s=m.role+':'+m.id+':'+m.state;if(window.speechModelStates.at(-1)!==s&&!window.speechModelStates.includes(s))window.speechModelStates.push(s);}return;}
 if(e.type==='settings'){window.speechSettings=e;return;}
 window.speechEvents.push([e.type,e.id,e.state||e.code||e.text||(e.locales&&e.locales.map(l=>l.id).join(',')+'/'+e.default)||''].join(' '));
 const box=document.querySelector('textarea');
 if(e.type==='state'&&e.state==='listening'){dictationStart=box.value.length;dictationLength=0;}
 if((e.type==='partial'||e.type==='final')&&dictationStart!==null){box.value=box.value.slice(0,dictationStart)+e.text+box.value.slice(dictationStart+dictationLength);dictationLength=e.text.length;}
 if(e.type==='state'&&e.state==='stopped')dictationStart=null;
}};`;
const editor = `<!doctype html><html lang="en"><head><title>Zeus Editor (simulated)</title></head><body><h1>Zeus Editor</h1><textarea aria-label="Feedback"></textarea><script>${speech}</script></body></html>`;
const page = `<!doctype html><html lang="en"><head><title>Zeus (simulated)</title><style>
body{background:#0b2545;color:#f1f6f9;font:16px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
main{width:600px}#session{font-size:12px;color:#9fb4cc}#globe{width:120px;height:120px;margin:0 auto;border-radius:50%;background:radial-gradient(circle at 40% 35%,#5b8cff,#1a3a64);opacity:0}
.live #globe{opacity:1}textarea{display:block;width:100%;background:#071d38;color:#f1f6f9;border:1px solid #24477a;padding:16px;margin:20px 0}button{background:#3772ff;color:white;border:0;padding:10px 20px;border-radius:8px}
header{position:fixed;top:0;left:0;right:0;display:flex;justify-content:flex-end;gap:8px;padding:12px}.pill{background:none;color:#c7dbe6;border:1px solid #24477a;border-radius:999px;padding:4px 11px}.project-menu{display:none}
</style></head><body><header><nav class="project-menu" role="listbox"><button role="option"><span class="menu-item-label">Solvias</span></button><button role="option"><span class="menu-item-label">Vicat</span></button><button role="option"><span class="menu-item-label">acme</span></button><button role="option"><span class="menu-item-label">No project</span></button></nav><button class="pill project-pill"><span class="pill-text">__PROJECT__</span></button></header><main><div id="globe"></div><h1>Zeus chat</h1><p>PTY session ${process.pid}</p><p id="session">Chat __SESSION__</p><p id="mode">Mode: __EU__</p><p id="reply">How can I help?</p><textarea id="zeus-message" aria-label="Message"></textarea><button id="send">Send</button></main><script>
${speech}
let pending=false;
// Like the chat page of zeus-editor: the app moves its loading globe to this globe (rect), then shows the page.
window.zeusGlobe={
 rect(){const b=document.getElementById('globe').getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height};},
 enter(){document.body.classList.add('entered');},
 reveal(){document.body.classList.add('live');},
};
// Like the Zeus chat, the message box has the focus when the page opens.
document.getElementById('zeus-message').focus();
requestAnimationFrame(()=>requestAnimationFrame(()=>window.webkit?.messageHandlers?.zeusApp?.postMessage('chat-ready')));
// The project menu and the project button of the Zeus chat (zeus-editor src/chat/client/main.js).
for(const option of document.querySelectorAll('.project-menu [role="option"]'))option.onclick=()=>{document.querySelector('.project-pill .pill-text').textContent=option.textContent;fetch('/project',{method:'POST',body:option.textContent});};
// Like the settings pop-up of the Zeus chat: the app menu item Settings… (Cmd+,) opens it.
// Like "Check for updates" in the settings of the Zeus chat: the page keeps the update events of the app.
window.updateEvents=[];
window.zeusApp={openSettings(){window.settingsOpened=(window.settingsOpened||0)+1;},onUpdateEvent(e){window.updateEvents.push(e);},closeState:async()=>{
 if(document.getElementById('zeus-message').value.trim())return {safe_to_close:false,reason:'composer-draft'};
 if(pending)return {safe_to_close:false,reason:'busy'};
 return await (await fetch('/close-state')).json();
}};
document.getElementById('send').onclick=async()=>{
 const text=document.getElementById('zeus-message').value;
 pending=true;document.getElementById('zeus-message').value='';
 document.getElementById('reply').textContent='Working...';
 document.getElementById('reply').textContent=await(await fetch('/turn',{method:'POST',body:text})).text();pending=false;
 // Like the EU chat page (zeus-editor src/chat/client/main.js): the cost after each reply, and a Vertex error.
 if(__EU__){
  window.webkit?.messageHandlers?.zeusApp?.postMessage('cost:'+await(await fetch('/cost')).text());
  const status=/EU_ERROR_([0-9]{3})/.exec(text);
  if(status)window.webkit?.messageHandlers?.zeusApp?.postMessage('eu-error:'+JSON.stringify({status:Number(status[1]),model:'claude-sonnet-5-5'}));
 }
};
</script></body></html>`;
// With <state>/no-close-state at start, this session acts like an editor plugin older than the app: no window.zeusApp.
// With <state>/hung-close-state at start, window.zeusApp.closeState() never answers.
const template = fs.existsSync(`${state}/no-close-state`) ? page.replace('window.zeusApp=', 'window.oldPlugin=')
  : fs.existsSync(`${state}/hung-close-state`) ? page.replace('closeState:async()=>{', 'closeState:async()=>{await new Promise(r=>setTimeout(r,600000));')
  : page;
// With <state>/long-turn at start, a turn of this session takes 60 s, longer than any check that waits on it.
const turnMs = fs.existsSync(`${state}/long-turn`) ? 60000 : Number(process.env.ZEUS_SIM_TURN_MS||3000);
// The page shows the chat of the session that runs now, in its project.
const html = () => template.replace('__SESSION__', sessionId).replace('__PROJECT__', projectOf(sessionId)).replaceAll('__EU__', String(eu));
// EU mode: the session cost of this launch (zeus-editor src/eu/cost.js), one Sonnet 5.5 call of 0.045220 USD per turn.
let turns = 0;
const cost = () => JSON.stringify({mode:'eu',currency:'USD',session_total:0.000035+turns*0.04522,chat_total:turns*0.04522,calls:1+turns,
 unpriced_calls:0,tokens:{input:2*turns,output:4*turns,cache_read:0,cache_write_5m:16426*turns,cache_write_1h:0},prices_as_of:'2026-11-16'});
const server = http.createServer((req, res) => {
 if(req.url === '/close-state') {res.end(JSON.stringify({safe_to_close:!busy,reason:busy?'busy':'idle'}));return;}
 if(req.url === '/project') {let name='';req.on('data',chunk=>name+=chunk);req.on('end',()=>{fs.writeFileSync(projectFile(sessionId),name.trim());res.end('ok');});return;}
 if(req.url === '/turn') {
  busy=true;record('busy');let text='';req.on('data',chunk=>text+=chunk);req.on('end',()=>setTimeout(()=>{busy=false;turns+=1;record('reply',text);res.end('Reply: '+text);},turnMs));return;
 }
 if(req.url === '/cost') {res.end(cost());return;}
 res.writeHead(200,{'content-type':'text/html;charset=utf-8'});res.end(req.url === '/editor' ? editor : html());
});
// The control socket and the launch record of the launcher (zeus-editor packages/launcher/control.js).
const stateDir = eu ? path.join(os.homedir(), '.zeus', 'eu', 'editor') : (process.env.ZEUS_EDITOR_STATE_DIR || path.join(os.homedir(), '.zeus-editor'));
const launchRecord = path.join(stateDir, 'chat', 'launches', `${process.pid}.json`);
const socketPath = path.join(os.tmpdir(), `zeus-sim-${process.pid}.sock`);
const launcherState = () => ({running:true,starting:false,restarting:false,sessionId,status:busy?'busy':'idle',
 input:{present:true,empty:terminalDraft==='',draft:terminalDraft},dialog:null,spinner:null,mode:null,pending:[],exit:null});
const control = net.createServer((socket) => {
 let authed = false, buffer = '';
 socket.setEncoding('utf8');
 socket.on('error', () => {});
 socket.on('data', (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) !== -1) {
   const message = JSON.parse(buffer.slice(0, newline));
   buffer = buffer.slice(newline + 1);
   const reply = (value) => socket.write(JSON.stringify({id:message.id,...value}) + '\n');
   if (!authed) {
    if (message.op === 'hello' && message.token === 'simulated') { authed = true; reply({ok:true,result:launcherState()}); }
    else { reply({ok:false,error:'unauthorized'}); socket.destroy(); }
    continue;
   }
   // A state event between the replies, as the launcher sends them.
   socket.write(JSON.stringify({event:'state',state:launcherState()}) + '\n');
   if (message.op === 'state') reply({ok:true,result:launcherState()});
   else if (message.op === 'send') {
    // A message for Claude, as the chat sends it. The handover request of the app: EU Zeus writes the summary that
    // <state>/eu-summary.md holds into a new handover of the project in <state>/eu-summary-project.
    record('send', String(message.text || '').slice(0, 60).replace(/\s+/g, '_'));
    if (eu && fs.existsSync(`${state}/eu-summary.md`)) {
     const project = fs.readFileSync(`${state}/eu-summary-project`, 'utf8').trim();
     const id = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z') + '-' + crypto.randomBytes(3).toString('hex');
     const folder = path.join(os.homedir(), 'Code', 'zeus-eu', 'clients', project, 'handoff', id);
     setTimeout(() => { fs.mkdirSync(folder, {recursive:true}); fs.copyFileSync(`${state}/eu-summary.md`, path.join(folder, 'summary.md')); record('summary', id); }, 1500);
    }
    reply({ok:true,result:{id:message.send_id}});
   }
   else if (message.op === 'restart') {
    if (typeof message.resume === 'string') { sessionId = message.resume; record('resume', sessionId); }
    terminalDraft = '';
    setTimeout(() => reply({ok:true,result:launcherState()}), 300);
   } else reply({ok:false,error:'unknown op'});
  }
 });
});
fs.rmSync(socketPath, {force:true});
// Delay only the fixture to permit startup screenshots. The app adds no wait.
setTimeout(()=>control.listen(socketPath,()=>server.listen(0,'127.0.0.1',()=>{
 fs.mkdirSync(path.dirname(launchRecord), {recursive:true});
 fs.writeFileSync(launchRecord, JSON.stringify({id:String(process.pid),token:'simulated',socket:socketPath,cwd:process.cwd(),pid:process.pid}));
 console.log(`Zeus chat: http://127.0.0.1:${server.address().port}/chat/${process.pid}#k=simulated`);
})), Number(process.env.ZEUS_SIM_START_DELAY || 0));
fs.writeFileSync(`${state}/zeus-started`,JSON.stringify({args:process.argv.slice(2),cwd:process.cwd(),app:process.env.ZEUS_APP}));
fs.appendFileSync(`${state}/zeus-starts`,JSON.stringify({pid:process.pid,args:process.argv.slice(2),cwd:process.cwd()})+'\n');
process.stdin.on('data',data=>{
 record('input',data.toString('hex'));
 // Enter sends the terminal text; other keys add to it. A paste comes in its bracketed paste marks.
 const text=data.toString().replace(/\x1b\[20[01]~/g,'');
 for(const char of text){if(char==='\r')terminalDraft='';else if(char==='\x15')terminalDraft='';else terminalDraft+=char;}
});
// ZEUS_SIM_TURN_MS (ms): a turn takes that long (default 3 s).
// ZEUS_SIM_STOP_DELAY (ms): zeus takes that long to stop, like Claude Code that ends a turn.
const stop=signal=>{fs.writeFileSync(`${state}/zeus-stopped`,signal);record('stop',signal);server.close();control.close();fs.rmSync(launchRecord,{force:true});fs.rmSync(socketPath,{force:true});setTimeout(()=>process.exit(0),Number(process.env.ZEUS_SIM_STOP_DELAY||0));};
process.on('SIGTERM',()=>stop('SIGTERM'));process.on('SIGHUP',()=>stop('SIGHUP'));
