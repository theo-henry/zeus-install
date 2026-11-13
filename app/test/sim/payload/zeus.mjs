// Executable PTY fixture. Each tab has its own server, input, and lifecycle records.
import http from 'node:http';
import fs from 'node:fs';
if (!process.stdin.isTTY || !process.stdout.isTTY) process.exit(2);
const state = process.env.ZEUS_SIM_STATE;
const record = (event, detail = '') => fs.appendFileSync(`${state}/sessions`, `${process.pid} ${event} ${detail}\n`);
record('start');
console.log('Checking for Zeus updates... (simulated)');
let busy = false;
// Like the mic of the Zeus chat and Zeus Editor: the dictated text replaces only its own span of the message box.
const speech = `window.speechEvents=[];let dictationStart=null,dictationLength=0;
window.zeusSpeech={onEvent(e){
 window.speechEvents.push([e.type,e.id,e.state||e.code||e.text||(e.locales&&e.locales.map(l=>l.id).join(',')+'/'+e.default)||''].join(' '));
 const box=document.querySelector('textarea');
 if(e.type==='state'&&e.state==='listening'){dictationStart=box.value.length;dictationLength=0;}
 if((e.type==='partial'||e.type==='final')&&dictationStart!==null){box.value=box.value.slice(0,dictationStart)+e.text+box.value.slice(dictationStart+dictationLength);dictationLength=e.text.length;}
 if(e.type==='state'&&e.state==='stopped')dictationStart=null;
}};`;
const editor = `<!doctype html><html lang="en"><head><title>Zeus Editor (simulated)</title></head><body><h1>Zeus Editor</h1><textarea aria-label="Feedback"></textarea><script>${speech}</script></body></html>`;
const page = `<!doctype html><html lang="en"><head><title>Zeus (simulated)</title><style>
body{background:#0b2545;color:#f1f6f9;font:16px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
main{width:600px}#globe{width:120px;height:120px;margin:0 auto;border-radius:50%;background:radial-gradient(circle at 40% 35%,#5b8cff,#1a3a64);opacity:0}
.live #globe{opacity:1}textarea{display:block;width:100%;background:#071d38;color:#f1f6f9;border:1px solid #24477a;padding:16px;margin:20px 0}button{background:#3772ff;color:white;border:0;padding:10px 20px;border-radius:8px}
header{position:fixed;top:0;left:0;right:0;display:flex;justify-content:flex-end;gap:8px;padding:12px}.pill{background:none;color:#c7dbe6;border:1px solid #24477a;border-radius:999px;padding:4px 11px}.project-menu{display:none}
</style></head><body><header><nav class="project-menu" role="listbox"><button role="option"><span class="menu-item-label">Solvias</span></button><button role="option"><span class="menu-item-label">Vicat</span></button><button role="option"><span class="menu-item-label">No project</span></button></nav><button class="pill project-pill"><span class="pill-text">No project</span></button></header><main><div id="globe"></div><h1>Zeus chat</h1><p>PTY session ${process.pid}</p><p id="reply">How can I help?</p><textarea id="prompt" aria-label="Message"></textarea><button id="send">Send</button></main><script>
${speech}
let pending=false;
// Like the chat page of zeus-editor: the app moves its loading globe to this globe (rect), then shows the page.
window.zeusGlobe={
 rect(){const b=document.getElementById('globe').getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height};},
 enter(){document.body.classList.add('entered');},
 reveal(){document.body.classList.add('live');},
};
requestAnimationFrame(()=>requestAnimationFrame(()=>window.webkit?.messageHandlers?.zeusApp?.postMessage('chat-ready')));
// The project menu and the project button of the Zeus chat (zeus-editor src/chat/client/main.js).
for(const option of document.querySelectorAll('.project-menu [role="option"]'))option.onclick=()=>{document.querySelector('.project-pill .pill-text').textContent=option.textContent;};
window.zeusApp={closeState:async()=>{
 if(document.getElementById('prompt').value.trim())return {safe_to_close:false,reason:'composer-draft'};
 if(pending)return {safe_to_close:false,reason:'busy'};
 return await (await fetch('/close-state')).json();
}};
document.getElementById('send').onclick=async()=>{
 const text=document.getElementById('prompt').value;
 pending=true;document.getElementById('prompt').value='';
 document.getElementById('reply').textContent='Working...';
 document.getElementById('reply').textContent=await(await fetch('/turn',{method:'POST',body:text})).text();pending=false;
};
</script></body></html>`;
// With <state>/no-close-state at start, this session acts like an editor plugin older than the app: no window.zeusApp.
// With <state>/hung-close-state at start, window.zeusApp.closeState() never answers.
const html = fs.existsSync(`${state}/no-close-state`) ? page.replace('window.zeusApp=', 'window.oldPlugin=')
  : fs.existsSync(`${state}/hung-close-state`) ? page.replace('closeState:async()=>{', 'closeState:async()=>{await new Promise(r=>setTimeout(r,600000));')
  : page;
const server = http.createServer((req, res) => {
 if(req.url === '/close-state') {res.end(JSON.stringify({safe_to_close:!busy,reason:busy?'busy':'idle'}));return;}
 if(req.url === '/turn') {
  busy=true;record('busy');let text='';req.on('data',chunk=>text+=chunk);req.on('end',()=>setTimeout(()=>{busy=false;record('reply',text);res.end('Reply: '+text);},3000));return;
 }
 res.writeHead(200,{'content-type':'text/html;charset=utf-8'});res.end(req.url === '/editor' ? editor : html);
});
// Delay only the fixture to permit startup screenshots. The app adds no wait.
setTimeout(()=>server.listen(0,'127.0.0.1',()=>{
 console.log(`Zeus chat: http://127.0.0.1:${server.address().port}/chat/${process.pid}#k=simulated`);
}), Number(process.env.ZEUS_SIM_START_DELAY || 0));
fs.writeFileSync(`${state}/zeus-started`,JSON.stringify({args:process.argv.slice(2),cwd:process.cwd(),app:process.env.ZEUS_APP}));
process.stdin.on('data',data=>record('input',data.toString('hex')));
// ZEUS_SIM_STOP_DELAY (ms): zeus takes that long to stop, like Claude Code that ends a turn.
const stop=signal=>{fs.writeFileSync(`${state}/zeus-stopped`,signal);record('stop',signal);server.close();setTimeout(()=>process.exit(0),Number(process.env.ZEUS_SIM_STOP_DELAY||0));};
process.on('SIGTERM',()=>stop('SIGTERM'));process.on('SIGHUP',()=>stop('SIGHUP'));
