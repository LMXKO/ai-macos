# AIOS for macOS

AIOS 的目标是把 macOS 变成一个可被 AI 长时间、自动、可验证地驱动的工作环境。

它不是聊天窗口，也不是只会看截图点坐标的脚本机器人。这个项目要做的是一个 macOS AI 执行层：AI 接收你的任务，观察真实 App 和系统状态，选择最稳定的控制通道，跨多个软件推进任务，并在每个关键动作后验证结果。

一句话目标：

```text
AI 长时间、自动驱动 macOS 上的软件完成我的任务。
```

## 当前状态

主线原型在：

```text
06-prototypes/aios-llm-swift
```

这是一个 Swift 实现的 macOS computer-use runtime，已经具备：

- CLI、菜单栏 host、daemon worker、SwiftUI 控制台、MCP stdio server
- 长任务队列、checkpoint、resume、scheduled run、LaunchAgent、resident session
- routine/trigger：定时、文件变化、App 运行、前台 App 等触发条件
- ToolRegistry：统一工具表，暴露 macOS、浏览器、视觉、App adapter、recipe、memory、runtime 等工具
- service catalog：把超大的工具表按 Browser、Vision、Runtime、Skills、Recipes、Memory 等服务边界分组
- Chrome/CDP、Safari/AppleScript、AX、OCR、视觉 grounding、foreground input fallback
- background driver capsule：为 Figma/Blender/canvas/native non-AX surface 接入外部 CUA-compatible driver 或 app adapter
- App skill package 机制：内置和本地安装的 App adapter/selector/recipe/entrypoint
- App verifier contract：按 App/任务类型定义完成条件，而不是只信工具调用成功
- recipe workflow program：参数、pre/postcondition、fallback、recovery、stability、learn once/reuse
- learning workflow：用户演示一次，AIOS 抽象成 recipe，绑定 verifier，确认后复用或失败后修补
- memory/episode/context graph：长期任务上下文、偏好、App/工具/文件/recipe/outcome 关系
- cockpit/replay：运行历史、事件流、trajectory、dashboard、replay bundle、pause/resume/replan/branch/stop

当前最关键的边界也已经明确：公开 macOS API 不提供“任意 inactive/offscreen 非 AX 像素面”的万能后台点击。AIOS 对这类界面走 app adapter 或外部 CUA-compatible driver capsule；没有语义通道时才显式 opt-in 到 foreground coordinate action。

## 项目目录

```text
.
├── 00-references/              # 开源参考：Fazm、Ghost OS、CUA、Peekaboo、MacOS-MCP、Codex 等
├── 01-system-runtime/          # 系统运行层设计占位
├── 02-observation/             # 观察层设计占位
├── 03-actuation/               # 控制/执行层设计占位
├── 04-agent-orchestrator/      # Agent 编排层设计占位
├── 05-permission-safety/       # 权限/安全层设计占位
├── 06-prototypes/
│   └── aios-llm-swift/         # 当前主实现
├── LICENSE
└── README.md
```

`00-references` 用来对照产品形态和系统能力：

- `fazm-main`：最接近 Mac AI agent 产品形态，参考 routines/inbox/trigger/UX。
- `ghost-os-main`：参考“看你做一次，然后变 recipe”的学习闭环。
- `cua-main`：参考 computer-use driver、trajectory、eval、后台执行。
- `Peekaboo-main`：参考 macOS capture、visual observation、agent-visible evidence。
- `MacOS-MCP-main`：参考把 macOS 能力暴露成 MCP tools。
- `codex-main`：参考 tool registry、事件流、approval/policy、sandbox、长任务编排。
- `Agent-main`：参考 macOS Accessibility 驱动和本地 agent 实现。

## 核心架构

```text
User Goal
  -> Planner
  -> Durable Queue / Task Graph / Routine / Resident Session
  -> Tool Selection
  -> Policy Gate
  -> App Action
  -> Observation
  -> App-Specific Verification
  -> Recovery / Resume / Learn / Memory
  -> Delivery
```

### 1. Runtime

Runtime 负责让任务能长时间存在，而不是只在一次 LLM 对话里跑完。

主要模块：

- `Runtime/RuntimeStores.swift`：run、event、summary、checkpoint、queue、state root。
- `Runtime/LongRunDaemonStore.swift`：daemon tick，整合 queue、task graph、resident、routine。
- `Runtime/RoutineStore.swift`：durable routine/trigger。
- `Runtime/TaskGraphStore.swift`：DAG task graph 和 watcher。
- `Runtime/ResidentAgentStore.swift`：常驻 session，多次 wake/tick 持续推进。
- `Host/HostAndDesktopApp.swift`：菜单栏 host、daemon worker、SwiftUI console。

支持的长期形态：

- 立即执行：`aios "<goal>"`
- 队列执行：`aios submit "<goal>"` + `aios host`
- daemon tick：`aios daemon tick`
- 延迟执行：`runtime_pause`、`runtime_schedule`
- routine/trigger：`routine_create`、`long_task_trigger_create`
- resident session：`resident_agent_plan`、`resident_agent_tick`
- task graph watcher：`task_graph_create`、`long_task_watch`

### 2. Observation

Observation 层负责理解当前 macOS 状态。

主要通道：

- AX tree：App、window、focus、role、label、value、action。
- ScreenCaptureKit / screenshot：窗口或屏幕截图。
- OCR：读取屏幕/window/image 文字。
- visual grounding：OCR、AX hint、rectangle、layout、color saliency、sidecar model candidates。
- Browser/CDP：DOM、selector、iframe、shadow DOM、extract、wait。
- AppleScript/SDEF/ScriptingBridge：可脚本化 App 的语义状态。
- 文件系统：Finder、文件元信息、导出物验证。
- run event stream：历史 action/observation/verification。

相关模块：

- `Vision/VisualGrounding.swift`
- `Vision/VisualGrounderRuntime.swift`
- `Vision/VisualPerceptionEngine.swift`
- `Browser/BrowserRuntimeStore.swift`
- `Browser/BrowserAgentRuntime.swift`
- `Trajectory/TrajectoryEvidenceStore.swift`

### 3. Actuation

Actuation 层负责执行动作，优先级从语义到像素：

1. App-native API、URL scheme、Shortcuts、Apple Events
2. Chrome CDP / DOM / JavaScript
3. App skill adapter
4. Accessibility semantic action：AXPress、AXValue
5. menu command / keyboard shortcut
6. visual grounding 后的 foreground coordinate action
7. raw coordinate click/type/drag/scroll，最后手段

相关模块：

- `Control/BackgroundControlKernel.swift`
- `Control/BackgroundExecutionKernel.swift`
- `Control/BackgroundDriverBridge.swift`
- `Control/BackgroundDriverCapsule.swift`
- `Control/NativeBackgroundDriverKernel.swift`
- `Tools/ToolRegistry.swift`

对 native non-AX / canvas 面，AIOS 不假装可以用公开 API 完成真后台点击。它会生成 driver capsule request，交给 app adapter 或外部 CUA-compatible driver。

### 4. App Skills

App skill 是高频 App 的能力包：工具、selector、recipe、verifier、adapter entrypoint。

当前内置覆盖：

- Finder
- Chrome
- Safari
- Mail / Calendar
- TextEdit
- WeChat
- Lark / Feishu
- QQ
- Notes / Reminders
- WPS / Office / LibreOffice / Preview
- Xcode / JetBrains IDE
- Baidu Netdisk / Tencent Meeting / ToDesk
- Terminal
- Figma / Blender / canvas native surfaces

相关工具：

```bash
aios tool app_skill_list '{}'
aios tool app_skill_suggest '{"query":"send message in Lark"}'
aios tool app_skill_core_pack '{"install":false}'
aios tool app_skill_package_scaffold '{"id":"my-app","app_name":"My App"}'
aios tool app_skill_route '{"query":"Figma canvas edit","app_name":"Figma"}'
aios tool app_skill_execute_adapter '{"query":"Figma canvas","action":"observe"}'
```

相关模块：

- `Skills/AppSkillsTrajectoryStrategy.swift`
- `Skills/AppSkillPackageStore.swift`
- `Skills/AppSkillRuntime.swift`
- `Skills/AppSkillEcosystemStore.swift`

### 5. App-Specific Verification

长期自动任务真正可靠，靠的是 App-specific completion contract。

例子：

- 消息是否发到正确的人/群
- 文件是否真的创建或导出
- 日历事件是否真的存在
- 浏览器是否到达目标 URL/selector/text 状态
- canvas 对象/状态是否能被 adapter 或视觉 anchors 验证
- 网盘上传是否在目标列表或上传面板里显示完成

相关工具：

```bash
aios tool app_verifier_list '{"query":"chat"}'
aios tool app_verifier_plan '{"app_name":"Lark","effect":"message_sent","target":"Team","value":"weekly update"}'
aios tool app_verifier_evaluate '{"app_name":"Chrome","effect":"web_state_reached","url":"https://example.com"}'
```

相关模块：

- `Skills/AppVerifierStore.swift`
- `Agent/AgentLoop.swift` 中的 completion gate 和 verified delivery 约束

### 6. Browser Agent

Chrome/CDP 是当前最深的后台语义通道之一，适合 Web App。

能力：

- launch isolated Chrome with debugging port
- tabs/status/eval
- selector click/type/read
- observe/act/extract/wait
- selector cache
- Stagehand-style browser agent contract

相关工具：

```bash
aios tool browser_cdp_launch '{}'
aios tool browser_cdp_observe '{"query":"submit","max_results":10}'
aios tool browser_cdp_act '{"goal":"submit form","action":"click","query":"Submit"}'
aios tool browser_agent_contract '{"goal":"fill a web form","url":"https://example.com"}'
aios tool browser_agent_extract '{"goal":"read table","schema":"rows"}'
```

相关模块：

- `Browser/BrowserAgentContractStore.swift`
- `Browser/BrowserAgentRuntime.swift`
- `Browser/BrowserSelectorCacheStore.swift`

### 7. Visual Grounding

视觉 grounding 负责处理图标、canvas、图片按钮、复杂布局和非文本区域。

当前动作闭环：

- observe
- verify
- click
- type
- hover
- drag
- scroll
- long_press
- post_verify

可接模型：

- 内置 heuristic grounder：OCR + AX + rectangles + layout + color saliency
- OpenAI-compatible vision sidecar：`AIOS_VISION_BASE_URL` / `AIOS_VISION_MODEL`
- local ShowUI / UI-TARS / GUI grounder adapter：`AIOS_LOCAL_GROUNDER_COMMAND`

相关工具：

```bash
aios tool visual_ground_schema '{}'
aios tool visual_grounder_profiles '{}'
aios tool visual_grounder_run '{"surface":"canvas","query":"play button"}'
aios tool visual_ground_action '{"query":"play","action":"click","execute":false}'
aios tool visual_grounder_verify '{"query":"success state"}'
aios tool visual_grounder_feedback '{"candidate_id":"M1","success":true}'
```

相关模块：

- `Vision/VisualGrounding.swift`
- `Vision/VisualGrounderRuntime.swift`
- `Vision/VisualGroundingQualityStore.swift`

### 8. Recipes And Learning

Recipe 是可复用的 workflow program，不只是 prompt template。

Recipe 支持：

- 参数化
- precondition / postcondition
- verify tool / verify expression
- retries
- fallback tools
- recovery steps
- branch / loop
- stability score
- run outcome tracking
- promote / compile / refine / repair

Learning workflow 把 Ghost OS 式“看你做一次”产品化：

```text
start learning
  -> user demonstrates
  -> record tool steps or raw events
  -> synthesize recipe
  -> generalize parameters
  -> attach verifier plan
  -> user confirms
  -> future tasks select/reuse
  -> failures produce repair hints
```

相关工具：

```bash
aios tool learn_workflow_plan '{"goal":"send weekly report in Lark","app_name":"Lark","verifier_effect":"message_sent"}'
aios tool learn_workflow_start '{"title":"weekly lark report","goal":"send weekly report"}'
aios learn record wechat_stage_file '{"recipient":"Example Contact","path":"~/Downloads/example.docx"}'
aios learn stop send-file-learned
aios tool learn_workflow_finalize '{"recipe_id":"send-file-learned","verifier_effect":"message_sent"}'
aios tool recipe_program_select '{"goal":"send file to contact"}'
```

相关模块：

- `Learning/Learning.swift`
- `Learning/LearningWorkflowStore.swift`
- `Recipes/RecipeLearningEngine.swift`
- `Recipes/RecipeProgramStore.swift`
- `Recipes/RecipeAdaptationStore.swift`
- `Recipes/RecipeStabilityStore.swift`

### 9. Memory, Episode, Context Graph

Memory 层让长任务不是“每次重新认识世界”。

它记录：

- 可复用 workflow hint
- 成功/失败 episode
- App、工具、文件、recipe、目标、结果之间的图关系
- 用户偏好和任务上下文
- Shadow-style digest/context pack

相关工具：

```bash
aios tool memory_remember '{"kind":"workflow_hint","key":"TextEdit input","value":"Use AXValue first."}'
aios tool memory_semantic_recall '{"query":"Chrome web automation"}'
aios tool memory_context_pack '{"query":"long browser workflow"}'
aios tool shadow_episode_policy '{"goal":"watch a download and summarize it"}'
aios tool memory_shadow_capture '{"goal":"paused long task","trigger":"pause"}'
```

相关模块：

- `Memory/MemoryStores.swift`
- `Memory/MemoryIndexStore.swift`
- `Memory/EpisodeContextEngine.swift`
- `Memory/LongMemoryEngine.swift`
- `Memory/ShadowMemoryStore.swift`

### 10. Cockpit, Replay, Product Entry

Cockpit 是“我的 Mac AI 执行层”的操作面板。

当前入口：

- `aios app`：SwiftUI 控制台
- `aios host`：菜单栏 host，自动 drain queue
- `aios daemon`：无 UI daemon worker
- `aios launch-agent install`：登录后常驻
- MCP：`aios mcp`

Cockpit 现在能看到：

- runs / queue / task graphs
- resident sessions
- routines / triggers
- learning workflows
- verifier contracts
- dashboard
- checkpoint
- trajectory / replay plan
- background driver receipts
- memory / app skills / artifacts
- pause / resume / feedback / replan / branch / stop / tick daemon

相关模块：

- `Platform/CockpitDashboardStore.swift`
- `Platform/CockpitControlStore.swift`
- `Platform/SessionProtocolStore.swift`
- `Trajectory/ReplayableSessionBundleStore.swift`
- `Trajectory/TrajectoryReplayEngine.swift`

## 快速开始

```bash
cd 06-prototypes/aios-llm-swift
swift build
```

在这个 Codex workspace 中，SwiftPM 有时需要：

```bash
swift run --disable-sandbox aios doctor
```

配置 OpenAI-compatible 模型：

```bash
export AIOS_LLM_BASE_URL="https://api.example.com/v1"
export AIOS_LLM_MODEL="example-chat-model"
export AIOS_LLM_API_KEY="replace-with-your-local-key"
export AIOS_MAX_STEPS="20"
```

可选视觉模型：

```bash
export AIOS_VISION_BASE_URL="https://vision-compatible.example.com/v1"
export AIOS_VISION_MODEL="example-vision-model"
export AIOS_VISION_API_KEY="replace-with-your-local-key"
```

运行：

```bash
swift run --disable-sandbox aios app
swift run --disable-sandbox aios host
swift run --disable-sandbox aios daemon
swift run --disable-sandbox aios submit "在 TextEdit 写一段项目说明，保存到桌面，并用 Finder 验证"
swift run --disable-sandbox aios runs
swift run --disable-sandbox aios show <run_id>
swift run --disable-sandbox aios resume <run_id>
```

MCP server：

```bash
swift run --disable-sandbox aios mcp
```

工具调用：

```bash
swift run --disable-sandbox aios tool long_agent_capability_matrix '{"goal":"AI长时间自动驱动mac上的软件完成任务"}'
swift run --disable-sandbox aios tool tool_service_catalog '{}'
swift run --disable-sandbox aios tool cockpit_dashboard '{"limit":5}'
swift run --disable-sandbox aios tool routine_list '{}'
swift run --disable-sandbox aios tool app_verifier_list '{"limit":5}'
```

本地测试状态目录：

```bash
AIOS_STATE_DIR=$PWD/.aios-state swift run --disable-sandbox aios tool routine_list '{}'
```

## 状态目录

默认状态目录：

```text
~/Library/Application Support/AIOS
```

主要内容：

```text
queue/*.json                         # 待执行任务
runs/<run_id>/events.jsonl           # 事件流
runs/<run_id>/summary.json           # run 摘要
runs/<run_id>/checkpoint.json        # 可恢复 checkpoint
runs.sqlite                          # run 索引
routines.json                        # durable routines/triggers
resident-agent-sessions.json         # resident sessions
task-graphs.json                     # task graphs
recipes/*.json                       # recipes / workflow programs
recipes/learning-records.jsonl       # recipe learning records
learning/workflow-records.json       # learning workflows
learning/raw/*.json                  # raw CGEvent traces
memory/*.jsonl                       # memory / semantic index
episodes/*.json                      # task episodes
context-graph/*.json                 # graph nodes/edges
app-skills/*.json                    # installed app skill manifests
app-skills/packages/*                # app skill packages
vision-ui-maps/*                     # visual UI map cache
background-driver-receipts.jsonl     # driver capsule receipts
trajectories/*                       # replay/session artifacts
evals/*                              # eval result/cases
audit.jsonl                          # tool-call audit log
```

## 常用命令

```bash
# 健康检查
swift run --disable-sandbox aios doctor
swift run --disable-sandbox aios doctor --request-permissions

# 后台运行
swift run --disable-sandbox aios host
swift run --disable-sandbox aios daemon
swift run --disable-sandbox aios daemon tick
swift run --disable-sandbox aios launch-agent install
swift run --disable-sandbox aios launch-agent status

# 任务
swift run --disable-sandbox aios submit "整理下载目录并给出摘要"
swift run --disable-sandbox aios runs
swift run --disable-sandbox aios show <run_id>
swift run --disable-sandbox aios resume <run_id>
swift run --disable-sandbox aios cancel <run_id>

# Routine / trigger
swift run --disable-sandbox aios tool routine_create '{"name":"daily summary","goal":"总结今天的新文件","schedule":"daily:18:00"}'
swift run --disable-sandbox aios tool long_task_trigger_create '{"goal":"看到报告文件后总结","trigger_kind":"file_exists","trigger_value":"~/Downloads/report.pdf"}'
swift run --disable-sandbox aios tool routine_tick '{}'

# App skill / verifier
swift run --disable-sandbox aios tool app_skill_core_pack '{"install":false}'
swift run --disable-sandbox aios tool app_verifier_plan '{"app_name":"Lark","effect":"message_sent","target":"Team","value":"weekly update"}'

# Visual / background driver
swift run --disable-sandbox aios tool background_driver_capsule '{}'
swift run --disable-sandbox aios tool background_driver_dispatch '{"app_name":"Figma","surface":"canvas","action":"click","query":"play","dry_run":true}'
swift run --disable-sandbox aios tool visual_ground_action '{"query":"submit","action":"click","execute":false}'

# Learning / recipe
swift run --disable-sandbox aios tool learn_workflow_plan '{"goal":"send weekly report in Lark","app_name":"Lark","verifier_effect":"message_sent"}'
swift run --disable-sandbox aios recipe list
swift run --disable-sandbox aios recipe suggest "把文档导出 PDF"
swift run --disable-sandbox aios eval run
```

## Tool Service Map

`ToolRegistry.swift` 仍然是 model-visible schema 的集中入口，但服务边界已经单独建模：

```text
Tools/ToolServiceCatalog.swift
```

主要服务：

- `background-control`：后台驱动、driver capsule、control kernel
- `vision-grounding`：OCR、screenshot、visual candidates/action/verify
- `browser-agent`：Chrome CDP、Safari、Stagehand-style browser runtime
- `resident-runtime`：long run、routine、task graph、resident session
- `cockpit`：dashboard、session、trajectory、replay
- `app-skills`：App skill package、adapter、verifier contract
- `native-app-adapters`：Finder、Mail、Calendar、WeChat、Lark、QQ、Office、IDE、网盘等
- `recipes-learning`：recipe、learning workflow、stability/repair
- `memory`：memory、episode、context graph、shadow digest

查看服务分组：

```bash
swift run --disable-sandbox aios tool tool_service_catalog '{}'
swift run --disable-sandbox aios tool tool_service_catalog '{"tool":"app_verifier_plan"}'
```

## 当前可证明能力

已经能证明的主线能力：

- 用 AX/AppleScript/CDP/visual fallback 操作真实 macOS App
- 对 Chrome Web App 做无光标、无焦点的 DOM 控制
- 对消息类 App 执行搜索、打开、发送、近期消息验证
- 对 Finder、TextEdit、Mail、Calendar、Notes、Reminders、Office/LibreOffice/Preview、IDE 等做第一批 adapter
- 用 verifier contract 把“完成”定义到 App 语义层
- 记录完整 run events，并从中导出 trajectory/replay/session
- 长任务 checkpoint/resume/schedule/daemon tick
- routine/trigger 驱动多次 wake/tick
- 将一次成功轨迹或用户演示提升为 recipe program
- 维护长期 memory、episode、context graph
- 将能力通过 MCP 暴露给外部 agent

## 仍需继续加厚的方向

不是“有没有框架”，而是“覆盖厚度和真实 App 成功率”：

- 为 Figma、Blender、Electron/canvas 非 AX 区域补真实 app adapter 或接入外部 CUA driver。
- 为高频 App 继续加 selectors、recipes、verifiers、fallback，而不是只有 open/send。
- 把 learning workflow 做进 UI：开始学习、录制、抽参数、确认、复用、失败修补。
- 接入默认可用的 GUI grounding 模型，让 ShowUI/UI-TARS/OmniParser 类能力开箱可接。
- 把 ToolRegistry 的执行实现继续拆到 BrowserService、AXService、InputService、RecipeService、MemoryService、AppAdapterService、DriverService。
- 把 cockpit 做成更贴近日常使用的 floating control bar、任务历史、例行任务面板、实时状态和远程触发入口。

## 设计原则

- 语义通道优先，坐标最后。
- 每个动作都要有 observation 和 verification。
- 长任务必须可暂停、可恢复、可审计、可 replay。
- 成功经验要沉淀成 recipe、memory、app skill，而不是下次重来。
- App-specific verifier 是可靠性的核心，不把“工具调用成功”等同于“任务完成”。
- 对 macOS 真实边界保持诚实：TCC、Secure Input、sandbox、DRM、支付/密码/银行等保护不能绕过。

## 许可证

见 [LICENSE](LICENSE)。
