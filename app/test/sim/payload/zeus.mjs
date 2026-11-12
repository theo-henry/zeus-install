// Executable PTY fixture. Each tab has its own server, input, and lifecycle records.
import http from 'node:http';
import fs from 'node:fs';
if (!process.stdin.isTTY || !process.stdout.isTTY) process.exit(2);
const state = process.env.ZEUS_SIM_STATE;
const record = (event, detail = '') => fs.appendFileSync(`${state}/sessions`, `${process.pid} ${event} ${detail}\n`);
record('start');
console.log('Checking for Zeus updates... (simulated)');
let busy = false;
const page = `<!doctype html><html lang="en"><head><title>Zeus (simulated)</title><style>
body{background:#0b2545;color:#f1f6f9;font:16px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
main{width:600px}textarea{display:block;width:100%;background:#071d38;color:#f1f6f9;border:1px solid #24477a;padding:16px;margin:20px 0}button{background:#3772ff;color:white;border:0;padding:10px 20px;border-radius:8px}
</style></head><body><main><h1>Zeus chat</h1><p>PTY session ${process.pid}</p><p id="reply">How can I help?</p><textarea id="prompt" aria-label="Message"></textarea><button id="send">Send</button></main><script>
let pending=false;
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
const server = http.createServer((req, res) => {
 if(req.url === '/close-state') {res.end(JSON.stringify({safe_to_close:!busy,reason:busy?'busy':'idle'}));return;}
 if(req.url === '/turn') {
  busy=true;record('busy');let text='';req.on('data',chunk=>text+=chunk);req.on('end',()=>setTimeout(()=>{busy=false;record('reply',text);res.end('Reply: '+text);},3000));return;
 }
 res.writeHead(200,{'content-type':'text/html;charset=utf-8'});res.end(page);
});
// Delay only the fixture to permit startup screenshots. The app adds no wait.
setTimeout(()=>server.listen(0,'127.0.0.1',()=>{
 console.log(`Zeus chat: http://127.0.0.1:${server.address().port}/chat/${process.pid}#k=simulated`);
}), Number(process.env.ZEUS_SIM_START_DELAY || 0));
fs.writeFileSync(`${state}/zeus-started`,JSON.stringify({args:process.argv.slice(2),cwd:process.cwd(),app:process.env.ZEUS_APP}));
process.stdin.on('data',data=>record('input',data.toString('hex')));
const stop=signal=>{fs.writeFileSync(`${state}/zeus-stopped`,signal);record('stop',signal);server.close();process.exit(0);};
process.on('SIGTERM',()=>stop('SIGTERM'));process.on('SIGHUP',()=>stop('SIGHUP'));
