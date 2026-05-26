# AIOS LLM Swift Prototype

This is the smallest all-Swift prototype for a structured macOS task orchestrator:

```text
UserGoal
-> TaskPlan
-> StepQueue
-> ToolSelection
-> PolicyCheck
-> AppAction
-> Observation
-> Verification
-> Recovery / NextStep
-> Delivery
```

It intentionally starts as a CLI instead of a SwiftUI app. The point is to prove the agent loop and real app control before building product UI.

## Host, Queue, And Event Stream

The prototype now has a tiny always-on host and durable run history:

- `aios host`: starts a menu-bar host named `AIOS` and drains queued tasks.
- `aios daemon`: starts the same queue worker without menu-bar UI.
- `aios app`: starts the minimal SwiftUI task console.
- `aios submit "<goal>"`: writes a queued task.
- `aios runs`: lists persisted runs.
- `aios show <run_id>`: prints the JSONL event stream for one run.
- `aios cancel <run_id>`: cancels a queued run.
- `aios retry <run_id>`: submits a new run with the same goal.
- `aios resume <run_id>`: requeues an existing run and resumes from its checkpoint when available.
- `aios launch-agent install|uninstall|status`: manages a user LaunchAgent for background queue draining.

State lives at `~/Library/Application Support/AIOS` by default:

- `queue/*.json`: submitted goals waiting for the host/daemon.
- `runs/<run_id>/events.jsonl`: durable events such as `UserGoal`, `TaskPlan`, `ToolSelection`, `PolicyCheck`, `AppAction`, `Observation`, `Verification`, `Recovery`, `NextStep`, and `Delivery`.
- `runs/<run_id>/summary.json`: goal, status, timestamps, and event path.
- `runs/<run_id>/checkpoint.json`: current plan, step status, verification state, action count, and duplicate-send guard for long-task resume.
- `runs.sqlite`: SQLite run index for fast task list/history lookup; JSON event streams remain the source of detailed truth.
- `snapshots/<snapshot_id>/snapshot.json`: persistent UI snapshots with stable element ids.
- `recipes/*.json`: reusable task recipes.
- `memory/memory.jsonl`: durable non-sensitive task/app/workflow memory.
- `episodes/*.json`: durable task episodes generated from completed, paused, or incomplete runs.
- `context-graph/*.json`: local graph nodes/edges for apps, workflows, goals, files, recipes, and outcomes.
- `app-skills/*.json`: optional app adapter/skill manifests layered over built-in manifests.
- `trajectories/<run_id>.json`: replayable action/observation/verification timelines exported from run events.
- `evals/last-run.json`: last E2E smoke/eval result.
- `evals/real-e2e-cases.json`: opt-in real app cases, disabled by default.
- `learning/raw/*.json`: raw CGEvent learning traces.
- `audit.jsonl`: tool-call audit log.

For local testing, set `AIOS_STATE_DIR` to redirect state into a scratch directory.

## Minimal App UI

`aios app` opens a small Codex-style control window:

- task input and submit
- run list with statuses
- selected run event stream
- audit tail
- cancel/resume/retry/refresh/open state folder
- LLM base URL/model/max-step settings

The UI is intentionally plain. The product center is still the user goal and the verified event stream.

The app view also exposes a task cockpit for long runs: selected checkpoint, trajectory summary, recalled memory, and available app skills. That makes a parked or resumed task inspectable instead of being a black-box background process.

## Computer-Use Runtime Layers

AIOS now separates computer-use work into planner, executor, perception, recipe, memory, app-skill, browser, and trajectory layers:

- `computer_use_strategy` chooses a primary controller and fallback path for the current goal.
- `background_control_plan` ranks deep background channels: CDP/DOM for Chrome web apps, app scripting/adapters, AX semantic actions, visual grounding, then foreground coordinates as the last resort.
- `background_capabilities` inspects which non-invasive channels are likely available for a target app.
- `background_action` is the unified non-invasive executor: it tries CDP selector actions, JavaScript eval, AppleScript/SDEF, AX background locators, visual grounding, and only uses foreground visual actions when `allow_foreground=true`.
- `visual_ground` turns a screenshot/window/image into ranked candidates from OCR text, rectangle detection, AX hints, and saliency regions.
- `visual_analyze` adds a Peekaboo/Ghost-style VQA hook. Configure `AIOS_VISION_BASE_URL`, `AIOS_VISION_MODEL`, and optionally `AIOS_VISION_API_KEY` for an OpenAI-compatible vision sidecar; without it, the tool returns local grounding evidence.
- `browser_cdp_observe`, `browser_cdp_act`, `browser_cdp_extract`, and `browser_cdp_wait` provide a Stagehand-like web-agent layer above raw CDP eval/click/type/read.
- `app_skill_list` and `app_skill_suggest` expose app adapter manifests with tools, selectors, permissions, notes, and compatibility hooks.
- `app_skill_install` installs local app skill packages so adapters can grow outside the monolithic Swift tool list.
- `memory_profile`, `episode_recall`, `context_graph_query`, and `context_graph_ingest` recall and strengthen durable task context.
- `trajectory_get`, `trajectory_export`, `trajectory_session_export`, and `trajectory_replay_plan` produce replayable timelines and full replay-session artifacts.

The practical boundary is explicit: macOS cannot make every arbitrary native, inactive, offscreen, non-AX surface controllable through a single public API. AIOS therefore uses the deepest available non-invasive channel first, and only falls back to foreground coordinate control when no semantic/background path exists.

## Long-Agent Parity Kernels

The long-running computer-use layer now exposes the 10 product kernels needed for "AI keeps working on macOS software for a long time":

```bash
swift run --disable-sandbox aios tool long_agent_capability_matrix '{"goal":"持续在 Chrome 和 Figma 完成任务"}'
swift run --disable-sandbox aios tool background_native_kernel '{"app_name":"Figma","surface":"canvas","action":"click","query":"play"}'
swift run --disable-sandbox aios tool background_driver_probe '{"app_name":"Figma","surface":"canvas","action":"click","query":"play"}'
swift run --disable-sandbox aios tool visual_grounder_model_registry '{}'
swift run --disable-sandbox aios tool visual_grounder_policy '{"surface":"canvas","query":"play button"}'
swift run --disable-sandbox aios tool recipe_stabilize_program '{"id":"create-calendar-event"}'
swift run --disable-sandbox aios tool resident_agent_plan '{"goal":"watch a download and summarize it","app_name":"Finder"}'
swift run --disable-sandbox aios tool resident_agent_tick '{"evidence":"manual tick"}'
swift run --disable-sandbox aios tool shadow_episode_policy '{"goal":"long browser workflow"}'
swift run --disable-sandbox aios tool browser_agent_contract '{"goal":"submit a form","url":"https://example.com/app"}'
swift run --disable-sandbox aios tool app_skill_core_pack '{"install":false}'
swift run --disable-sandbox aios tool cockpit_replay_spec '{"run_id":"<run_id>"}'
swift run --disable-sandbox aios tool agent_harness_dispatch '{"goal":"持续在 Chrome 和 Figma 完成任务","app_name":"Chrome","surface":"canvas"}'
swift run --disable-sandbox aios tool computer_use_model_stack '{"goal":"AI长时间自动驱动mac上的软件完成任务"}'
```

These tools map the current implementation against CUA-style background control, Ghost-style recipe/memory loops, Peekaboo-style capture/replay evidence, Stagehand-style browser primitives, and Codex-style resident/harness workflows. Native non-AX pixels still require an app adapter or external CUA-compatible driver capsule; the kernel makes that boundary explicit and keeps foreground coordinates opt-in.

## Long-Running Tasks

AIOS persists execution state after planning, after tool results, after verification changes, and before incomplete exits. A crash, host restart, or max-step stop can be continued with:

```bash
swift run --disable-sandbox aios resume <run_id>
swift run --disable-sandbox aios host
```

The checkpoint includes the current `TaskPlan`, completed/failed/running step state, verification contracts, action count, and already-submitted external sends. This lets a resumed task continue from the pending or failed step without blindly repeating verified work or resending the same external message.

Long waits use the runtime state machine instead of busy loops. The executor can call `runtime_pause` with `resume_after_seconds` or `resume_at`; the run is marked `paused` or `scheduled`, the checkpoint is persisted, and the same run id is requeued for the host/daemon when it is time to continue. The queue skips future scheduled items while still draining ready work.

`runtime_schedule` and `runtime_status` expose the same durable state machine as tools. A long task can now be scheduled, inspected, resumed, and exported without needing to parse run folders manually.

## Memory

AIOS keeps a local JSONL memory store for reusable, non-sensitive context:

- successful recipes and locator hints
- non-invasive AX actions that worked for a target app
- visual OCR fallback hints
- verified completion effects
- user or workflow notes explicitly saved through `memory_remember`

The executor receives relevant `MemoryContext` before each run and can call:

```bash
swift run --disable-sandbox aios tool memory_remember '{"kind":"workflow_hint","key":"TextEdit input","value":"Use AXValue before paste fallback."}'
swift run --disable-sandbox aios tool memory_recall '{"query":"TextEdit input","limit":5}'
swift run --disable-sandbox aios tool memory_recent '{"limit":10}'
swift run --disable-sandbox aios tool episode_recall '{"query":"TextEdit export PDF","limit":3}'
swift run --disable-sandbox aios tool context_graph_query '{"query":"Chrome","limit":10}'
swift run --disable-sandbox aios tool memory_profile '{"query":"Chrome web automation","limit":5}'
```

Memory rejects secret-like values such as passwords, bearer tokens, private keys, API keys, and payment terms. It is local runtime state, not source-controlled project data.

Episodes and the context graph are the next memory layer above JSONL hints. Episodes summarize what happened in a run; the graph connects goals, apps, recipes, tools, files, outcomes, and learned fixes so future tasks can reuse operating context, not just isolated notes.

## Recipes And Eval

Default recipes are seeded automatically:

- `send-file-to-contact`
- `write-plan-and-sync`
- `export-document-pdf`
- `create-calendar-event`

Examples:

```bash
swift run --disable-sandbox aios recipe list
swift run --disable-sandbox aios recipe suggest "把文档导出成 PDF"
swift run --disable-sandbox aios recipe run send-file-to-contact '{"app":"wechat","recipient":"Example Contact","path":"~/Downloads/example.docx"}'
swift run --disable-sandbox aios recipe exec export-document-pdf '{"path":"~/Downloads/example.docx","outdir":"~/Downloads"}'
swift run --disable-sandbox aios eval list
swift run --disable-sandbox aios eval run --repeat 3
swift run --disable-sandbox aios eval real-list
```

Eval cases are conservative and avoid destructive or accidental-send actions. Real cases are generated in `evals/real-e2e-cases.json`, disabled by default, and require both `enabled: true` in that file and `AIOS_ALLOW_REAL_E2E=1`.

The default full-stack real E2E query for this project's goal is:

```text
Draft a short project plan and send it to Example Contact.
```

Run it only after explicitly enabling the real E2E case in `real-e2e-cases.json`, because it sends a real external message:

```bash
AIOS_ALLOW_REAL_E2E=1 swift run --disable-sandbox aios eval real-run project-plan-send-to-contact
```

Recipes are now real step workflows, not only prompt templates. Each recipe can define:

- version metadata and app bindings
- parameter schemas with inferred placeholders
- global preconditions and postconditions
- ordered tool steps
- parameter placeholders such as `{{path}}` and `{{recipient}}`
- wait conditions before a step
- verification tools after a step
- `retries`
- `fallbackTools`
- `verifyExpression` clauses such as `success && evidence contains Created`
- `recoverySteps`
- `nextOnSuccess` / `nextOnFailure` branch targets
- `loopUntil` and `maxIterations`
- `stateWrites` emitted into the event stream
- deterministic stop-on-failure behavior with structured evidence

The executor is recipe-first: it receives local recipe suggestions in the task prompt and can call `recipe_suggest` / `recipe_execute` before falling back to manual app automation. A successful run can be promoted into a durable workflow program:

```bash
swift run --disable-sandbox aios tool recipe_promote_run '{"run_id":"<run_id>","recipe_id":"learned-workflow"}'
swift run --disable-sandbox aios tool recipe_compile '{"id":"learned-workflow"}'
swift run --disable-sandbox aios tool recipe_refine '{"id":"learned-workflow","run_id":"<run_id>","success":true}'
```

Promotion extracts successful `AppAction` / `Observation` pairs, infers placeholders, coalesces stable steps, and writes a versioned recipe draft with parameters, preconditions, postconditions, and success/failure counters.
Compilation validates workflow-program shape before reuse; refinement increments versioned success/failure counters from real runs.

## Learning

AIOS can record successful tool-level workflows and raw UI events, then save them as reusable recipes:

```bash
swift run --disable-sandbox aios learn start "send file workflow"
swift run --disable-sandbox aios learn record finder_file_info '{"path":"~/Downloads/example.docx"}'
swift run --disable-sandbox aios learn record wechat_stage_file '{"recipient":"Example Contact","path":"~/Downloads/example.docx"}'
swift run --disable-sandbox aios learn stop send-file-learned
swift run --disable-sandbox aios recipe exec send-file-learned '{}'

swift run --disable-sandbox aios learn record-events "raw UI flow" --seconds 8 --recipe-id learned-ui-flow
swift run --disable-sandbox aios learn record-events "exact raw UI flow" --seconds 8 --recipe-id raw-ui-flow --raw
```

Tool learning records exact app tools and arguments. Raw event learning uses a listen-only CGEvent tap, captures mouse/key events plus optional frontmost/AX context, writes the raw trace, and by default synthesizes semantic recipe steps: `aios_background_click` / `aios_background_type` first, `visual_click` and foreground locator fallback next, raw coordinates last. Consecutive printable key events are folded into text-entry steps when possible. Use `--raw` to save exact mouse/keyboard replay. It requires Input Monitoring permission.
Tool-level learning now saves only verified successful tool steps; failed recorded steps are rejected instead of becoming recipes. Raw event recipes are explicitly marked unverified until replayed and strengthened with verifiers.

## MCP Server

The same `ToolRegistry` is exposed over MCP stdio:

```bash
swift run --disable-sandbox aios mcp
```

The server supports `initialize`, `ping`, `tools/list`, and `tools/call`, so other agents can discover and call the macOS tools without a separate bridge.

## Config And Keychain

```bash
swift run --disable-sandbox aios config show
swift run --disable-sandbox aios config set base_url "https://api.example.com/v1"
swift run --disable-sandbox aios config set model "example-chat-model"
swift run --disable-sandbox aios config set-key "$AIOS_LLM_API_KEY"
```

The API key is stored in the macOS Keychain. `AIOS_LLM_API_KEY` still overrides it for one-off runs.
Fallback providers can be set with semicolon-separated `base_url|model|api_key_or_$ENV` entries:

```bash
export AIOS_LLM_FALLBACKS="https://example.com/v1|other-model|$OTHER_API_KEY"
```

## Orchestration

The runtime is now a two-phase orchestrator rather than a raw ReAct loop:

- Planning phase: the model must call `task_plan_submit` and produce a compact `TaskPlan`.
- Execution phase: Swift owns the `StepQueue`; each step has `pending`, `running`, `done`, or `failed` status.
- Tool selection: the model chooses app tools for the current step only.
- Policy check: every app tool call passes one Swift policy gate before execution.
- App action: the selected Swift/macOS tool executes.
- Observation: each `ToolResult` is recorded as step evidence.
- Verification: the model can call `step_complete`; Swift also auto-verifies simple successful tool evidence.
- Recovery / NextStep: failed steps are retried up to three attempts, and the model can call `plan_update` to append recovery steps.
- Delivery: `task_complete` ends the run only after requested delivery is done and verified.
- Checkpoint: the current plan and verification state are persisted throughout the run and cleared only after verified completion.
- Memory: successful reusable hints are saved locally and recalled into future tasks when relevant.
- Action-not-performed hardening: if the model claims success in prose without tool calls, AIOS emits `ActionNotPerformed` and asks for a concrete app/observation tool. `task_complete` is rejected before tool evidence exists.

The CLI emits structured event lines such as `UserGoal`, `TaskPlan`, `StepQueue`, `ToolSelection`, `PolicyCheck`, `AppAction`, `Observation`, `Verification`, `Recovery`, `NextStep`, and `Delivery`. This gives us a Codex-style event stream that can later back a SwiftUI task timeline.

Orchestration-only tools:

- `task_plan_submit`
- `step_complete`
- `step_failed`
- `plan_update`
- `runtime_pause`

## Run

```bash
cd 06-prototypes/aios-llm-swift
swift run --disable-sandbox aios doctor
swift run --disable-sandbox aios doctor --request-permissions
swift run --disable-sandbox aios setup --request-permissions
swift run --disable-sandbox aios host
swift run --disable-sandbox aios submit "Draft a short project plan and send it to Example Contact"
swift run --disable-sandbox aios runs
swift run --disable-sandbox aios show <run_id>
swift run --disable-sandbox aios resume <run_id>
swift run --disable-sandbox aios mcp
swift run --disable-sandbox aios tool aios_list_apps '{"query":"WeChat"}'
swift run --disable-sandbox aios tool aios_find '{"query":"Send","role":"AXButton","max_results":5}'
swift run --disable-sandbox aios tool visual_read '{"scope":"screen","max_results":5}'
swift run --disable-sandbox aios tool visual_ground '{"scope":"screen","max_results":8}'
swift run --disable-sandbox aios tool background_control_plan '{"goal":"use Chrome web app without stealing focus","app_name":"Chrome"}'
swift run --disable-sandbox aios tool background_action '{"action":"read","query":"Send","app_name":"WeChat"}'
swift run --disable-sandbox aios tool browser_cdp_status '{}'
swift run --disable-sandbox aios tool browser_cdp_observe '{"query":"submit","max_results":10}'
swift run --disable-sandbox aios tool runtime_status '{"run_id":"<run_id>"}'
swift run --disable-sandbox aios "Create a TextEdit document with hello aios, save it to ~/Desktop/aios-demo.txt, and reveal it in Finder."
```

In this sandboxed Codex workspace, `--disable-sandbox` avoids SwiftPM's own `sandbox-exec` failure. It does not disable this prototype's tool policy.
If permissions change, quit and reopen the host app, then run `doctor` again.

## LLM Config

The client expects an OpenAI-compatible chat completions endpoint. Configure your provider locally; do not commit real keys or private endpoints.

```bash
export AIOS_LLM_BASE_URL="https://api.example.com/v1"
export AIOS_LLM_MODEL="example-chat-model"
export AIOS_LLM_API_KEY="replace-with-your-local-key"
export AIOS_MAX_STEPS="20"
export AIOS_VISION_BASE_URL="https://vision-compatible.example.com/v1"
export AIOS_VISION_MODEL="example-vision-model"
```

`AIOS_LLM_BASE_URL` may be either the API root shown above or a full `/chat/completions` URL.

By project policy, sending chat messages, running Shortcuts, writing Calendar events, and running shell commands are directly available to the model when the user task needs them. They no longer require `AIOS_ALLOW_*` environment switches.

## Current Tools

Universal macOS tools:

- `aios_context`: frontmost app, bundle id, pid, visible window titles
- `aios_automation_context`: frontmost or target app context plus visible windows for locator-based work
- `aios_find`: find AX elements and return reusable locator ids
- `aios_inspect`: inspect a locator's attributes and actions
- `aios_read`: read text from a locator or app AX tree
- `aios_click`: AXPress-first click with coordinate fallback
- `aios_type`: AXValue-first text entry with paste fallback
- `aios_background_click`: AXPress-only non-invasive click; restores focus and never uses coordinates
- `aios_background_type`: AXValue-only non-invasive text entry; restores focus and never clicks/pastes
- `aios_wait`: wait for locator, text, app, or window conditions
- `aios_list_apps`: installed app inventory from `/Applications`, `~/Applications`, and `/System/Applications`
- `aios_list_running_apps`
- `aios_app_windows`
- `aios_open_app`: open/focus an app
- `aios_quit_app`
- `aios_open_file`
- `aios_open_url`
- `clipboard_get_text`
- `clipboard_set_text`
- `clipboard_set_files`
- `ui_paste`
- `ui_keyboard_shortcut`
- `ui_click_menu`
- `ui_click`
- `ui_scroll`
- `ui_hover`
- `ui_drag`
- `ui_long_press`
- `window_manage`
- `dialog_click`
- `dialog_input`
- `dock_open`
- `menubar_click`
- `space_switch`
- `ax_describe_frontmost`
- `ax_press`
- `ax_get_focused_value`
- `ax_set_focused_value`
- `screen_capture`
- `screen_capture_window`: ScreenCaptureKit first, legacy CGWindow fallback
- `screen_capture_window_sck`
- `observe_snapshot`: front app/window/focus/AX plus optional screenshot in one tool result
- `observe_wait`: waits for frontmost app, window title, AX text, focused value, Safari/Chrome URL, or file existence
- `observe_annotate_frontmost`: indexed actionable AX elements with labels and bounds
- `snapshot_create`: creates a persistent snapshot id and stable `E1`, `E2`, ... element ids
- `snapshot_get`
- `snapshot_click`
- `snapshot_type`
- `snapshot_press`
- `ocr_image`
- `ocr_screen`
- `visual_find`: OCR text with screen/window bounds for visual fallback
- `visual_read`: OCR screen/window text and regions
- `visual_click`: foreground coordinate click on a visual OCR match
- `visual_ground`: OCR, rectangle, AX-hint, and saliency candidates for icon/canvas/layout grounding
- `visual_analyze`: VQA/image reasoning through a configured vision sidecar, with local grounding fallback
- `background_control_plan`: ranks CDP, scripting, AX, visual, and coordinate control channels for a task
- `background_capabilities`
- `background_appscript`
- `background_action`
- `browser_cdp_launch`: launches isolated Chrome with a remote debugging port
- `browser_cdp_status`
- `browser_cdp_tabs`
- `browser_cdp_eval`: JavaScript evaluation through Chrome DevTools Protocol
- `browser_cdp_click`: DOM selector click without cursor/focus
- `browser_cdp_type`: DOM selector text entry without screen focus
- `browser_cdp_read`: read DOM text/value/html/attributes
- `browser_cdp_observe`: Stagehand-style DOM observation with selector candidates
- `browser_cdp_act`: selector/text resolved click/type/read/submit
- `browser_cdp_extract`: structured page extraction
- `browser_cdp_wait`: selector/text/url/expression waits
- `memory_remember`
- `memory_recall`
- `memory_recent`
- `episode_recall`
- `context_graph_query`
- `context_graph_ingest`
- `memory_profile`
- `recipe_list`
- `recipe_suggest`
- `recipe_execute`
- `recipe_promote_run`
- `recipe_compile`
- `recipe_refine`
- `app_skill_list`
- `app_skill_suggest`
- `app_skill_install`
- `trajectory_get`
- `trajectory_export`
- `trajectory_session_export`
- `trajectory_replay_plan`
- `runtime_status`
- `runtime_schedule`
- `computer_use_strategy`
- `learn_start`
- `learn_record_tool`
- `learn_record_events`
- `learn_stop`
- `sdef_lookup`: inspect an app's AppleScript dictionary
- `scripting_bridge_probe`

App-specific tools:

- Finder:
  - `finder_list_directory`
  - `finder_file_info`
  - `finder_find_files`
- `textedit_new_document`
- `textedit_set_text`
- `textedit_read_text`
- `textedit_save_as`
- `finder_create_folder`
- `finder_reveal_file`
- Chrome:
  - `chrome_open_url`
  - `chrome_get_current_tab`
  - `chrome_new_tab`
  - `chrome_search`
  - `chrome_get_page_text`
  - `chrome_eval_js`
- Notes:
  - `notes_create_note`
  - `notes_search`
- Mail:
  - `mail_compose_draft`
  - `mail_search_messages`
- Calendar:
  - `calendar_create_event`
  - `calendar_find_events`
- Reminders:
  - `reminders_create`
- WeChat:
  - `wechat_open`
  - `wechat_search_chat`
  - `wechat_stage_file`: stages an attachment, does not send
  - `wechat_send_text`
  - `wechat_send_staged`
  - `wechat_verify_chat`
  - `wechat_verify_recent_message`
- Lark:
  - `lark_open`
  - `lark_search_chat`
  - `lark_stage_file`: stages an attachment, does not send
  - `lark_send_text`
  - `lark_send_staged`
  - `lark_verify_chat`
  - `lark_verify_recent_message`
- QQ:
  - `qq_open`
  - `qq_search_chat`
  - `qq_stage_file`: stages an attachment, does not send
  - `qq_send_text`
  - `qq_send_staged`
  - `qq_verify_chat`
  - `qq_verify_recent_message`
- Tencent Meeting:
  - `tencent_meeting_open`
  - `tencent_meeting_stage_join`: stages a meeting id/link on the clipboard, does not join
- Baidu Netdisk:
  - `baidunetdisk_open`
  - `baidunetdisk_stage_file`: stages a file on the clipboard, does not upload
- ToDesk:
  - `todesk_open`
  - `todesk_stage_remote_id`: stages a remote id/code on the clipboard, does not connect
- Docker:
  - `docker_open`
  - `docker_status`: read-only app/window status
- IDEs:
  - `xcode_open_path`
  - `pycharm_open_path`
  - `rustrover_open_path`
- Document/viewer apps:
  - `wps_open_file`
  - `libreoffice_open_file`
  - `libreoffice_export_pdf`
  - `preview_open_file`
- Shortcuts:
  - `shortcuts_open`
  - `shortcuts_list`
  - `shortcuts_run`
- Safari:
  - `safari_open_url`
  - `safari_get_current_url`
  - `safari_get_page_text`
  - `safari_eval_js`
  - `safari_new_tab`
  - `safari_search`
- AI/dev desktop apps:
  - `claude_open`
  - `codex_open`
- Other installed high-frequency apps with explicit open adapters:
  - `anaconda_open`
  - `clashx_open`: does not change proxy settings
  - `flyingbird_open`: does not change network/proxy state
  - `inode_client_open`: does not connect/disconnect
  - `inode_manager_open`: does not change network sessions
  - `ntfs_for_mac_open`
  - `ui_tars_open`
  - `veee_open`: does not change network/proxy state
  - `wd_discovery_open`
  - `yaaa_network_assistant_open`
- Terminal:
  - `terminal_run_command`
- `task_complete`

This does not mean every proprietary app feature has a dedicated adapter. The current layer gives the LLM broadly applicable controls plus first-pass adapters for high-value apps. Those adapters should keep expanding only where native APIs or stable workflows exist.

## Codex-Inspired Boundaries

- Model-visible tool schema is separate from execution code.
- Every tool returns a structured result with `success`, `evidence`, optional `data`, `error`, and `suggestion`.
- Large tool outputs are truncated in the middle while preserving head and tail evidence.
- Still-protected behavior: no deletes, no credentials/payments, no file overwrite unless requested.
- Chat/file send workflows remain staged before final send so the model can verify the target recipient/chat first; the final send tool is directly callable.
