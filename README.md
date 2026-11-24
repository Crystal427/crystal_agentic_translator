# Crystal Agentic Translator for macOS

Native SwiftUI desktop application for translating long-form `.txt` fiction with a separate controller and translation model served by LM Studio. The app contains the project workflow in-process; it does not host a web UI or a FastAPI server.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or later)
- LM Studio with its local server enabled and the selected controller/translator models installed

## Build and run

```sh
swift test
swift run CrystalTranslator
```

Create an ad-hoc-signed `.app` bundle and a ZIP archive:

```sh
./scripts/package-macos-app.sh
open dist/CrystalTranslator.app
```

The script also creates `dist/CrystalTranslator-macOS.zip`. To choose a different output directory, pass it as the first argument. It builds a release executable, copies it into the app bundle, applies an ad-hoc signature, and uses `ditto` to archive the bundle while preserving macOS metadata and executable permissions. This is for local use; Developer ID signing and notarization are not configured.

## Use

1. Start the LM Studio local server. The default URL is `http://127.0.0.1:1234`.
2. In the app, open **Settings**, test the connection, and select available controller and translator models. Defaults match the design document (`hemmingway-1.5-i1` and `index-translate-9b`).
3. Import one or more `.txt` files. Choose whether they are one continuous work or separate jobs.
4. Start the task. The app creates an outline, scouts each batch, translates, runs deterministic checks, asks the controller to review, retries failures, and writes merged partial output as it goes. Pause/resume, review, editing, and retranslation are available in the app.

## Queue and activity

Tasks explicitly added to the run queue execute serially in FIFO order. A normal completion drains the queue; a user pause stops the drain and leaves remaining jobs queued until **Run Queue** is explicitly selected. Jobs awaiting guide confirmation are not silently restarted. Queue order is held in memory and does not survive relaunch. Job data and per-job `events.log` files are persisted; selecting a job reloads its log, while live activity and model streams are scoped to the selected job.

Text normalization preserves source content after normalizing line endings, removing trailing line whitespace, and compressing runs of four or more blank lines to three. UTF-8/UTF-16 BOMs are honored; UTF-8, GB18030, Shift-JIS, and Windows-1252 are fallback decoders. New-task chunk size defaults to 8,192 characters.

## Persistence

Settings and resumable projects are stored in:

```text
~/Library/Application Support/CrystalAgenticTranslator/
  settings.json
  jobs/<job-id>/
    job.json
    source/
    chunks/
    guide.json
    guide.md
    memory.md
    memory/<chunk-index>.md
    output/<file-index>-<source-name>.zh.txt
    events.log
```

The local job directory is not synchronized to a server. Keep backups of original files and project data.

## LM Studio API integration

The client uses LM Studio's documented native v1 management routes:

- `GET /api/v1/models`
- `POST /api/v1/models/load` with `model` and `context_length`
- `POST /api/v1/models/unload` with `instance_id`

Inference uses the documented OpenAI-compatible `POST /v1/chat/completions` endpoint with streaming and JSON-schema response formats for controller tasks. Translator requests explicitly send `reasoning_effort: "none"` as specified by the design. Model management is only called when a user runs a task; the app does not download models or modify LM Studio configuration. With `swap` scheduling, it unloads only the configured counterpart model instances, never unrelated loaded models.

Plain HTTP is accepted only for loopback LM Studio hosts; remote servers must use HTTPS. Base URLs containing embedded credentials, a query, or a fragment are rejected.

Official documentation:

- [LM Studio REST API](https://lmstudio.ai/docs/developer/rest)
- [List models](https://lmstudio.ai/docs/developer/rest/list)
- [Load a model](https://lmstudio.ai/docs/developer/rest/load)
- [Unload a model](https://lmstudio.ai/docs/developer/rest/unload)
- [Chat completions](https://lmstudio.ai/docs/developer/openai-compat/chat-completions)
- [Structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output)

The current settings UI assumes the default unauthenticated local LM Studio server; it does not yet expose a bearer-token field. A server configured to require authentication cannot be used until token entry is added.

## CI

`.github/workflows/macos.yml` runs the regression suite on macOS, packages the app, and uploads `CrystalTranslator-macOS.zip` for pushes, pull requests, and manual runs. The ZIP preserves the app bundle's executable permissions when downloaded.

## Verification boundary

Automated tests use a controlled in-process LM Studio transport. They validate request paths/payloads and pipeline state transitions without a live LM Studio process or real model inference. Model quality, long-context behavior, live model loading, and real-world QA thresholds remain unverified and should be evaluated on representative books before relying on unattended output. The current settings UI does not expose a bearer-token field; authenticated LM Studio servers cannot be used. Pending queue order is not persisted across app relaunch, and Developer ID signing/notarization are not configured.
