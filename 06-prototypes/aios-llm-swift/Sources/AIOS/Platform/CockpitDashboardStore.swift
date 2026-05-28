import Foundation

struct CockpitDashboardStore {
    static var dashboardsURL: URL {
        EventStore.rootURL.appendingPathComponent("cockpit-dashboards", isDirectory: true)
    }

    static func dashboard(runID: String? = nil, limit: Int = 20) -> [String: String] {
        let summary = liveSummary(runID: runID, limit: limit)
        let live = CockpitControlStore.liveState(limit: limit)
        let runSnapshot: [String: String] = {
            guard let runID, !runID.isEmpty,
                  let snapshot = try? SessionProtocolStore.cockpitSnapshot(runID: runID, limit: limit)
            else { return [:] }
            return snapshot
        }()
        let artifacts = artifactRows(runID: runID, limit: limit)
        let commands = CockpitControlStore.list(runID: runID).prefix(max(1, limit)).map(\.dictionary)
        let resident = ResidentAgentStore.status(limit: limit)
        let routines = RoutineStore.status(limit: limit)
        let learning = LearnWorkflowStore.list(limit: limit).map(\.dictionary)
        let verifiers = AppVerifierStore.list(limit: limit).map(\.dictionary)
        let driverReceipts = BackgroundDriverCapsuleStore.recent(limit: limit)
        let workflows = LongAutomationWorkflowStore.catalog(goal: runID ?? "")
        return [
            "schema": "aios.cockpit.dashboard.v1",
            "run_id": runID ?? "",
            "summary": jsonStringValue(summary),
            "live": jsonStringValue(live),
            "run_snapshot": jsonStringValue(runSnapshot),
            "artifacts": jsonStringValue(artifacts),
            "commands": jsonStringValue(Array(commands)),
            "resident_runtime": jsonStringValue(resident),
            "routine_runtime": jsonStringValue(routines),
            "learning_workflows": jsonStringValue(learning),
            "verifier_contracts": jsonStringValue(verifiers),
            "background_receipts": jsonStringValue(driverReceipts),
            "workflow_catalog": jsonStringValue(workflows),
            "views": "operator_board,runs,queue,task_graphs,resident_sessions,routines,triggers,workflow_catalog,learning_workflows,verifier_contracts,current_step,screen_or_window_snapshot,plan_tree,memory_hits,recipe_hits,trajectory,replay,driver_receipts,artifacts,controls",
            "controls": "pause,resume,feedback,replan,branch,stop,takeover,continue,start_chat_workflow,start_browser_workflow,start_document_workflow,create_routine,tick_daemon,learn_workflow,verify_completion",
            "live_control_contract": "AgentLoop polls cockpit commands during execution; daemon tick advances queue/task_graph/routine/resident work; feedback/replan enters model context, pause/stop saves checkpoint immediately"
        ]
    }

    static func liveSummary(runID: String? = nil, limit: Int = 20) -> [String: String] {
        let runs = ((try? EventStore.listRuns()) ?? []).prefix(max(1, limit))
        let queue = TaskQueue.list()
        let readyQueue = queue.filter(\.ready)
        let futureQueue = queue.filter { !$0.ready }
        let daemon = LongRunDaemonStore.status()
        let resident = ResidentAgentStore.status(limit: limit)
        let residentRows = parseRows(resident["sessions"] ?? "[]")
        let activeResidents = residentRows.filter { row in
            !["complete", "canceled"].contains(row["status"] ?? "")
        }
        let routines = RoutineStore.list().filter(\.enabled)
        let selectedRun = runID.flatMap { id in runs.first { $0.id == id } }
        let artifacts = artifactRows(runID: runID, limit: limit)
        let driverReceipts = BackgroundDriverCapsuleStore.recent(limit: limit)
        let replayAvailable = runID.flatMap { id in
            ((try? TrajectoryStore.summarize(runID: id, limit: 1))?.isEmpty == false) ? "true" : "false"
        } ?? "false"
        let statusCounts = Dictionary(grouping: runs, by: \.status).mapValues(\.count)
        let cards: [[String: String]] = [
            [
                "id": "runs",
                "title": "Runs",
                "value": "\(runs.count)",
                "detail": statusCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            ],
            [
                "id": "queue",
                "title": "Queue",
                "value": "\(queue.count)",
                "detail": "ready=\(readyQueue.count),scheduled=\(futureQueue.count)"
            ],
            [
                "id": "daemon",
                "title": "Daemon",
                "value": daemon.status,
                "detail": "tick=\(daemon.tickCount),next=\(daemon.nextWakeAt ?? "")"
            ],
            [
                "id": "resident",
                "title": "Resident",
                "value": "\(activeResidents.count)",
                "detail": activeResidents.prefix(3).map { "\($0["id"] ?? ""):\($0["status"] ?? "")" }.joined(separator: ",")
            ],
            [
                "id": "workflows",
                "title": "Workflows",
                "value": "5",
                "detail": "chat,browser,document,resident,cockpit"
            ],
            [
                "id": "routines",
                "title": "Routines",
                "value": "\(routines.count)",
                "detail": RoutineStore.nextWakeValues().prefix(3).joined(separator: ",")
            ],
            [
                "id": "selected_run",
                "title": "Selected Run",
                "value": selectedRun?.status ?? "",
                "detail": selectedRun.map { "\($0.id.prefix(8)) \($0.goal)" } ?? ""
            ],
            [
                "id": "replay",
                "title": "Replay",
                "value": replayAvailable,
                "detail": "artifacts=\(artifacts.count),driver_receipts=\(driverReceipts.count)"
            ]
        ]
        return [
            "schema": "aios.cockpit.live_summary.v1",
            "run_id": runID ?? "",
            "cards": jsonStringValue(cards),
            "latest_runs": jsonStringValue(runs.map { run in
                [
                    "id": run.id,
                    "status": run.status,
                    "goal": run.goal,
                    "updated_at": run.updatedAt
                ]
            }),
            "queue": jsonStringValue(queue.prefix(limit).map(\.dictionary)),
            "resident_sessions": resident["sessions"] ?? "[]",
            "resident_observations": resident["observations"] ?? "[]",
            "routines": jsonStringValue(RoutineStore.status(limit: limit)),
            "daemon": jsonStringValue(daemon.dictionary),
            "selected_run": selectedRun.map { jsonStringValue([
                "id": $0.id,
                "goal": $0.goal,
                "status": $0.status,
                "updated_at": $0.updatedAt
            ]) } ?? "",
            "replay_available": replayAvailable,
            "operator_next_actions": "tick_daemon,resume_selected,export_replay_session,record_feedback,replan,branch,stop"
        ]
    }

    static func export(runID: String? = nil, limit: Int = 20) throws -> URL {
        let payload = dashboard(runID: runID, limit: limit)
        let id = runID?.isEmpty == false ? runID! : "global"
        let url = dashboardsURL.appendingPathComponent("\(id)-dashboard.json")
        try writeJSONObject(payload, to: url)
        return url
    }

    private static func artifactRows(runID: String?, limit: Int) -> [[String: String]] {
        var rows: [[String: String]] = []
        let roots = [
            EventStore.trajectoriesURL,
            EventStore.snapshotsURL,
            EventStore.recipesURL,
            EventStore.appSkillsURL
        ]
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls where rows.count < limit * 3 {
                let name = url.lastPathComponent
                if let runID, !runID.isEmpty, !name.contains(runID) { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                rows.append([
                    "name": name,
                    "path": url.path,
                    "kind": root.lastPathComponent,
                    "updated_at": values?.contentModificationDate.map(isoDateString) ?? "",
                    "bytes": "\(values?.fileSize ?? 0)"
                ])
            }
        }
        return Array(rows.prefix(limit))
    }

    private static func parseRows(_ json: String) -> [[String: String]] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.map { row in
            row.reduce(into: [String: String]()) { result, pair in
                if let value = pair.value as? String {
                    result[pair.key] = value
                } else if let value = pair.value as? NSNumber {
                    result[pair.key] = value.stringValue
                } else if JSONSerialization.isValidJSONObject(pair.value) {
                    result[pair.key] = jsonStringValue(pair.value)
                }
            }
        }
    }
}
