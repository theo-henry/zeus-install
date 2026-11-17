# EU vault and Standard read block scenario of the app on a simulated Mac (app/test/sim/run.sh --vault). Sourced by
# run.sh: it uses its helpers (act, check, need, wait_for, launch_app, stop_app, ...) and eu_sandbox of eu.sh.
# The vault is a real encrypted disk image (hdiutil) in the simulated home folder. Its key goes to a keychain file of the
# test (ZEUS_APP_TEST_KEYCHAIN), not the login keychain, and the test answers Touch ID (ZEUS_APP_TEST_VAULT_AUTH), so
# no window of macOS opens. Standard sessions run in the real read block (sandbox-exec).
# check runs its test, in single quotes, with eval; ShellCheck does not see the variables in it.
# shellcheck disable=SC2016,SC2034,SC2154

real_path() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# vault_mounted: a volume is mounted at the vault folder of the simulated home.
vault_mounted() { mount | grep -qF " on $VAULT_REAL (apfs"; }

# vault_state_has <text>: the app writes the state of the vault into the trace, and it has this text.
vault_state_has() {
  local before
  before="$(grep -c "vault state: " "$TRACE" || true)"
  act test-vault-state
  wait_count "vault state: " $((before + 1)) 10 >/dev/null && grep "vault state: " "$TRACE" | tail -1 | grep -qF -- "$1"
}

# vault_encrypted: hdiutil says that the disk image of the vault is encrypted with one passphrase.
vault_encrypted() {
  local info waited=0
  until [ "$waited" -ge 20 ]; do
    info="$(hdiutil isencrypted "$BUNDLE" 2>&1 || true)"
    if printf '%s\n' "$info" | grep -q "encrypted: YES"; then printf '%s\n' "$info" | grep -q "passphrase-count: 1"; return; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# probe_has <line>: the read block probe of the newest Standard session wrote this line.
probe_has() { grep -qxF -- "$1" "$PROBE_OUT"; }

# Called by the cleanup of run.sh: the vault and the test keychain go before the work folder.
vault_cleanup() {
  [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null || true
  [ -n "${LARGE_SERVER_PID:-}" ] && kill "$LARGE_SERVER_PID" 2>/dev/null || true
  if [ -n "${VAULT_REAL:-}" ] && mount | grep -qF " on $VAULT_REAL ("; then hdiutil detach -force "$VAULT_REAL" >/dev/null 2>&1 || true; fi
  [ -n "${VAULT_KEYCHAIN:-}" ] && security delete-keychain "$VAULT_KEYCHAIN" >/dev/null 2>&1 || true
}

vault_scenario() {
  echo
  echo "Scenario vault: the EU vault (create, Touch ID, keychain, lock at quit, crash) and the Standard read block"
  eu_sandbox
  VAULT="$SANDBOX/.zeus/eu"
  BUNDLE="$SANDBOX/Library/Application Support/Zeus/eu-vault.sparsebundle"
  JAIL="$SANDBOX/Library/Application Support/Zeus/jail/standard.sb"
  HANDOVER="$SANDBOX/Library/Application Support/Zeus/handover"
  # The EU folders of the EU mode from before the vault, which a vault mount would hide.
  mkdir -p "$VAULT/claude" "$HANDOVER"
  printf 'old EU state\n' >"$VAULT/claude/settings.json"
  VAULT_REAL="$(real_path "$VAULT")"
  # A keychain file of the test, which never locks while the test runs.
  VAULT_KEYCHAIN="$WORK/vault/test.keychain-db"
  mkdir -p "$WORK/vault"
  security create-keychain -p "$(uuidgen)" "$VAULT_KEYCHAIN"
  security set-keychain-settings "$VAULT_KEYCHAIN"

  launch_app vault ZEUS_APP_TEST_VAULT_AUTH=allow ZEUS_APP_TEST_KEYCHAIN="$VAULT_KEYCHAIN"
  need "the app opens a Standard chat" 'wait_for "page loaded: http://127.0.0.1" $PAGE_LOAD_LIMIT && sleep 1'
  check "without an EU vault, Standard starts as before, without the read block" \
    'grep -q "jail: off: no EU vault on this Mac" "$TRACE" && ! grep -q "jail: on" "$TRACE" && [ ! -e "$JAIL" ] && grep -qxF "session command: $SANDBOX/.local/bin/zeus --no-open" <(sed "s/^[^ ]* //" "$TRACE")'

  # Create: refused over the old EU folders, cancelled Touch ID, then made.
  act test-vault-create
  check "the vault is not made over the EU folders from before the vault" \
    'wait_for "vault: create failed: folder not empty" 20 && [ ! -e "$BUNDLE" ] && [ -f "$VAULT/claude/settings.json" ]'
  rm -rf "$VAULT"
  act test-vault-auth:cancel
  act test-vault-create
  check "a cancelled Touch ID makes no vault and no key" \
    'wait_for "vault: create failed: cancelled" 20 && [ ! -e "$BUNDLE" ] && ! security find-generic-password -s io.github.theo-henry.zeus.eu-vault "$VAULT_KEYCHAIN" >/dev/null 2>&1'
  act test-vault-auth:allow
  act test-vault-create
  need "the app makes the vault after Touch ID and mounts it" 'wait_for "vault: create ok" 90 && vault_mounted'
  shot vault-1-created
  check "the vault is a sparse bundle, owner only" '[ -f "$BUNDLE/Info.plist" ] && [ "$(stat -f %Lp "$BUNDLE")" = 700 ]'
  check "it is mounted without a Finder icon, with owners, owner only" \
    'mount | grep -F " on $VAULT_REAL (apfs" | grep -q nobrowse && ! mount | grep -F " on $VAULT_REAL (" | grep -q noowners && [ "$(stat -f %Lp "$VAULT")" = 700 ]'
  check "the marker names the mounted volume" \
    'python3 -c "import json,sys,plistlib,subprocess; m=json.load(open(sys.argv[1])); i=plistlib.loads(subprocess.check_output([\"diskutil\",\"info\",\"-plist\",sys.argv[2]])); sys.exit(0 if m[\"kind\"]==\"zeus-eu-vault\" and m[\"volume_uuid\"]==i[\"VolumeUUID\"] else 1)" "$VAULT/.zeus-vault" "$VAULT"'
  check "Spotlight does not index the vault" '[ -e "$VAULT/.metadata_never_index" ]'
  check "the key is in the keychain, readable only by the app" \
    'security find-generic-password -s io.github.theo-henry.zeus.eu-vault -a eu-vault "$VAULT_KEYCHAIN" >/dev/null 2>&1 && security dump-keychain -a "$VAULT_KEYCHAIN" 2>/dev/null | grep -A3 "decrypt derive" | grep -q "applications (1):" && security dump-keychain -a "$VAULT_KEYCHAIN" 2>/dev/null | grep -A4 "decrypt derive" | grep -qF "/Zeus-dev.app"'
  check "the key is in no trace and no output of the app" '! grep -Eq "[0-9a-f]{64}" "$TRACE" "$WORK/vault/app.out"'
  check "a vault that is open needs no Touch ID" \
    'act test-vault-auth:cancel && act test-vault-unlock && wait_for "vault: unlock ok" 20 && act test-vault-auth:allow'
  printf 'ana@example.com,ACME\n' >"$VAULT/rows.csv"

  # The read block: a new Standard session tries the vault and the other EU folders as Claude would.
  mkdir -p "$WORK/large"
  head -c 20000000 /dev/urandom >"$WORK/large/view.json"
  python3 -m http.server 0 --bind 127.0.0.1 --directory "$WORK/large" >"$WORK/large/server.log" 2>&1 &
  LARGE_SERVER_PID=$!
  local port="" waited=0
  until [ -n "$port" ] || [ "$waited" -ge 40 ]; do
    sleep 0.25
    waited=$((waited + 1))
    port="$( (lsof -nP -a -p "$LARGE_SERVER_PID" -iTCP -sTCP:LISTEN 2>/dev/null || true) | awk 'NR>1{split($9,a,":"); print a[2]; exit}')"
  done
  printf 'EU handover\n' >"$HANDOVER/probe.txt"
  python3 - "$STATE/jail-probe.json" <<PY
import json, sys
json.dump({
    "read": ["$VAULT/rows.csv", "$VAULT/.zeus-vault", "$BUNDLE/Info.plist", "$SANDBOX/Code/zeus-eu/clients/acme/out/rows.csv",
             "$HANDOVER/probe.txt"],
    "write": ["$VAULT/standard-wrote.txt", "$JAIL", "$SANDBOX/Code/zeus-eu/clients/acme/standard-wrote.txt"],
    "control": "$SANDBOX/Code/zeus/clients/acme/project.json",
    "url": "http://127.0.0.1:$port/view.json",
    "sha256": "$(shasum -a 256 "$WORK/large/view.json" | awk '{print $1}')",
    "out": "$SANDBOX/Code/zeus/clients/acme/view.json",
}, open(sys.argv[1], "w"))
PY
  act new-chat
  need "with an EU vault, a new Standard session starts in the read block" \
    'wait_count "jail: on" 1 30 && wait_starts 2 && grep -qxF "session command: /usr/bin/sandbox-exec -f $JAIL $SANDBOX/.local/bin/zeus --no-open" <(sed "s/^[^ ]* //" "$TRACE")'
  check "the app writes the read block profile, owner only" '[ -f "$JAIL" ] && [ "$(stat -f %Lp "$JAIL")" = 600 ] && [ "$(stat -f %Lp "$(dirname "$JAIL")")" = 700 ]'
  real_home="$(real_path "$SANDBOX")"
  check "the profile allows everything but the EU folders" \
    'grep -qx "(allow default)" "$JAIL" && grep -qx "(deny file-read\* file-write\*" "$JAIL"'
  for folder in "$real_home/.zeus/eu" "$real_home/Library/Application Support/Zeus/eu-vault.sparsebundle" \
    "$real_home/Code/zeus-eu" "/private/tmp/zeus-eu-$(id -u)" "$real_home/Library/Application Support/Zeus/handover"; do
    check "the profile denies ${folder#"$real_home"/}" 'grep -qxF "  (subpath \"$folder\")" "$JAIL"'
  done
  check "the profile keeps the Standard workspace and the home folder open" \
    '! grep -qF "(subpath \"$real_home/Code/zeus\")" "$JAIL" && ! grep -qF "(subpath \"$real_home\")" "$JAIL"'
  check "the profile denies writes to its own folder" 'grep -qx "(deny file-write\*" "$JAIL" && grep -qF "(subpath \"$real_home/Library/Application Support/Zeus/jail\")" "$JAIL"'

  PROBE_OUT="$STATE/jail-probe-$(grep " start standard" "$STATE/sessions" | tail -1 | awk '{print $1}').out"
  need "the session ran its probe" 'wait_file_has "^done$" "$PROBE_OUT" 60'
  for file in "$VAULT/rows.csv" "$VAULT/.zeus-vault" "$BUNDLE/Info.plist" "$SANDBOX/Code/zeus-eu/clients/acme/out/rows.csv" "$HANDOVER/probe.txt"; do
    check "Standard cat, python3, bash, and node can not read ${file#"$SANDBOX"/}" \
      'probe_has "cat denied $file" && probe_has "python denied $file" && probe_has "bash denied $file" && probe_has "node denied $file"'
  done
  check "Standard can not write the vault, the EU workspace, or the profile" \
    'probe_has "write denied $VAULT/standard-wrote.txt" && probe_has "write denied $JAIL" && probe_has "write denied $SANDBOX/Code/zeus-eu/clients/acme/standard-wrote.txt" && [ ! -e "$VAULT/standard-wrote.txt" ]'
  check "Standard still reads its own workspace" 'probe_has "control read $SANDBOX/Code/zeus/clients/acme/project.json"'
  check "Standard still gets a large response complete (20 MB, as a large View) and writes it" \
    'probe_has "large complete 20000000 bytes" && cmp -s "$WORK/large/view.json" "$SANDBOX/Code/zeus/clients/acme/view.json"'
  kill "$LARGE_SERVER_PID" 2>/dev/null || true
  LARGE_SERVER_PID=""
  rm -f "$STATE/jail-probe.json"

  # Lock: refused while a program has a vault file open; at quit, after the sessions stopped, it is forced.
  (exec 3<"$VAULT/rows.csv"; exec sleep 300) &
  HOLDER_PID=$!
  sleep 0.5
  act test-vault-lock
  check "a lock while a program has a vault file open fails, and the vault stays open" \
    'wait_for "vault: lock failed: busy" 30 && vault_mounted'
  stop_app
  check "the quit locks the vault after the sessions stopped, also with the open file" \
    'grep -q "vault: lock (force) ok" "$TRACE" && ! vault_mounted'
  check "the lock comes after the sessions stopped" \
    '[ "$(grep -n "state: ended" "$TRACE" | tail -1 | cut -d: -f1)" -lt "$(grep -n "vault: lock (force) ok" "$TRACE" | cut -d: -f1)" ]'
  kill "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=""
  # hdiutil reads the encryption only of a disk image that is not attached, and some seconds after the detach.
  check "the locked vault is encrypted" 'vault_encrypted'

  # Unlock: cancelled Touch ID, then Touch ID.
  launch_app vault-unlock ZEUS_APP_TEST_VAULT_AUTH=cancel ZEUS_APP_TEST_KEYCHAIN="$VAULT_KEYCHAIN"
  need "the app opens again" 'wait_for "page loaded: http://127.0.0.1" $PAGE_LOAD_LIMIT && sleep 1'
  check "the app start does not open the vault" 'vault_state_has "exists=true mounted=false"'
  check "with a locked EU vault, Standard still starts in the read block" 'grep -q "jail: on" "$TRACE" && ! grep -q "jail: off" "$TRACE"'
  act test-vault-unlock
  check "a cancelled Touch ID keeps the vault locked" 'wait_for "vault: unlock failed: cancelled" 20 && ! vault_mounted'
  act test-vault-auth:allow
  act test-vault-unlock
  check "Touch ID unlocks the vault with the key of the keychain" \
    'wait_for "vault: unlock ok" 30 && vault_mounted && grep -qx "ana@example.com,ACME" "$VAULT/rows.csv" && vault_state_has "marker=true"'
  shot vault-2-unlocked

  # A crash leaves the vault mounted; the next start locks it before anything else.
  kill -9 "$APP_PID"
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  sleep 1
  check "after a crash the vault stays mounted" 'vault_mounted'
  launch_app vault-crash ZEUS_APP_TEST_VAULT_AUTH=allow ZEUS_APP_TEST_KEYCHAIN="$VAULT_KEYCHAIN"
  check "the next start locks the vault before anything else" \
    'wait_for "vault: detached at start: ok" 30 && ! vault_mounted && [ "$(grep -n "vault: detached at start" "$TRACE" | head -1 | cut -d: -f1)" -lt "$(grep -n "launched: " "$TRACE" | head -1 | cut -d: -f1)" ]'
  need "the app opens after the crash" 'wait_for "page loaded: http://127.0.0.1" $PAGE_LOAD_LIMIT && sleep 1'

  # A key that does not open the vault.
  act test-vault-wrong-key
  wait_for "vault: wrong key saved" 10 >/dev/null || true
  act test-vault-unlock
  check "a wrong key does not open the vault" 'wait_for "vault: unlock failed: wrong password" 30 && ! vault_mounted'

  # A Zeus Editor that runs Standard commands in the Claude Code sandbox: Claude Code could not start in the jail.
  local plugin="$SANDBOX/.claude/plugins/cache/zeus-editor/zeus-editor/sim"
  printf 'const SANDBOX_EXCLUDED_COMMANDS = ["python3 scripts/zeus.py * --via browser*"];\n' >"$plugin/dist/chunk-old.mjs"
  act new-chat
  check "with that Zeus Editor, Standard starts without the read block and says why" \
    'wait_for "jail: off: the installed Zeus Editor runs Standard commands in the Claude Code sandbox" 30'
  rm -f "$plugin/dist/chunk-old.mjs"
  # A quit while a chat page still loads asks first: the page can not answer the close check yet.
  newest_page_loaded "$PAGE_LOAD_LIMIT" >/dev/null || true
  sleep 1
  stop_app
}
