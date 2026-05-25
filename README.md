# AI macOS System Layer

## Purpose

This project builds a system-level AI execution layer for macOS.

The final goal is not a chatbot, menu bar assistant, or screen-clicking bot. The final goal is a trusted macOS capability that can observe installed applications, choose the safest available control path, operate across applications, and verify the result after each action.

In practical terms, the AI should become a trusted execution layer inside the macOS environment:

- observe application, window, screen, notification, file, and system state
- understand the current user task
- choose native app/system interfaces before visual automation
- act across multiple installed applications
- verify whether the action actually succeeded
- respect macOS privacy controls, TCC permissions, sandboxing, secure input, and user consent

macOS cannot be forked like Android or freely reshaped like Linux. The practical path is a signed native app plus helper services, LaunchAgent or LaunchDaemon integration, Accessibility permissions, Screen Recording permissions, Automation permissions, and carefully scoped privileged helpers where needed.

## System-Level Definition

This project is considered system-level only if it integrates with macOS trust and permission paths rather than behaving like a normal foreground app.

Minimum definition:

- it runs as a persistent app/service, not only as a foreground chat window
- it can observe active applications through Accessibility, window metadata, screenshots, or app-specific APIs
- it can execute actions through Apple Events, Shortcuts, app APIs, Accessibility actions, or controlled input injection
- it re-observes and verifies after each action
- it has explicit TCC permissions, audit logs, user confirmation gates, and a reliable stop path

Screenshot-only or coordinate-only automation is useful for prototypes but is not the target architecture.

## Research Summary

Current open-source projects do not provide a complete macOS-level AI OS. They provide useful pieces for desktop AI agents and automation.

### Current Judgment

macOS can support the goal "AI drives multiple installed apps to complete user tasks", but it does so as a platform-integrated desktop agent rather than a forked or modified operating system.

The practical target is:

- a trusted native macOS app or background agent
- Accessibility, Screen Recording, Automation, and optional helper permissions
- app control through Apple Events, Shortcuts, app APIs, AX actions, and fallback input
- an observe-act-verify loop shared with the Linux and Android projects

The active Swift prototype in `06-prototypes/aios-llm-swift` now implements the core long-running computer-use runtime layers:

- deep control routing through CDP/DOM, AppleScript/SDEF, non-invasive AX, visual grounding, and opt-in foreground fallback
- visual grounding plus an OpenAI-compatible vision sidecar hook for VQA/layout/icon reasoning
- recipe workflow programs with parameters, pre/postconditions, branches, loops, recovery, promotion, compilation, and refinement
- durable queue/checkpoint/schedule/status runtime for long-running tasks
- app skill manifests that can be installed locally instead of hard-coding every adapter into Swift
- Stagehand-style browser observe/act/extract/wait tools on top of Chrome CDP
- memory profile, episode recall, and context graph ingestion/query
- cockpit/replay session export for inspecting, resuming, and turning trajectories into reusable workflows

The key boundary is that the AI operates through Apple-approved control surfaces. It should not assume it can bypass TCC, Secure Input, sandboxing, DRM, banking/payment protections, or per-app Automation prompts.

### Closest Open-Source Implementations

- [mediar-ai/fazm](https://github.com/mediar-ai/fazm): closest product-shape reference. Native macOS AI computer agent, useful for understanding a polished Mac app, permissions, and multi-app workflows.
- [ghostwright/ghost-os](https://github.com/ghostwright/ghost-os): useful as an "eyes and hands for agents" reference. Good for thinking about exposing macOS control as an agent/MCP-compatible capability layer.
- [trycua/cua](https://github.com/trycua/cua): useful for computer-use infrastructure, trajectories, evaluation, background execution, and verification around desktop agents.
- [CursorTouch/MacOS-MCP](https://github.com/CursorTouch/MacOS-MCP): useful as a lightweight MCP server pattern for exposing macOS app/window/UI control to agents.
- [macOS26/Agent](https://github.com/macOS26/Agent): useful as a developer-focused macOS agent reference, especially around Accessibility-driven app operation and local/remote model provider integration.
- [OpenInterpreter/open-interpreter](https://github.com/OpenInterpreter/open-interpreter): useful for local natural-language computer control, but it is broader than macOS and should be treated as a prototype/runtime reference.
- [accomplish-ai/accomplish](https://github.com/accomplish-ai/accomplish): useful for desktop AI coworker workflows, but not a macOS system-layer implementation.

Recommended priority for this project:

1. Study Fazm for product shape and native macOS agent UX.
2. Study Ghost OS and MacOS-MCP for exposing macOS control as agent tools.
3. Study CUA for computer-use testing, trajectory recording, and verification.
4. Use Open Interpreter and Accomplish as broader desktop-agent references, not as the system-layer base.

### AI And Desktop Agent References

- [OpenInterpreter/open-interpreter](https://github.com/OpenInterpreter/open-interpreter): natural-language local computer control reference; useful for prototyping agent workflows.
- [accomplish-ai/accomplish](https://github.com/accomplish-ai/accomplish): desktop AI coworker reference; useful for multi-app desktop workflows.
- [All-Hands-AI/OpenHands](https://github.com/All-Hands-AI/OpenHands): agent runtime reference; useful for task orchestration and tool use patterns.
- [agiresearch/AIOS](https://github.com/agiresearch/AIOS): agent OS runtime concepts; useful for memory, scheduling, and tool abstraction.
- OpenAI Codex (`00-references/codex-main`): useful as the closest reference for an LLM-driven tool runtime. It is not a macOS automation layer, but its tool registry, event stream, approval model, sandbox policy, and output truncation patterns map well to this project.

### Codex Reference Takeaways

Codex should influence the runtime shape, not the language stack. The Swift prototype should borrow these ideas:

- `codex-rs/core/src/tools/router.rs` and `registry.rs`: keep model-visible tool schemas separate from the local tool implementations.
- `codex-rs/core/src/tools/orchestrator.rs`: route every tool call through one policy point before execution.
- `codex-rs/protocol/src/protocol.rs`: model the task as a turn with structured events such as start, tool begin, tool end, warning, and complete.
- `codex-rs/protocol/src/approvals.rs`: represent risky actions as approval requests with action, reason, and possible decisions.
- `codex-rs/core/src/unified_exec/head_tail_buffer.rs`: cap large tool outputs and preserve the beginning and ending as evidence.

For this project, the minimal Swift version is:

```text
LLM message
  -> tool call
  -> Swift ToolRegistry
  -> policy gate
  -> app-specific Swift/AppleScript/AX action
  -> evidence-shaped ToolResult
  -> next LLM message
```

### macOS Native Integration References

- [Apple Accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h): native UI observation and interaction through AXUIElement.
- [Apple App Sandbox](https://developer.apple.com/documentation/security/app_sandbox): sandbox and entitlement model.
- [Apple Automation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_automation_apple-events): Apple Events automation entitlement.
- [Apple Endpoint Security](https://developer.apple.com/documentation/endpointsecurity): system event monitoring for security-sensitive integrations.
- [Apple Service Management](https://developer.apple.com/documentation/servicemanagement): login items and helper service management.

### Automation And Control References

- [Hammerspoon/hammerspoon](https://github.com/Hammerspoon/hammerspoon): powerful macOS automation runtime; useful for prototyping window/app automation.
- [BlueM/cliclick](https://github.com/BlueM/cliclick): command-line mouse and keyboard automation; useful as fallback input injection reference.
- [koekeishiya/yabai](https://github.com/koekeishiya/yabai): window management reference; useful for understanding macOS window control tradeoffs.
- [ianyh/Amethyst](https://github.com/ianyh/Amethyst): open-source macOS window manager reference.

## Architecture

```text
user goal
  -> agent planner
  -> observe current app and macOS state
  -> select Apple Event, Shortcut, app API, Accessibility action, or input event
  -> execute action
  -> observe again
  -> verify result
  -> continue, recover, or request user confirmation
```

### 1. System Runtime

Runs as a signed native app plus helper services.

Possible components:

- menu bar or background app
- LaunchAgent for user-session work
- privileged helper only when strictly needed
- local agent bridge
- model provider interface
- task lifecycle manager
- audit logger
- policy engine

### 2. Observation Layer

Combines:

- Accessibility API / AXUIElement tree
- active app and focused window state
- screenshots with Screen Recording permission
- OCR and vision models
- notifications where available
- clipboard with user-aware policy
- files and app documents where permissioned
- app-specific AppleScript, Shortcuts, URL schemes, or local APIs

### 3. Actuation Layer

Action priority:

1. app-native APIs, URL schemes, Shortcuts, and Apple Events
2. Accessibility semantic actions
3. menu commands and keyboard shortcuts
4. screenshot/OCR/vision-driven control
5. raw coordinate clicking as last resort

### 4. Agent Orchestrator

Turns user goals into reliable execution loops.

Core pieces:

- planner
- tool selector
- task state
- memory
- verifier
- UI recovery strategy
- user handoff when confidence is low

### 5. Permission And Safety

Required controls:

- Accessibility permission explanation and onboarding
- Screen Recording permission explanation and onboarding
- Automation permission prompts per target app
- optional Full Disk Access only for explicitly justified workflows
- sensitive action confirmations
- protected handling for passwords, payments, banking, private files, and secure input
- audit trail
- emergency stop from a trusted UI surface

## First Phase Goal

The first phase should prove that a trusted macOS app/service can operate across real applications using native macOS observation and execution paths.

### MVP Scope

The first MVP should be intentionally narrow:

- one macOS version range
- one user account
- one signed local app or development-signed app
- no banking, payment, password manager, private-file bulk access, or destructive file operations
- no autonomous background actions without explicit task request
- no kernel extension or invasive system modification

Recommended initial target:

- latest stable macOS available to the team
- Apple Silicon Mac if possible
- isolated test user account
- local or remote LLM provider hidden behind a simple model interface

### Phase 1 Deliverables

- native macOS app or agent process
- LaunchAgent or login-item integration
- Accessibility permission flow
- Screen Recording permission flow
- Apple Events or Shortcuts action executor
- Accessibility tree reader
- screenshot/window-state observer
- observe-act-verify loop
- audit log for every observation, decision, action, and verification
- demo workflow across at least two unrelated apps

Current Swift prototype status:

- CLI, menu-bar host, daemon worker, and minimal SwiftUI task console
- shared `ToolRegistry` for CLI, agent loop, and MCP stdio server
- locator-based Accessibility driver: context, find, inspect, read, click, type, wait
- recipe-first execution with recipe suggestions and deterministic recipe execution
- verified tool-level learning; raw event learning is marked unverified until replayed
- structured run events, audit log, policy gate, snapshots, OCR, app adapters, and eval cases

### Suggested First Demo

Use safe local applications:

1. Open TextEdit or Notes.
2. Create a short note.
3. Save or confirm the note exists.
4. Open Finder.
5. Locate or create a test folder.
6. Open Safari.
7. Navigate to a local test page.
8. Return to the original app and verify the note.

This demo is intentionally simple. The important part is whether the AI can observe, act, and verify across apps without relying only on fixed coordinates.

## First Phase Work Breakdown

### Runtime Team

- create a persistent native app or background agent
- expose local control API for submitting user goals
- manage model provider configuration
- own task lifecycle and cancellation
- write structured logs for every step

### Observation Team

- read active app and focused window
- inspect Accessibility nodes through AXUIElement
- capture screen/window state through Screen Recording permission
- normalize observations into a stable JSON schema
- mark unavailable or low-confidence observations explicitly

### Actuation Team

- implement Apple Events or Shortcuts actions first
- implement app URL scheme or app-specific adapters where useful
- implement Accessibility action execution
- add keyboard/mouse injection as fallback
- require the orchestrator to verify after every action

### Orchestrator Team

- translate user goals into small executable steps
- choose tools based on observation state
- record expected result for each step
- call verifier after every action
- recover or ask for user help when verification fails

### Permission And Safety Team

- define allowed apps and tools for MVP
- design permission onboarding for Accessibility, Screen Recording, and Automation
- block sensitive surfaces by default
- add user confirmation for risky actions
- implement emergency stop
- make audit logs easy to inspect

## Core Interfaces

The first implementation should keep module boundaries explicit.

### Observation Schema

```json
{
  "session": "macos-user-session-id",
  "active_app": "TextEdit",
  "bundle_id": "com.apple.TextEdit",
  "active_window": "Untitled",
  "focused_element": {},
  "accessibility_tree": {},
  "screen": {
    "available": true,
    "source": "screen-recording-permission"
  },
  "automation_permissions": {
    "com.apple.TextEdit": "granted"
  }
}
```

### Action Schema

```json
{
  "type": "accessibility.press",
  "target": {
    "element_id": "stable-or-session-element-id",
    "label": "Save"
  },
  "expected_result": "save-dialog-open"
}
```

### Verification Result

```json
{
  "success": true,
  "evidence": "Save dialog is visible",
  "next_state": "awaiting-file-name"
}
```

## Development Plan

### Phase 1: Prove The Loop

1. Build a persistent macOS app or background agent.
2. Request and verify Accessibility permission.
3. Request and verify Screen Recording permission.
4. Observe active app, window, and Accessibility tree.
5. Execute basic actions through Apple Events, Shortcuts, Accessibility, or fallback input.
6. Verify that the AI can complete multi-step workflows in one desktop session.

### Phase 2: Harden The Runtime

1. Add a tool registry.
2. Add memory and task state.
3. Add an audit log.
4. Add confirmation gates for sensitive actions.
5. Add recovery behavior when the UI changes unexpectedly.

### Phase 3: Expand System Reach

1. Add app-specific adapters for Finder, Safari, Notes, Calendar, Mail, and Terminal.
2. Prefer Apple Events, Shortcuts, and app APIs before visual automation.
3. Add notification, clipboard, and file-state observation with policy gates.
4. Improve handling of multiple displays, Spaces, Stage Manager, and full-screen apps.

### Phase 4: Package As A Trusted Product

1. Sign and notarize the app.
2. Add login item or LaunchAgent behavior.
3. Add privileged helper only if a specific system operation requires it.
4. Add MDM/enterprise deployment notes if needed.

## Directory Map

- `00-references/`: cloned/reference repositories if needed later
- `01-system-runtime/`: native app, LaunchAgent, helper services, runtime hosting
- `02-observation/`: Accessibility tree, screenshots, OCR, notifications, clipboard, window state
- `03-actuation/`: Apple Events, Shortcuts, Accessibility actions, keyboard/mouse fallback
- `04-agent-orchestrator/`: planner, tool registry, memory, verification loop
- `05-permission-safety/`: TCC permissions, user confirmation, sandboxing, audit logs
- `06-prototypes/`: small experiments before committing to architecture

## Real Device Testing

### Test Hardware

- one spare Mac or isolated test user account
- one macOS version matching the target user base
- one Apple Silicon Mac if available
- one fast emergency stop path

### Minimum System-Level Validation

- [ ] The AI runs as a persistent app/service, not only as a foreground chat UI.
- [ ] The AI can observe the active desktop session.
- [ ] The AI can read Accessibility tree data from at least one GUI app.
- [ ] The AI can capture screen/window state through Screen Recording permission.
- [ ] The AI can execute at least one semantic action through Apple Events, Shortcuts, app API, or Accessibility action.
- [ ] The AI can fall back to keyboard/mouse input only when semantic actions are not available.
- [ ] The AI re-observes state after each action.
- [ ] The AI can verify success or detect failure.
- [ ] The AI can operate across at least two unrelated apps in one workflow.
- [ ] The AI writes an audit log for observations, decisions, actions, and verification.

### Full System-Level Acceptance

- [ ] The app or agent starts after login.
- [ ] The app handles permission denial and permission revocation clearly.
- [ ] The app handles screen lock and unlock safely.
- [ ] The app recovers after target app crashes.
- [ ] The app recovers after window moves, resize events, Spaces changes, and focus changes.
- [ ] The app respects per-app Automation permissions.
- [ ] Sensitive actions require explicit user confirmation.
- [ ] Passwords, payments, banking, secure input, and private data paths are protected.
- [ ] The user can stop the AI immediately through a reliable emergency stop path.
- [ ] Logs are complete enough to replay failures.
- [ ] The same task can run repeatedly without coordinate-specific assumptions.
- [ ] The app can run in shadow mode for debugging.
- [ ] The app can be signed, notarized, and installed cleanly.

### Test Order

1. Shadow mode: observe the desktop and log planned actions without executing them.
2. Safe mode: operate only on harmless apps such as TextEdit, Finder, Safari, Notes, and Terminal.
3. Session mode: complete multi-step workflows across multiple apps in one login session.
4. Recovery mode: re-test after window moves, Spaces changes, app crashes, notifications, and logout/login.
5. Persistence mode: verify the agent starts after login and still behaves correctly.

### What To Measure

- whether the AI can identify the correct app, window, and UI element
- whether the action succeeded without manual correction
- whether the verification step catches mismatches
- whether permission prompts and failures are understandable
- whether logs are complete enough to replay failures

## Development Notes

macOS is the fastest desktop path for a polished prototype, but it is not an open OS in the same way Linux and Android are. Treat TCC, Accessibility, Screen Recording, Automation prompts, code signing, and notarization as core platform features rather than afterthoughts.

## Key Risks

- Accessibility trees may be incomplete or inconsistent across apps.
- TCC permissions can be revoked or denied by the user.
- Screen Recording and Automation permissions require clear onboarding.
- Secure input can block keyboard observation and should be respected.
- Coordinate-based actions are fragile and should not become the default path.
- App Store sandboxing may conflict with broad automation goals.

## Done Criteria For Phase 1

Phase 1 is done only when all of the following are true:

- the app or agent can start and stop cleanly
- required permissions are requested and detected correctly
- the agent can observe at least two unrelated GUI apps
- the agent can complete one multi-app task
- each action is followed by a verification step
- failures are logged with enough context to replay the issue
- a user can stop execution immediately
- no kernel extension or invasive system modification is required
