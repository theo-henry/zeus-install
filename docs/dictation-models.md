# Dictation models (maintainer)

Zeus dictation runs Whisper models on the Mac with whisper.cpp.
Each Zeus app release carries its model list in `app/Resources/dictation-models.json`.
When a release changes the list, each Mac gets the new model by itself at the next start of Zeus.

## How the app uses the model list

- The list has one model for each role.
  The roles are the choices of the dictation settings: `accurate` (the default, `defaultRole`) and `fast`.
- The app downloads the model of the role that the user selected, and keeps every role that this Mac already has up to date.
  Downloads go to `~/Library/Application Support/io.github.theo-henry.zeus/whisper-models/<id>.bin`, outside the app, so an app update does not download a model again.
- A download goes to a temporary file first.
  The app checks its size (`bytes`) and its SHA-256 (`sha256`), then renames it in one step.
  A failed check deletes the file; the app tries again after 30 s, 2 min, 10 min, 30 min, and then each hour.
- `installed.json` in that folder records the model of each role that is in use.
- When the model of a role changes (a new `id`), the old model stays in use until the new model is downloaded, checked, and loaded.
  Then the app deletes the old file.
  A new model that does not load is deleted, and the old model stays in use.
- The model of the selected role loads in the background about 2 s after the app starts, and stays loaded.
  Until a model is loaded, dictation uses Apple's speech recognition.

## Model list fields

| Field | Meaning |
| --- | --- |
| `version` | The format of the file. Only `1` exists. |
| `defaultRole` | The role of a user who never changed the setting. |
| `models[].id` | A unique, stable name. A new file (another model, quantization, or revision) needs a new id. The file name on the Mac is `<id>.bin`. |
| `models[].role` | `accurate` or `fast`. Exactly one model for each role. |
| `models[].engine` | The code that runs the model. Only `whisper` (whisper.cpp ggml files) exists. |
| `models[].name`, `description` | The text in the settings. |
| `models[].url` | The download link, pinned to one revision (a Hugging Face commit, never `main`). |
| `models[].bytes` | The exact size of the file. |
| `models[].sha256` | The SHA-256 of the file, in lowercase hex. |
| `models[].multilingual` | `true` for a multilingual model. |
| `models[].languages` | For a model that is not multilingual: its Whisper language codes, for example `["en"]`. |
| `models[].license`, `source` | The license of the model file and where it comes from. Add its notice to `app/Resources/THIRD-PARTY-NOTICES.md`. |

## Replace a model

1. Pick the file on Hugging Face and its commit:

   ```bash
   curl -s https://huggingface.co/api/models/ggerganov/whisper.cpp/revision/main | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
   curl -s https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main | python3 -c '
   import json,sys
   for f in json.load(sys.stdin):
       if f["path"].endswith(".bin"): print(f["path"], f["size"], (f.get("lfs") or {}).get("oid"))'
   ```

   The LFS `oid` is the SHA-256 of the file.
2. In `app/Resources/dictation-models.json`, change the model of the role: a new `id`, the `url` with the commit in place of `main`, `bytes`, `sha256`, `multilingual`, `languages`, `name`, `description`, `license`, and `source`.
3. Check the license of the new file.
   A permissive license of whisper.cpp does not cover every model file.
   Add the notice to `app/Resources/THIRD-PARTY-NOTICES.md`.
4. Download the file once and check it:

   ```bash
   curl -L -o /tmp/model.bin '<url>'
   stat -f %z /tmp/model.bin
   shasum -a 256 /tmp/model.bin
   ```

5. Build and test the app, then release it (`app/release.sh`).
   At the next start, each Mac downloads the new model in the background, switches to it when it loads, and deletes the old one.

To add a role (for example a third choice), add a model with the new `role`; the settings show it at once.
Removing a role from the list removes its model from each Mac.

## A model that needs other code

A model that whisper.cpp cannot load (for example another model family) needs a new `engine` value and its code:

1. Add a class that conforms to `Transcriber` in `app/Sources/Zeus/Dictation/DictationRuntime.swift`.
   It loads the file, counts the tokens of a text, and turns 16 kHz mono Float32 samples into text.
2. Add its `engine` value to `DictationRuntime.makeTranscriber`.
3. Release the code and the model list together.
   The model list is part of the app, so an app never gets a model whose engine it does not have.

## whisper.cpp

`app/Package.swift` pins whisper.cpp 1.9.3 (commit `371b5a7561823ab2bb32142d2751e35e7534727b`) through the `whisper-b4938-xcframework.zip` of the whisper.cpp release `b4938`, with its SHA-256.
SwiftPM downloads it at the first build.
`app/build.sh` copies `whisper.framework` into `Zeus.app/Contents/Frameworks` (`app/copy-whisper.sh`).
The framework needs macOS 13.3 or later.

To update whisper.cpp, pick a release with an `xcframework.zip` asset, take its `digest` (SHA-256) from the GitHub API, and change the `url` and `checksum` in `Package.swift`:

```bash
gh api repos/ggml-org/whisper.cpp/releases/tags/<tag> --jq '.assets[] | select(.name|test("xcframework")) | [.name, .digest] | @tsv'
```

The voice detector `app/Resources/ggml-silero-v5.1.2.bin` (Silero VAD 5.1.2, MIT) is in the app.
It comes from `https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin`, SHA-256 `29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`.
