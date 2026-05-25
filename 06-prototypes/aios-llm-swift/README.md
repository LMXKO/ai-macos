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
- `aios launch-agent install|uninstall|status`: manages a user LaunchAgent for background queue draining.

State lives at `~/Library/Application Support/AIOS` by default:

- `queue/*.json`: submitted goals waiting for the host/daemon.
- `runs/<run_id>/events.jsonl`: durable events such as `UserGoal`, `TaskPlan`, `ToolSelection`, `PolicyCheck`, `AppAction`, `Observation`, `Verification`, `Recovery`, `NextStep`, and `Delivery`.
- `runs/<run_id>/summary.json`: goal, status, timestamps, and event path.
- `runs.sqlite`: SQLite run index for fast task list/history lookup; JSON event streams remain the source of detailed truth.
- `snapshots/<snapshot_id>/snapshot.json`: persistent UI snapshots with stable element ids.
- `recipes/*.json`: reusable task recipes.
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
- cancel/retry/refresh/open state folder
- LLM base URL/model/max-step settings

The UI is intentionally plain. The product center is still the user goal and the verified event stream.

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

- ordered tool steps
- parameter placeholders such as `{{path}}` and `{{recipient}}`
- wait conditions before a step
- verification tools after a step
- `retries`
- `fallbackTools`
- `verifyExpression` clauses such as `success && evidence contains Created`
- `recoverySteps`
- deterministic stop-on-failure behavior with structured evidence

The executor is recipe-first: it receives local recipe suggestions in the task prompt and can call `recipe_suggest` / `recipe_execute` before falling back to manual app automation.

## Learning

AIOS can record successful tool-level workflows and raw UI events, then save them as reusable recipes:

```bash
swift run --disable-sandbox aios learn start "send file workflow"
swift run --disable-sandbox aios learn record finder_file_info '{"path":"~/Downloads/example.docx"}'
swift run --disable-sandbox aios learn record wechat_stage_file '{"recipient":"Example Contact","path":"~/Downloads/example.docx"}'
swift run --disable-sandbox aios learn stop send-file-learned
swift run --disable-sandbox aios recipe exec send-file-learned '{}'

swift run --disable-sandbox aios learn record-events "raw UI flow" --seconds 8 --recipe-id learned-ui-flow
```

Tool learning records exact app tools and arguments. Raw event learning uses a listen-only CGEvent tap, captures mouse/key events plus optional frontmost/AX context, writes the raw trace, and emits a replayable recipe with `ui_click` and keyboard steps. It requires Input Monitoring permission.
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
- Action-not-performed hardening: if the model claims success in prose without tool calls, AIOS emits `ActionNotPerformed` and asks for a concrete app/observation tool. `task_complete` is rejected before tool evidence exists.

The CLI emits structured event lines such as `UserGoal`, `TaskPlan`, `StepQueue`, `ToolSelection`, `PolicyCheck`, `AppAction`, `Observation`, `Verification`, `Recovery`, `NextStep`, and `Delivery`. This gives us a Codex-style event stream that can later back a SwiftUI task timeline.

Orchestration-only tools:

- `task_plan_submit`
- `step_complete`
- `step_failed`
- `plan_update`

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
swift run --disable-sandbox aios mcp
swift run --disable-sandbox aios tool aios_list_apps '{"query":"WeChat"}'
swift run --disable-sandbox aios tool aios_find '{"query":"Send","role":"AXButton","max_results":5}'
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
- `recipe_list`
- `recipe_suggest`
- `recipe_execute`
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
