# Zeus speech bridge, version 2

This document is the contract between the Zeus app (native macOS shell, `app/Sources/Zeus/Speech.swift`) and the Zeus pages that use speech to text: the main chat and the Zeus Editor pages of zeus-editor.
A page can use the bridge without reading the Swift code.

## Summary of version 2

- Dictation uses local Whisper models (`whisper.cpp`) on the Mac.
  No audio leaves the Mac.
- Whisper gives the text only after Stop.
  While the user speaks, the page gets audio levels (for a waveform), not words.
  After Stop, the page gets a `processing` state, then the `final` text.
- While the Whisper model is not ready (first download, or the load after the app start), the app uses Apple's on-device speech recognition instead.
  That engine still sends `partial` text while the user speaks, as in version 1.
  The page does not choose the engine; each `state: "listening"` event says which engine runs.
- The dictation settings are app-wide and shared by both chats: the model (`accurate` or `fast`), the language (`auto` or a fixed language), and one list of custom words.
  Pages read and write them through the bridge.
- A recording stops by itself after 10 minutes (`recordingLimitSeconds` in the settings), and is then transcribed.

## Detection and compatibility rules

At document start, in the main frame of every Zeus page, the app sets:

```js
window.zeusApp.speech = { version: 2 }
```

The object is frozen.
A page that sets its own `window.zeusApp` keeps `speech` (the app adds it back).

Compatibility rules:

1. The version is a single integer that changes only when the meaning of an existing message or event changes.
   New message types, new event types, and new fields in an event do not change the version.
2. A page must ignore event types and fields that it does not know.
3. A page that supports only version 1 (it checks `version === 1`) shows no dictation control in an app with version 2.
   This is intended: a version 1 page cannot wait for text that comes after Stop, so it would lose dictated words.
4. A page that supports version 2 must check `version >= 2`, and must work with both engines (`whisper` and `apple`).
5. In an app with version 1 (`version === 1`), a version 2 page can fall back to the version 1 behaviour, or show no dictation control.
   Version 1 has only the messages `speech-languages`, `speech-start`, `speech-stop`, and the events `languages`, `state` (`listening` and `stopped`), `partial`, `final`, and `error`.
6. All messages from version 1 keep their names and fields in version 2.
   A start with a `locale` still works (see `speech-start`).

## Transport

- Page to app: `window.webkit.messageHandlers.zeusApp.postMessage(message)`, where `message` is a plain object with a `type` that starts with `speech-`.
  Only the main frame of a page on `127.0.0.1` or `localhost` can post; the app ignores other frames and other hosts.
  A same-origin editor frame relays its messages through the top page, as in version 1.
- App to page: the app calls `window.zeusSpeech?.onEvent?.(event)` in the page's main frame.
  The page defines `window.zeusSpeech = { onEvent(event) { ... } }`.
- Events of a recognition (`state`, `level`, `partial`, `final`, `error`) go only to the page that started it.
- `status` and `settings` events go to every page that has posted at least one speech message, so that both chats stay in step.
  A page that wants these events from the start posts `speech-status` and `speech-settings` when it loads.

## Sessions

- A page starts a session with an `id` of its choice (a non-empty string, unique within the page).
- One session runs in the whole app at a time, from its start until its `stopped` state, including the time while Whisper processes.
  A start during that time gets the error `busy`.
- After `state: "listening"`, a session always ends with `state: "stopped"`.
  The `final` text (or an `error`) comes before `stopped`.
- An error before `listening` (for example `permission-denied` or `busy`) is the only answer to that start: no `stopped` follows.
- Events with an `id` that is not the page's current session are stale; the page must ignore them.
- The page must keep its session until `stopped`.
  Do not reset the session on a timer while the state is `processing`; Whisper processing can take several seconds for long recordings.

Typical Whisper session:

```text
page -> app   {type: "speech-start", id: "d1"}
app  -> page  {type: "state", id: "d1", state: "listening", engine: "whisper"}
app  -> page  {type: "level", id: "d1", level: 0.42}         (about 20 per second)
page -> app   {type: "speech-stop", id: "d1"}
app  -> page  {type: "state", id: "d1", state: "processing"}
app  -> page  {type: "final", id: "d1", text: "Show the Celonis process.", engine: "whisper"}
app  -> page  {type: "state", id: "d1", state: "stopped"}
```

Typical Apple fallback session (model not ready):

```text
page -> app   {type: "speech-start", id: "d2"}
app  -> page  {type: "state", id: "d2", state: "listening", engine: "apple"}
app  -> page  {type: "partial", id: "d2", text: "Show the"}
page -> app   {type: "speech-stop", id: "d2"}
app  -> page  {type: "final", id: "d2", text: "Show the Celonis process.", engine: "apple"}
app  -> page  {type: "state", id: "d2", state: "stopped"}
```

The Apple engine sends no `level` and no `processing`.

## Messages from the page

| Message | Fields | Answer |
| --- | --- | --- |
| `speech-start` | `id` (string, required); `locale` (optional, see below) | `state: "listening"`, or an `error` |
| `speech-stop` | `id` | Whisper: `state: "processing"`, then `final`, then `stopped`. Apple: `final`, then `stopped` |
| `speech-cancel` | `id` | `{type: "state", id, state: "stopped", cancelled: true}` at once; no `final` |
| `speech-status` | none | `status` event |
| `speech-settings` | none | `settings` event |
| `speech-settings-set` | any of `model`, `language`, `customWords` | After a change, a `settings` event to every page. The sender always gets a `settings` event; it has an `error` field when a value is not valid |
| `speech-model-download` | `model`: `"accurate"` or `"fast"` | `status` events with the download progress |
| `speech-model-cancel` | `model`: `"accurate"` or `"fast"` | `status` event with the state `cancelled` |
| `speech-languages` | none | `languages` event (version 1 message, still available) |

Details:

- `speech-start` `locale`: omit it or send `null` to use the language of the settings (the normal case in version 2).
  A version 1 BCP-47 id such as `"fr-FR"` is still accepted: Whisper uses its language code (`fr`), and Apple uses that locale.
  `"auto"` means auto-detection.
- `speech-stop` and `speech-cancel` with an `id` that is not the current session of this page do nothing.
- `speech-cancel` stops the microphone or the Whisper processing at once and discards the audio.
  Use it for Escape or for a frame that goes away.
- `speech-settings-set` applies only the fields that it has.
  `model` must be one of the `models[].role` values of the settings.
  `language` must be `"auto"` or one of the `allLanguages` ids that `settings` lists (see below); the value is kept also when the selected model does not have it.
  `customWords` is the complete new list (an array of strings); the app trims each word, removes empty words and repeats (case-insensitive), cuts each word to 64 characters, and keeps at most 200 words.
  An invalid `model` or `language` is ignored; the other fields still apply.
- `speech-model-download` starts the download of that model now, also after a failure or a cancel.
  The app downloads the model of the selected role by itself; this message is for a "Retry" or "Download" button.

## Events to the page

### `state`

```js
{ type: "state", id, state: "listening", engine: "whisper" | "apple" }
{ type: "state", id, state: "processing", reason?: "limit" }
{ type: "state", id, state: "stopped", cancelled?: true }
```

- `processing` comes only from Whisper, after `speech-stop`, after the app stopped the session (see "App-side stops"), or after the 10-minute limit (`reason: "limit"`).
  Show "Transcribing..." in this state.
- `cancelled: true` is present only in the answer to `speech-cancel`.

### `level`

```js
{ type: "level", id, level: 0.0 ... 1.0 }
```

The loudness of the microphone: 0 is -50 dBFS or quieter, 1 is 0 dBFS.
About 20 events per second, only from Whisper, only while `listening`.

### `partial` and `final`

```js
{ type: "partial", id, text }                              // Apple only
{ type: "final", id, text, engine: "whisper" | "apple" }
```

`final` is the complete text of the session.
It can be an empty string (silence).
With `partial`, each event has the complete text so far; replace, do not append.

### `error`

```js
{ type: "error", id, code, message }
```

| `code` | Meaning |
| --- | --- |
| `permission-denied` | No microphone permission (Whisper and Apple), or no speech recognition permission (Apple only) |
| `no-on-device` | Apple only: this Mac cannot recognize the language on the Mac |
| `unavailable` | No microphone, or the recognizer is not available now |
| `busy` | Another session runs in the app (also while it processes) |
| `failed` | The recognition or the Whisper processing failed |

`message` is a full English sentence that the page can show.

### `status`

```js
{
  type: "status",
  engine: "whisper" | "apple",      // the engine that a start uses now
  selected: "accurate" | "fast",   // the model role of the settings
  active: { role, id, name } | null, // the Whisper model that is loaded now
  runtime: "idle" | "loading" | "ready" | "failed",
  loading?: "<model id>",           // with runtime "loading"
  runtimeError?: "<text>",          // with runtime "failed"
  models: [
    {
      role: "accurate" | "fast",
      id, name, description, license,
      bytes,                         // the download size
      multilingual: true | false,
      languages?: ["en"],            // only for a model that is not multilingual
      installed: true | false,       // this model is the role's model on this Mac now
      state: "missing" | "downloading" | "verifying" | "ready" | "failed" | "cancelled",
      received?, total?,             // with state "downloading" (bytes)
      error?,                        // with state "failed": a full sentence
      retryAt?                       // with state "failed": when the app tries again (ms since 1970)
    }
  ]
}
```

- The app sends `status` after each change (download progress at most four times a second, model loads, settings changes).
- `engine` is `apple` until a Whisper model is loaded.
- `active` can differ from `selected`: after the user picks a model that is not downloaded yet, the loaded model stays in use until the new one is ready.
  After an app update that changes a model, the old model stays in use until the new one is downloaded and loaded.
- `state: "ready"` means the file is on the Mac and checked; `runtime: "ready"` with `active.role === selected` means it is loaded.

### `settings`

```js
{
  type: "settings",
  model: "accurate" | "fast",
  models: [{ role, name, description }],
  language: "auto" | "<code>",            // as the user chose it
  effectiveLanguage: "auto" | "<code>",   // what the selected model uses (the Fast model is English only)
  languages: [{ id, name }],              // the choices for the selected model; "auto" first for a multilingual model
  allLanguages: [{ id, name }],           // every language that a setting can have
  customWords: ["Celonis", "PQL", ...],
  prompt: {
    limit: 100,        // the token budget of the custom words
    tokens,            // the tokens that the included words use
    included,          // the number of words, from the start of the list, that go to the model
    total,             // the number of words in the list
    estimated          // true when no model is loaded and the count is a guess
  },
  recordingLimitSeconds: 600,
  error?: "<text>"     // only to the sender of an invalid speech-settings-set
}
```

- Language ids are Whisper language codes (`en`, `fr`, `de`, `nl`, ...), not BCP-47 locales.
  Names are in the language of the Mac.
- When `included < total`, the words after the first `included` words do not reach the model.
  Show that to the user.
- Custom words are a hint for spelling and context, not a guarantee.

### `languages` (version 1 message)

```js
{ type: "languages", engine, locales: [{ id, name, onDevice: true }], default }
```

With Whisper, the ids are Whisper language codes, with `{id: "auto", name: "Auto-detect"}` first for a multilingual model, and `default` is the setting.
With Apple, the ids are BCP-47 locales, as in version 1.
New pages use `settings` instead.

## App-side stops and cancels

The app stops or cancels a session by itself in these cases:

| Case | What the app does | Events to the page |
| --- | --- | --- |
| The page's chat tab goes out of view (another tab, or a Zeus Editor tab goes out of view) | Stop | Whisper: `processing`, `final`, `stopped`; Apple: `final`, `stopped` |
| 10 minutes of recording | Stop | `processing` with `reason: "limit"`, `final`, `stopped` |
| The page reloads or goes to another page, its window or tab closes, its web process ends, or the app quits | Cancel | None; the audio and any Whisper processing are discarded |

A page that hides a frame and still exists keeps its session and gets its `final` text.
A page that removes a frame posts `speech-cancel` first, or loses the result.

## Send while dictating

Whisper text arrives after Stop.
A Send action during a session must post `speech-stop`, wait for `final` (or `error`) and `stopped`, insert the text, and only then send.
A Send that cancels the session loses the dictated words.

## Permissions

- Whisper needs only the microphone permission.
  The app asks at the first start of a session.
- Apple's engine also needs the speech recognition permission.

## Model files

The app downloads the models to `~/Library/Application Support/io.github.theo-henry.zeus/whisper-models/`.
See [dictation-models.md](dictation-models.md) for the model list and how a maintainer changes a model.
