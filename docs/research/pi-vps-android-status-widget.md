# Research: pi on a VPS + Android home-screen status widget

Date: 2026-11-07. Primary sources only; every claim carries a source URL. Verified against live repo/docs/npm on this date.

## Summary (load-bearing findings)

1. **The agent is not at `steipete/pi`.** The pi coding agent lives at [github.com/earendil-works/pi](https://github.com/earendil-works/pi) (moved from `mariozechner/pi-coding-agent`); npm package is [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) (your 0.84.0–0.84.4 are its versions; current latest is 1.5.0). `github.com/steipete/pi` is currently a **fork of badlogic/pi, a GPU pod manager** ([GitHub API](https://api.github.com/repos/steipete/pi): `fork: True, parent: badlogic/pi`), and `@steipete/pi` does not exist on npm.
2. **pi has a first-class RPC mode**: `pi --mode rpc [--no-session]` — JSONL commands on stdin, responses + session events on stdout, long-lived, with ~35 documented commands (`get_state`, `set_model`, `get_available_models`, `prompt`, `steer`, `abort`, `get_session_stats` with tokens/cost/context usage, `switch_session`, …) and full event stream including `message_end` with usage and `agent_settled` ([rpc.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md), [rpc-commands.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md), [json.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)).
3. **pi has NO built-in network server** — no WebSocket/HTTP/daemon mode, no official web UI or mobile app. RPC is stdio-only; a bridge must spawn pi as a child process ([pi.dev](https://pi.dev): "JSON protocol over stdin/stdout for non-Node integrations"). Community web/PWA/Flutter/Matrix clients and a Zed ACP adapter exist around `--mode rpc`.
4. Sessions are append-only JSONL trees at `~/.pi/agent/sessions/--<path>--/<timestamp>_<id>.jsonl`; resumable via `--continue`/`--resume`/`--session`; one active session per pi process; multi-conversation server scenarios are served by the **experimental `@earendil-works/pi-durable`** harness with `watch()` live-state feeds and read-only viewer processes ([session-format.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md), [sessions.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md), [pi-durable README](https://github.com/earendil-works/pi/blob/main/packages/durable/README.md)).
5. Android widget refresh floors: `updatePeriodMillis` **≥30 min**, WorkManager periodic **≥15 min** and Doze-deferrable ([AppWidgetProviderInfo](https://developer.android.com/reference/android/appwidget/AppWidgetProviderInfo#updatePeriodMillis), [PeriodicWorkRequest](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest)).
6. FCM push → widget update is a **documented pattern in the Glance docs** ("update... in response to a Firebase Cloud Messaging (FCM) message"), BUT high-priority messages that never surface a user-facing notification get **downgraded to normal priority** (rolling 7-day per-instance behavior), which breaks wake-ups ([Glance state mgmt](https://developer.android.com/develop/ui/compose/glance/glance-app-widget#when-to-update), [FCM priority](https://firebase.google.com/docs/cloud-messaging/android/message-priority)).
7. A persistent WebSocket foreground service is time-boxed: Android 14 requires the `dataSync` FGS type; **Android 15 enforces ~6 hours of `dataSync` FGS per 24 h** (timer resets on user interaction) ([FGS types](https://developer.android.com/about/versions/14/changes/fgs-types-required), [Android 15 behavior changes](https://developer.android.com/about/versions/15/behavior-changes-15#datasync-timeout)). Doze suspends network and ignores wakelocks ([Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)). Push (FCM) + periodic poll hybrid is the battery-compliant architecture.
8. **Glance is the Compose-first recommendation** for widgets in 2026 — stable **1.2.0 (Aug 2026)**, with 1.3.0-alpha02 current; it compiles to RemoteViews, so RemoteViews limits still apply ([Glance releases](https://developer.android.com/jetpack/androidx/releases/glance), [create-app-widget](https://developer.android.com/develop/ui/compose/glance/create-app-widget)).
9. Prior art: **Claude Code mobile "Remote Control"** (official; phone pairs to a locally-running session, push notifications when a task finishes or a decision is needed) is the closest shipped analog; Omnara has pivoted to a self-hostable agent platform with web/Slack/Discord approval surfaces (no mobile app in its current repo); **Vibe Kanban is sunsetting**; OpenClaw is pi.dev's cited real-world SDK example (gateway on your own server + messaging channels).
10. pi itself documents running **on** Android via Termux (`pkg install nodejs git; npm install -g --ignore-scripts @earendil-works/pi-coding-agent`) and tmux key-setup — the Termux+tmux+SSH workflow is first-party documented ([termux.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/termux.md), [tmux.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/tmux.md)).

---

## 1. pi's programmatic/headless surfaces

### 1.1 Identity of the product (correction to the brief)

- The pi coding agent ("minimal, extensible agent harness") is published by Earendil: repo [github.com/earendil-works/pi](https://github.com/earendil-works/pi) (monorepo, `packages/coding-agent`), site [pi.dev](https://pi.dev), npm [`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) — latest 1.5.0; version list includes **0.84.0–0.84.4**, matching the user's installed ~0.84.x (verified via [npm registry](https://registry.npmjs.org/@earendil-works/pi-coding-agent)).
- The previous npm name [`@mariozechner/pi-coding-agent`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) is deprecated with the message "please use @earendil-works/pi-coding-agent instead going forward" (npm registry metadata).
- `github.com/steipete/pi` is **not** the agent: GitHub API reports it as a fork of `badlogic/pi`, "CLI tool for managing vLLM deployments on Prime Intellect GPU pods" (npm `@badlogic/pi`). `@steipete/pi` returns Not Found on npm. Anyone linking "steipete/pi" for the agent is out of date. Sources: <https://api.github.com/repos/steipete/pi>, <https://raw.githubusercontent.com/steipete/pi/main/README.md>, <https://registry.npmjs.org/@steipete%2Fpi>.
- Config directory is `~/.pi/agent/` as the brief states (sessions, extensions, settings all live there): [settings.md / extensions.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) ("~/.pi/agent/extensions/*.ts", project-local `.pi/extensions/...`).

### 1.2 Modes and CLI entrypoints

There is no `pi agent` subcommand. From [cli.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md) and [cli-integration.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli-integration.md):

| Entrypoint | Behavior |
|---|---|
| `pi` | Interactive TUI (when stdin/stdout are terminals) |
| `pi -p/--print "..."` | Run prompt(s), print final assistant text, exit |
| `pi --mode json "..."` | One-shot; JSONL session events on stdout, then exit |
| `pi --mode rpc [--no-session]` | **Long-lived RPC subprocess**: JSONL commands in on stdin; responses + events out on stdout "until shutdown" |
| `pi --export <input> [output]` | Export a session file to HTML, exit |
| `pi install/remove/uninstall/update/list/config` | Package (extension/skill/theme) management |
| `pi auth login/logout/check ...` | Provider credentials |
| `pi mcp add/remove/list/login/logout` | MCP client config |

"All four modes use the same agent, sessions, resources, and tools. The mode determines how input enters Pi, how output is exposed, and whether the process remains available for more commands." ([cli-integration.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli-integration.md))

### 1.3 RPC mode (the headless/control surface)

Source: [rpc.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md), [rpc-commands.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md), [json.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md). Start: `pi --mode rpc --no-session`. "RPC mode runs Pi as a long-lived subprocess controlled through JSON records on stdin and stdout."

**Protocol properties (rpc.md):**
- Strict JSONL framing (one JSON object per line, LF-terminated; Node `readline` is explicitly unsuitable because it splits on U+2028/U+2029). Stdout is protocol-only; diagnostics go to stderr.
- Commands carry an optional `id`; responses repeat it. Session events generally have no command id (`bash_execution_update` is the exception).
- Lifecycle: a successful `prompt` response only means accepted/queued/handled (`data.disposition`); "Wait for `agent_settled` when the client needs to know Pi will not continue automatically."
- Shutdown: close stdin, or SIGTERM/SIGHUP → orderly shutdown; second signal kills immediately.
- Maintained TS client: `RpcClient` ([rpc-client.ts](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-client.ts)) "starts Pi, correlates responses, exposes typed command methods"; protocol types in [rpc-types.ts](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts).

**Commands (complete list, rpc-commands.md):** `prompt` (with `streamingBehavior: "steer"|"followUp"`, images), `steer`, `follow_up`, `abort`, `clear_queue`, `new_session`, `get_state` (model, isStreaming, isCompacting, sessionFile/Id/Name, messageCount, pendingMessageCount), `get_messages`, `set_model`, `cycle_model`, `get_available_models`, `set_thinking_level`, `cycle_thinking_level`, `get_available_thinking_levels`, `set_steering_mode`, `set_follow_up_mode`, `compact`, `set_auto_compaction`, `set_auto_retry`, `abort_retry`, `bash` (streams `bash_execution_update`, result enters model context on next prompt), `abort_bash`, `get_session_stats`, `export_html`, `switch_session`, `fork`, `clone`, `get_fork_messages`, `get_entries` (append-order entries with `since` cursor + `leafId`, "so an entry id works as a durable cursor... even across client restarts"), `get_tree`, `get_last_assistant_text`, `set_session_name`, `get_commands`.

**`get_session_stats` returns exactly the data a status widget needs** (rpc-commands.md): message counts, `tokens {input, output, cacheRead, cacheWrite, total}`, `cost`, and `contextUsage {tokens, contextWindow, percent}`.

**Events (json.md, shared by JSON + RPC):** `agent_start`, `agent_end`, `agent_settled`, `turn_start`, `turn_end`, `message_start`, `message_update` (carries top-level cumulative `usage` incl. cost), `message_end` ("the authoritative final message" — assistant messages record usage/model), `tool_execution_start/update/end` (with `durationMs`), `queue_update`, `entry_appended`, `session_info_changed`, `thinking_level_changed`, `compaction_start/end`, `auto_retry_start/end`, `summarization_retry_*`, plus RPC-only `bash_execution_update` and `extension_error`.

**Extension UI over RPC** ([rpc-extension-ui.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)): extension `ctx.ui` dialogs (`select`, `confirm`, `input`, `editor`) become `extension_ui_request`/`extension_ui_response` records — this is how a bridge would render approve/deny prompts; `notify`/`setStatus`/`setWidget` are fire-and-forget. TUI-only methods are no-ops in RPC.

### 1.4 SDK, agent-core, and pi-durable (server-side scenarios)

- **SDK** ([sdk.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)): `createAgentSession()` embeds the agent in Node/Bun with typed events, `prompt()/steer()/followUp()/abort()`, and `AgentSessionRuntime` adding `newSession()/switchSession()/fork()/importFromJsonl()`. 14 typechecked examples in-repo.
- **`@earendil-works/pi-agent-core`** ([packages/agent README](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md)): the stateful agent library underneath (event flow, tool execution, hooks) — for hosts building their own harness.
- **`@earendil-works/pi-durable`** ([packages/durable README](https://github.com/earendil-works/pi/blob/main/packages/durable/README.md)) — flagged **"Experimental. The API changes without notice between releases."** This is the closest thing to a server-side multi-session daemon in the pi ecosystem: durable conversations in SQLite/JSONL; `harness.resume()` continues runs a crashed process left unfinished; **`watch()` returns a live structural view ("its value at attachment, then each commit that touches it")** including `pi.live` (running generation, tool calls, retry, runFailure), `pi.inbox`, `pi.usage`; **busy conversations queue steers/follow-ups** (`whenBusy: "steer"` etc.); `watchTaskGraph()` watches every live task; a second process can open storage `readOnly: true` (a pure viewer). This maps 1:1 onto "VPS runs agents, phone watches status" — but it is experimental and not part of the `pi` CLI.

### 1.5 Sessions: files, resume/attach semantics, multi-session

Sources: [sessions.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md), [session-format.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md), [cli.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md).

- Storage: `~/.pi/agent/sessions/--<path>--/<timestamp>_<session-id>.jsonl`, grouped by working directory; override with `--session-dir`, `PI_CODING_AGENT_SESSION_DIR`, or the `sessionDir` setting; `--no-session` for ephemeral runs ("An ephemeral session cannot be resumed after Pi exits").
- Format: versioned JSONL (v3), append-only **tree** of entries (`id`/`parentId`) — messages, `model_change`, `thinking_level_change`, `usage`, `compaction`, `branch_summary`, `context_edit`, `custom`, `custom_message`, `label`, `session_info`. The docs include a parsing example and say "Sessions can be removed by deleting their .jsonl files."
- Resume: `--continue` (most recent for the cwd), `--resume` (picker), `--session <path|id>`, `--session-id <id>`, `--fork`. "Each session records the working directory it was created in and never changes it."
- **Tailing from an external process while a TUI is attached: not documented.** The file format is fully specified and plain JSONL (so an external `tail -f`-style reader can parse new lines), but pi's docs describe no watch/lock/notification mechanism for concurrent readers, and no way for a second process to *attach to* a running interactive pi. What the docs DO sanction: run pi itself under `--mode rpc` and consume events, or use the RPC `get_entries` + `since` cursor "across client restarts". Two processes writing one session concurrently is not described as supported anywhere I could find.
- **Multi-session:** one active session per pi process (RPC `new_session`/`switch_session`/`fork`/`clone` swap it; SDK `AgentSessionRuntime` recreates services per switch). Multiple pi processes with separate session files are the natural multi-agent pattern; `pi-durable` is the single-process, multi-conversation alternative (§1.4).

### 1.6 Extension/plugin API

Source: [extensions.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) (158 KB; read in part).

- Extensions are TypeScript/JS files auto-discovered from `~/.pi/agent/extensions/` or `.pi/extensions/` (post project trust), loaded in-process via jiti. Security note verbatim: "Extensions run with your full system permissions and can execute arbitrary code."
- They can register tools, commands, shortcuts, flags, providers; subscribe to session/agent/tool/model events; and use Node built-ins ("Node.js built-ins (`node:fs`, `node:path`, etc.) are also available") plus npm dependencies.
- `ctx.mode` reports `"tui" | "rpc" | "json" | "print"`, so an extension can behave differently per mode — including opening **sockets**, though the docs instruct: "Do not start background resources such as processes, sockets, file watchers, or timers from the factory. Defer background resource startup until `session_start`."
- **Attach direction:** a bridge does not attach to a running interactive pi; pi is either embedded (SDK), spawned under the bridge (`--mode rpc`), or the extension itself hosts the outbound connection from inside any mode. There is no documented external attach/injection API for an already-running TUI instance.
- Remote execution: built-in tools support "pluggable operations for delegating to remote systems (SSH, containers, etc.)" (extensions.md "Remote Execution"; example `ssh.ts` in the examples table).

### 1.7 Remote clients / web UIs / mobile — built-in vs ecosystem

- **Built into pi: none.** No network server mode exists (modes are text/json/rpc/print only — [cli.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)); [pi.dev](https://pi.dev) describes RPC as "JSON protocol over stdin/stdout for non-Node integrations" and mentions no web/mobile surface. The closest built-in remote features: `/share` uploads a finished session as a **read-only viewer link** (GitHub gist or Radius artifact) ([sessions.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md)), and pi runs *on* Android via Termux (§3.5).
- **Ecosystem (all wrap `--mode rpc` or the SDK; found via GitHub search 2026-11-07):**
  - [imrj05/orbit](https://github.com/imrj05/orbit) — native desktop workbench for pi (Rust GUI).
  - [spongioblast/spopi](https://github.com/spongioblast/spopi) — desktop GUI around `pi --mode rpc`.
  - [oopjoy/Pi-Chat](https://github.com/oopjoy/Pi-Chat) — "local-first Web/PWA client for the Pi coding agent — conversation UI over Pi RPC".
  - [saltysalrua/pi-gui-flutter](https://github.com/saltysalrua/pi-gui-flutter) — Flutter GUI over Pi RPC, multi-session/multi-project.
  - [Hi-Barry/pi-courier](https://github.com/Hi-Barry/pi-courier) — run pi from Matrix chat via the RPC protocol.
  - [svkozak/pi-acp](https://github.com/svkozak/pi-acp) — ACP adapter (Zed editor integration).
  - [qiz029/pi-agent-go](https://github.com/qiz029/pi-agent-go) — Go SDK for the RPC protocol.
  - [KristjanPikhof/Pi-Agents-Team](https://github.com/KristjanPikhof/Pi-Agents-Team) — extension spawning background RPC worker agents.
  - A community "self-updating Web UI built for Pi... monitor and interact with multiple agent sessions from anywhere, especially on mobile" was announced on r/PiCodingAgent ([thread](https://www.reddit.com/r/PiCodingAgent/comments/1v0tuar/web_ui_for_pi_and_other_agents)) — community, not first-party.
  - [pi.dev](https://pi.dev) cites **OpenClaw** as "a real-world example" of the SDK (see §3.4).

---

## 2. Android home-screen widget live-status mechanics

### 2.1 Update paths and their floors

- **`updatePeriodMillis` (static, in AppWidgetProviderInfo XML):** "Updates requested with `updatePeriodMillis` will not be delivered more than once every 30 minutes." ([AppWidgetProviderInfo reference](https://developer.android.com/reference/android/appwidget/AppWidgetProviderInfo#UPDATE_PERIOD_MILLIS) — field `updatePeriodMillis`). It drives `onUpdate()` broadcasts; not suitable for live status.
- **WorkManager periodic:** "Periodic work has a minimum interval of 15 minutes" (`MIN_PERIODIC_INTERVAL_MILLIS`; flex interval also has a minimum, `MIN_PERIODIC_FLEX_MILLIS`), and "execution may be delayed because WorkManager is subject to OS battery optimizations, such as doze mode." ([PeriodicWorkRequest reference](https://developer.android.com/reference/androidx/work/PeriodicWorkRequest))
- **Glance's official "When to update widgets" guidance** (state-management page, [§When to update widgets](https://developer.android.com/develop/ui/compose/glance/glance-app-widget#when-to-update-widgets)):
  - Immediate, while the app is awake: "when... your user interacts with your app in the foreground, or **while the app is already updating in response to a Firebase Cloud Messaging (FCM) message or a broadcast**" → call `GlanceAppWidget.update(context, glanceId)` / `updateAll(context)`.
  - Periodic: "Use `updatePeriodMillis`... up to once every 30 minutes. Use WorkManager to schedule more frequent updates, such as every 15 minutes."
  - "Avoid updating your widget every minute when the app isn't awake."
- **Push via FCM high priority — supported but conditioned.**
  - The widget-update-on-FCM pattern itself is documented (Glance quote above).
  - Android 12+ angle: receiving a high-priority FCM message is an official exemption from the background foreground-service-start restriction — "Your app receives a high priority message using Firebase Cloud Messaging" — but with the caveat: "The system can downgrade the high priority messages to normal priority **if the app is not using the high priority messages for surfacing time sensitive content to the user**. If the message's priority is downgraded, your app cannot start a foreground service." ([FGS background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start#background-start-restriction-exemptions))
  - FCM's own priority doc: high priority is for urgent, user-facing content and "generally should result in user interaction with your app or its notifications"; messages that "don't result in user-facing notifications" may be **downgraded per app instance based on ~7 days of behavior** (detectable by comparing `getPriority()` vs `getOriginalPriority()`); for follow-up work use an **expedited WorkManager job** ("a brief exemption for expedited jobs scheduled immediately after a high priority FCM `onMessageReceived`"). ([FCM message priority](https://firebase.google.com/docs/cloud-messaging/android/message-priority))
  - Net: silent widget-only high-priority pushes will eventually be deprioritized; pair pushes with a real notification (or accept best-effort delivery) plus a poll fallback.
- **AppWidgetManager / receiver constraints:** widget providers are broadcast receivers with "strict 10-second background limits"; the classic-widgets guide says "Don't call `Context.startForegroundService` from `AppWidgetProvider.onReceive` or `onUpdate`, which throws `ForegroundServiceStartNotAllowedException` when triggered in the background. Enqueue a WorkManager `CoroutineWorker` instead." ([Glance create-app-widget](https://developer.android.com/develop/ui/compose/glance/create-app-widget) warning box; [App widgets guide](https://developer.android.com/develop/ui/views/appwidgets)). In Glance, updating state requires `updateAppWidgetState` **followed by** `update()` — writing state alone "doesn't automatically recompose your widget or push a new RemoteViews hierarchy to the launcher" ([same page](https://developer.android.com/develop/ui/compose/glance/create-app-widget)). Bitmap memory per widget is capped (`6 * width * height` bytes, enforced on Android 17+) ([appwidgets guide](https://developer.android.com/develop/ui/views/appwidgets)).

### 2.2 Persistent connection vs push+poll

- **Doze** ([doze-standby](https://developer.android.com/training/monitoring-device-state/doze-standby)): when unplugged+stationary+screen-off, the system "restricts apps' access to network and CPU-intensive services... prevents apps from accessing the network and defers their jobs, syncs, and standard alarms"; wakelocks are ignored; JobScheduler (hence WorkManager) doesn't run. Maintenance windows become less frequent over time. FCM is the recommended transport: "FCM provides a single, persistent connection to the cloud... we strongly recommend you use FCM if possible, rather than maintaining your own persistent network connection."
- **Foreground service + WebSocket:** Android 14 requires every FGS to declare a type; a WebSocket listener maps to **`dataSync`** (`FOREGROUND_SERVICE_DATA_SYNC`, "Data transfer operations... Transfer data between a device and the cloud over a network"; runtime prerequisites: none) ([FGS types required](https://developer.android.com/about/versions/14/changes/fgs-types-required#data-sync)).
  - **Android 15 hard quota:** "The system permits an app's `dataSync` services to run for a total of **6 hours in a 24-hour period**, after which the system calls the running service's `Service.onTimeout(int, int)`... The 6-hour time limit is shared by all of an app's `dataSync` foreground services... if the user brings the app to the foreground, the timer resets." Exceeding it → `ForegroundServiceStartNotAllowedException` on next start. ([behavior-changes-15](https://developer.android.com/about/versions/15/behavior-changes-15#datasync-timeout))
  - Also on Android 15: `BOOT_COMPLETED` receivers may no longer launch `dataSync` FGS ([same page](https://developer.android.com/about/versions/15/behavior-changes-15#fgs-boot-completed)), so an auto-restart-on-boot WebSocket service is not available for that type.
  - A dataSync FGS does keep the app out of App Standby ("The app has a process currently in the foreground, either as an activity or foreground service" — [doze-standby](https://developer.android.com/training/monitoring-device-state/doze-standby)), but Doze still suspends network for everyone except exempted apps; battery-optimization exemption requests are Play-policy restricted ("Google Play policies prohibit apps from requesting direct exemption... unless the core function of the app is adversely affected").
- **Conclusion supported by the sources:** a 24/7 WebSocket FGS is not sustainable under Android 15 rules (6 h/day) — the compliant architecture is FCM push (high-priority, ideally with a visible notification) + WorkManager polling (≥15 min) + refresh-on-interaction, which is exactly the hybrid the Glance "when to update" section lays out.

### 2.3 Glance vs RemoteViews in 2026

- **Glance is the Compose-first, currently recommended path.** The app-widgets guide itself now routes metadata/receiver/layout guidance to "the Compose-first... sections in the Glance documentation" and banners "Try the Compose way" ([appwidgets guide](https://developer.android.com/develop/ui/views/appwidgets)).
- **Release status:** stable **1.2.0 released August 26, 2026**; 1.3.0-alpha02 (July 2026) is current alpha; 1.1.1 (Oct 2024) was the prior security-fix line ([Glance releases](https://developer.android.com/jetpack/androidx/releases/glance)).
- **It is still RemoteViews underneath:** "Glance provides a modern approach to build app widgets using Compose, but is restricted by the limitations of `AppWidgets` and `RemoteViews`. Therefore, Glance uses different composables from the Jetpack Compose UI." ([create-app-widget](https://developer.android.com/develop/ui/compose/glance/create-app-widget)). Update model: `GlanceAppWidget.update/updateAll` recompose and re-send RemoteViews to the host; `AndroidRemoteViews` interop exists for anything Glance can't express; receivers are `GlanceAppWidgetReceiver` subclasses in the manifest, same `APPWIDGET_UPDATE` filter, same `AppWidgetProviderInfo` XML (same `updatePeriodMillis` floor).
- For a small text/status widget, Glance (Text/Column/Button, `actionStartActivity`, `actionRunCallback`) covers it; RemoteViews directly remains valid for pure-Views codebases or exotic views.

---

## 3. Prior art (first-party docs)

### 3.1 Claude Code mobile ("Remote Control") — Anthropic official

Source: [code.claude.com/docs/en/mobile](https://code.claude.com/docs/en/mobile).

- Transport/architecture: "Remote Control... connects the Claude app to a Claude Code session running on your machine, so code execution and filesystem access stay local." Start with `claude remote-control` or `/remote-control`, then pair by QR code or pick the session in the app's Code tab; requires the same claude.ai account login; reconnects if the machine sleeps.
- Mobile surface shows/does: "Start, monitor, and steer Claude Code tasks from your phone"; check progress, answer questions, steer sessions; it is "a client for Claude Code sessions rather than a place where code runs."
- Push: with Remote Control active, Claude can notify the phone "when a long-running task finishes or when it needs a decision from you"; you can request a notification in a prompt.
- Limitations: terminal-only commands (`/plugin`, `/resume`) don't work; permission-mode selection is constrained; computer must stay on. "Dispatch" (spawns sessions and notifies when they finish/need approval) requires Pro/Max/Ultra.
- Complementary cloud mode: "Claude Code on the web" runs tasks on "Anthropic-managed cloud infrastructure... in an isolated sandbox environment," GitHub integration via a secure proxy, with an iOS app preview at launch; now GA as "Cloud sessions" ([announcement](https://claude.com/blog/claude-code-on-the-web)).

### 3.2 Omnara

Sources: [github.com/omnara-ai/omnara](https://github.com/omnara-ai/omnara) README, [docs.omnara.com/introduction](https://docs.omnara.com/introduction), docs folder in-repo (`docs/events/interactions.mdx`, `docs/integrations/`).

- What it is now (2026): "The open-source managed agent platform... the open-source, self-hostable alternative to Claude Managed Agents and OpenAI's Agents API." Apache-2.0; self-host via Docker Compose, or Omnara Cloud. Runs agents "on any model and any machine," with `agent.yaml` configs, managed sandboxes, streaming events, and a TypeScript SDK (`@omnara/sdk`).
- Surfaces: web dashboard, CLI (`npx omnara agents chat`), REST API; integrations for **Slack, Discord, GitHub** supply tools, activity subscriptions, and "an interaction handler for presenting questions and approvals."
- Controllable remotely: "Reading or streaming it's event log; Sending inputs...; Resolving questions and approvals" (docs README). Approvals are first-class "interactions."
- **Mobile:** the current repo's only frontend app is `frontend/apps/web` — no iOS/Android app, and no push-notification docs are present on omnara.com or docs.omnara.com today. (Omnara's 2025 positioning as a Claude Code mobile monitor with push approvals — e.g. its Show HN — is no longer reflected in the first-party docs; treat "mobile push approvals" as historical/community context, not a documented current feature. Source checked: [omnara.com](https://www.omnara.com), [docs.omnara.com](https://docs.omnara.com/introduction).)

### 3.3 Vibe Kanban

Sources: [github.com/BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) README (fetched 2026-11-07), [shutdown announcement](https://www.vibekanban.com/blog/shutdown).

- **Status: sunsetting.** The README's H1: "Vibe Kanban is sunsetting. Read the announcement." Use it only as pattern reference, not a dependency.
- What it was: kanban-board planning for coding-agent work; "workspaces" giving each agent a branch, terminal, and dev server; diff review with inline comments sent back to the agent; 10+ agent backends (Claude Code, Codex, Gemini CLI, ...); web UI (`npx vibe-kanban`), self-hosting guide, remote deployment via Cloudflare Tunnel/ngrok + Remote-SSH editor links.
- Mobile notifications: **not present in the current README or verifiable current docs** (a `docs/features/notifications` URL 404s as of 2026-11-07). Vibe Kanban shipped mobile push notifications at one point, but I could not verify it against a live first-party page today; do not cite it as current.

### 3.4 OpenClaw (pi.dev's cited real-world SDK example)

Source: [docs.openclaw.ai](https://docs.openclaw.ai); referenced as an SDK example by [pi.dev](https://pi.dev).

- Pattern: "You run a single Gateway process on your own machine (or a server)... No hosted service in the middle" — the closest analog to "pi on a VPS + remote surface," built on the pi SDK.
- Channels/clients: Discord, Google Chat, iMessage, Matrix, Microsoft Teams, Signal, Slack, Telegram, WhatsApp "and more via channel plugins"; Web Control UI (browser dashboard for chat/config/sessions), CLI, macOS app, and "pair iOS and Android nodes" for camera/screen/voice. Cron jobs, hooks, and webhooks for scheduled automation.
- Relevance: demonstrates the "agent gateway on VPS, arbitrary messaging/web surfaces as remote UI" architecture that pi's SDK/RPC makes possible.

### 3.5 Termux + tmux + SSH (run agents on a server, drive from a phone)

Sources: [Termux wiki — Remote Access](https://wiki.termux.com/wiki/Remote_Access), pi's own [termux.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/termux.md) and [tmux.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/tmux.md).

- Termux-in = pi on the phone: first-party pi docs cover installing pi inside Termux (`npm install -g --ignore-scripts @earendil-works/pi-coding-agent`), `termux-setup-storage` for shared storage, clipboard via `termux-clipboard-set/get` (text only), and a Termux AGENTS.md template. pi "detects that it is running in Termux."
- Termux-as-server = SSH into the phone: wiki: "Default SSH port in Termux is 8022"; run `sshd` manually (no init system); OpenSSH recommended; key auth via `ssh-copy-id -p 8022`; MOSH and rsync-over-SSH documented; SFTP via `openssh-sftp-server`. The wiki page does not cover tmux.
- pi's tmux doc is about key reporting inside tmux (`extended-keys on`, CSI-u on tmux ≥3.5), i.e., running the TUI pleasantly under tmux on a server; combine with any SSH client to attach from a phone. Neither doc describes widget/notification integration — Termux API (termux-api) is the documented hook pi uses for Android device interactions.

---

## Open questions the sources don't answer

1. **Concurrent readers/writers of one session file:** pi documents the JSONL format and RPC `get_entries` cursors, but says nothing about file locking, append atomicity, or whether an external `tail -f` reader is *supported* while a TUI or RPC process writes the same session. Needs an experiment or a question to maintainers.
2. **Attaching a bridge to a running TUI pi:** no documented mechanism; the only in-TUI hook surface is extensions (which run inside the process and *may* open sockets at `session_start`). Whether anyone runs an extension-hosted WebSocket server inside an interactive pi session is not documented first-party.
3. **pi-durable stability timeline:** it is the purpose-built library for a VPS status-widget backend (watch/busy/usage/task-graph/read-only viewer) but is labeled experimental with breaking changes between releases; no stability/roadmap statement beyond that.
4. **pi RPC backpressure/limits at scale** (max outstanding commands, event throughput) are unspecified beyond "honor backpressure."
5. **FCM deprioritization thresholds:** Google documents the *behavior* (7-day per-instance downgrade for non-notification high-priority messages) but not the exact quota or how a widget-refresh-only use degrades over time; only empirical testing answers "how often can I push before downgrade."
6. **Android 16 specifics:** the brief asks about Android 14/15/16; developer.android.com pages fetched cover 14 (FGS types) and 15 (dataSync 6 h quota, BOOT_COMPLETED restrictions). I did not find (and did not verify) an equivalent published behavior-change page for Android 16 altering these widget/FGS rules — needs a targeted check of the Android 16 behavior-changes page before finalizing targetSdk.
7. **Omnara mobile history:** whether Omnara still ships/keeps the iOS/Android monitoring app (2025-era) is not answerable from current first-party docs; only the web/CLI/API/Slack/Discord surfaces are documented now.
8. **Vibe Kanban's former mobile-push implementation details** (transport: web push vs ntfy vs APNs/FCM) — first-party pages are gone (404) or removed post-sunset; only the archived blog announcement remains, which I did not fetch.

---

### Source index (primary)

- pi repo + docs: https://github.com/earendil-works/pi (docs at `packages/coding-agent/docs/`: rpc.md, rpc-commands.md, rpc-extension-ui.md, json.md, sdk.md, sessions.md, session-format.md, cli.md, cli-integration.md, extensions.md, termux.md, tmux.md, containerization.md; packages/agent/README.md; packages/durable/README.md)
- pi site: https://pi.dev · npm: https://www.npmjs.com/package/@earendil-works/pi-coding-agent · old package: https://www.npmjs.com/package/@mariozechner/pi-coding-agent
- steipete/pi check: https://api.github.com/repos/steipete/pi (fork of badlogic/pi)
- Android: https://developer.android.com/reference/android/appwidget/AppWidgetProviderInfo · https://developer.android.com/reference/androidx/work/PeriodicWorkRequest · https://developer.android.com/develop/ui/views/appwidgets · https://developer.android.com/develop/ui/compose/glance/create-app-widget · https://developer.android.com/develop/ui/compose/glance/glance-app-widget · https://developer.android.com/jetpack/androidx/releases/glance · https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start · https://developer.android.com/about/versions/14/changes/fgs-types-required · https://developer.android.com/about/versions/15/behavior-changes-15 · https://developer.android.com/training/monitoring-device-state/doze-standby
- FCM: https://firebase.google.com/docs/cloud-messaging/android/message-priority
- Prior art: https://code.claude.com/docs/en/mobile · https://claude.com/blog/claude-code-on-the-web · https://github.com/omnara-ai/omnara · https://docs.omnara.com/introduction · https://github.com/BloopAI/vibe-kanban · https://www.vibekanban.com/blog/shutdown · https://docs.openclaw.ai · https://wiki.termux.com/wiki/Remote_Access
