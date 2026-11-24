# Crystal Agentic Translator for macOS

Native SwiftUI desktop application for translating long-form `.txt` fiction with a separate controller and translation model served by LM Studio or GLM Coding Plan. The app contains the project workflow in-process; it does not host a web UI or a FastAPI server.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or later)
- Either LM Studio with its local server enabled and the selected models installed, or access to GLM Coding Plan

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

1. In **Settings**, select LM Studio or GLM Coding Plan. LM Studio uses `http://127.0.0.1:1234` by default; GLM uses the Coding Plan endpoint and `glm-5.3-flash`.
2. For GLM, enter the API key in Settings; it is stored in macOS Keychain, not `settings.json`. Test the connection and select controller and translator models. LM Studio defaults match the design document (`hemmingway-1.5-i1` and `index-translate-9b`).
3. Import one or more `.txt` files. Choose whether they are one continuous work or separate jobs.
4. Start the task. The app creates an outline, scouts each batch, translates, runs deterministic checks, asks the controller to review, retries failures, and writes merged partial output as it goes. Pause/resume, review, editing, and retranslation are available in the app.

## Queue and activity

Tasks explicitly added to the run queue execute serially in FIFO order. A normal completion drains the queue; a user pause stops the drain and leaves remaining jobs queued until **Run Queue** is explicitly selected. Jobs awaiting guide confirmation are not silently restarted. Queue order is held in memory and does not survive relaunch. Job data and per-job `events.log` files are persisted; selecting a job reloads its log and its own latest activity/output is retained in memory for the current app session. After relaunch, the compact window falls back to the persisted job status until new live activity arrives. The main app uses one reusable window; the compact window can reopen it after it is closed.

Text normalization preserves source content after normalizing line endings, removing trailing line whitespace, and compressing runs of four or more blank lines to three. UTF-8/UTF-16 BOMs are honored; UTF-8, GB18030, Shift-JIS, and Windows-1252 are fallback decoders. New-task chunk size defaults to 8,192 characters. Short final chunks are retained as produced rather than rebalanced into earlier chunks.

The controller refines the outline across every source window in order, reserving context for the accumulated guide and model output. Completed windows are checkpointed so interrupted planning can resume. Explicit chapter, numbered-section, and divider markers are retained as source offsets and attached to translation chunks; unmarked prose is not assigned invented section titles.

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
  workspace-diary.jsonl
  workspace-diary.1.jsonl
  workspace-diary.2.jsonl
```

The local job directory is not synchronized to a server. Keep backups of original files and project data.

## Model API integration

The client uses LM Studio's documented native v1 management routes:

- `GET /api/v1/models`
- `POST /api/v1/models/load` with `model` and `context_length`
- `POST /api/v1/models/unload` with `instance_id`

Inference uses the documented OpenAI-compatible `POST /v1/chat/completions` endpoint with streaming and JSON-schema response formats for controller tasks. Translator requests explicitly send `reasoning_effort: "none"` as specified by the design. Model management is only called for LM Studio when a user runs a task; GLM uses the configured URL prefix and does not receive LM Studio model list/load/unload calls. GLM Coding Plan requests use Bearer authentication and JSON-object response mode; credentials are kept in Keychain and omitted from encoded settings. With LM Studio `swap` scheduling, the app unloads only the configured counterpart model instances, never unrelated loaded models.

Plain HTTP is accepted only for loopback hosts; remote servers must use HTTPS. Base URLs containing embedded credentials, a query, or a fragment are rejected. The workspace diary records operational statuses and errors with timestamps, rotates its JSONL files, and redacts credential patterns.

Official documentation:

- [LM Studio REST API](https://lmstudio.ai/docs/developer/rest)
- [List models](https://lmstudio.ai/docs/developer/rest/list)
- [Load a model](https://lmstudio.ai/docs/developer/rest/load)
- [Unload a model](https://lmstudio.ai/docs/developer/rest/unload)
- [Chat completions](https://lmstudio.ai/docs/developer/openai-compat/chat-completions)
- [Structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output)
- [GLM Coding Plan quick start](https://docs.bigmodel.cn/cn/coding-plan/quick-start)
- [GLM-5.3-Flash](https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash)


## CI

`.github/workflows/macos.yml` runs the regression suite on macOS, packages the app, and uploads `CrystalTranslator-macOS.zip` for pushes, pull requests, and manual runs. The ZIP preserves the app bundle's executable permissions when downloaded.

## Verification boundary

Automated tests use controlled in-process transports. They validate request paths/payloads and pipeline state transitions without a live LM Studio process or real model inference. Model quality, long-context behavior, live model loading, and real-world QA thresholds remain unverified and should be evaluated on representative books before relying on unattended output. Pending queue order is not persisted across app relaunch, and Developer ID signing/notarization are not configured.
