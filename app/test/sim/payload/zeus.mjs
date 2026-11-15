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
record('start');
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
</style></head><body><header><nav class="project-menu" role="listbox"><button role="option"><span class="menu-item-label">Solvias</span></button><button role="option"><span class="menu-item-label">Vicat</span></button><button role="option"><span class="menu-item-label">No project</span></button></nav><button class="pill project-pill"><span class="pill-text">__PROJECT__</span></button></header><main><div id="globe"></div><h1>Zeus chat</h1><p>PTY session ${process.pid}</p><p id="session">Chat __SESSION__</p><p id="reply">How can I help?</p><textarea id="zeus-message" aria-label="Message"></textarea><button id="send">Send</button></main><script>
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
};
</script></body></html>`;
// With <state>/no-close-state at start, this session acts like an editor plugin older than the app: no window.zeusApp.
// With <state>/hung-close-state at start, window.zeusApp.closeState() never answers.
const template = fs.existsSync(`${state}/no-close-state`) ? page.replace('window.zeusApp=', 'window.oldPlugin=')
  : fs.existsSync(`${state}/hung-close-state`) ? page.replace('closeState:async()=>{', 'closeState:async()=>{await new Promise(r=>setTimeout(r,600000));')
  : page;
// The page shows the chat of the session that runs now, in its project.
const html = () => template.replace('__SESSION__', sessionId).replace('__PROJECT__', projectOf(sessionId));
const server = http.createServer((req, res) => {
 if(req.url === '/close-state') {res.end(JSON.stringify({safe_to_close:!busy,reason:busy?'busy':'idle'}));return;}
 if(req.url === '/project') {let name='';req.on('data',chunk=>name+=chunk);req.on('end',()=>{fs.writeFileSync(projectFile(sessionId),name.trim());res.end('ok');});return;}
 if(req.url === '/turn') {
  busy=true;record('busy');let text='';req.on('data',chunk=>text+=chunk);req.on('end',()=>setTimeout(()=>{busy=false;record('reply',text);res.end('Reply: '+text);},Number(process.env.ZEUS_SIM_TURN_MS||3000)));return;
 }
 res.writeHead(200,{'content-type':'text/html;charset=utf-8'});res.end(req.url === '/editor' ? editor : html());
});
// The control socket and the launch record of the launcher (zeus-editor packages/launcher/control.js).
const stateDir = process.env.ZEUS_EDITOR_STATE_DIR || path.join(os.homedir(), '.zeus-editor');
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
