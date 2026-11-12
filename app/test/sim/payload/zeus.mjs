// Simulated zeus: needs a terminal, prints the chat address, serves a page, and records how it stopped.
import http from "node:http";
import fs from "node:fs";

if (!process.stdin.isTTY || !process.stdout.isTTY) {
  console.error("zeus: run this command in a terminal window.");
  process.exit(2);
}
console.log("Checking for Zeus updates... (simulated)");
const page = `<!doctype html><html><head><title>Zeus (simulated)</title><style>
body{background:#11203b;color:#e6ecf7;font:16px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
a{color:#8fb0ff}</style></head><body><div><h1>Simulated Zeus chat</h1>
<p>Process ${process.pid}, arguments ${JSON.stringify(process.argv.slice(2))}</p><p>Folder ${process.cwd()}</p>
<p><a href="https://example.com">A link to another website (opens in the browser)</a></p></div></body></html>`;
const server = http.createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(page);
});
server.listen(0, "127.0.0.1", () => {
  console.log(`Zeus chat: http://127.0.0.1:${server.address().port}/chat/5e5e5e5e5e5e#k=simulated`);
});
fs.writeFileSync(`${process.env.ZEUS_SIM_STATE}/zeus-started`, JSON.stringify({ args: process.argv.slice(2), cwd: process.cwd() }));
const stop = (signal) => {
  fs.writeFileSync(`${process.env.ZEUS_SIM_STATE}/zeus-stopped`, signal);
  server.close();
  process.exit(0);
};
process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGHUP", () => stop("SIGHUP"));
