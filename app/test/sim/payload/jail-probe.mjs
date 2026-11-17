// What a Standard Zeus session can reach in the read block of the app (app/Sources/Zeus/StandardJail.swift).
// The simulated zeus runs it as its child, so it is in the same jail as Claude Code, its hooks, and its Bash commands.
// Usage: node jail-probe.mjs <probe.json> <result file>
// probe.json: {"read": [files the jail must hide], "write": [files the jail must not let it write],
//              "control": a Standard file it must read, "url": a large response (a Celonis View), "sha256": its hash,
//              "out": where it writes that response}
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';

const [probeFile, resultFile] = process.argv.slice(2);
const probe = JSON.parse(fs.readFileSync(probeFile, 'utf8'));
const lines = [];
const note = (line) => lines.push(line);
const denied = (result) => result.status !== 0 && /Operation not permitted/.test(String(result.stderr));

for (const file of probe.read) {
  note(`cat ${denied(spawnSync('/bin/cat', [file])) ? 'denied' : 'ALLOWED'} ${file}`);
  note(`python ${denied(spawnSync('python3', ['-c', 'import sys; open(sys.argv[1]).read()', file])) ? 'denied' : 'ALLOWED'} ${file}`);
  note(`bash ${denied(spawnSync('/bin/bash', ['-c', 'cat "$1"', 'probe', file])) ? 'denied' : 'ALLOWED'} ${file}`);
  let nodeRead = 'ALLOWED';
  try { fs.readFileSync(file); } catch (error) { if (error.code === 'EPERM') nodeRead = 'denied'; else nodeRead = `error-${error.code}`; }
  note(`node ${nodeRead} ${file}`);
}
for (const file of probe.write) {
  let write = 'ALLOWED';
  try { fs.writeFileSync(file, 'written by a Standard session\n'); } catch (error) { write = error.code === 'EPERM' ? 'denied' : `error-${error.code}`; }
  note(`write ${write} ${file}`);
}
const control = spawnSync('/bin/cat', [probe.control]);
note(`control ${control.status === 0 ? 'read' : 'FAILED'} ${probe.control}`);

// A large response, as content-cli gets a large View: every byte must arrive.
const body = await new Promise((resolve) => {
  http.get(probe.url, (response) => {
    const chunks = [];
    response.on('data', (chunk) => chunks.push(chunk));
    response.on('end', () => resolve(Buffer.concat(chunks)));
    response.on('error', () => resolve(null));
  }).on('error', () => resolve(null));
});
if (body) fs.writeFileSync(probe.out, body);
const hash = body ? crypto.createHash('sha256').update(body).digest('hex') : 'none';
note(`large ${hash === probe.sha256 ? 'complete' : 'BROKEN'} ${body ? body.length : 0} bytes`);
note('done');
fs.writeFileSync(resultFile, lines.join('\n') + '\n');
