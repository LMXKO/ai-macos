import Foundation

struct CockpitDashboardStore {
    static var dashboardsURL: URL {
        EventStore.rootURL.appendingPathComponent("cockpit-dashboards", isDirectory: true)
    }

    static func dashboard(runID: String? = nil, limit: Int = 20) -> [String: String] {
        let live = CockpitControlStore.liveState(limit: limit)
        let runSnapshot: [String: String] = {
            guard let runID, !runID.isEmpty,
                  let snapshot = try? SessionProtocolStore.cockpitSnapshot(runID: runID, limit: limit)
            else { return [:] }
            return snapshot
        }()
        let artifacts = artifactRows(runID: runID, limit: limit)
        return [
            "schema": "aios.cockpit.dashboard.v1",
            "run_id": runID ?? "",
            "live": jsonStringValue(live),
            "run_snapshot": jsonStringValue(runSnapshot),
            "artifacts": jsonStringValue(artifacts),
            "views": "runs,queue,task_graphs,current_step,screen_or_window_snapshot,plan_tree,memory_hits,recipe_hits,trajectory,replay,artifacts,controls",
            "controls": "pause,resume,feedback,replan,branch,stop,takeover,continue"
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
}
