import AppKit
import Foundation

struct RoutineJob: Codable {
    var id: String
    var name: String
    var goal: String
    var schedule: String
    var triggerKind: String
    var triggerValue: String
    var enabled: Bool
    var cooldownSeconds: Int
    var lastRunAt: String?
    var nextRunAt: String?
    var lastObservedValue: String?
    var lastRunID: String?
    var lastStatus: String
    var lastError: String?
    var runCount: Int
    var notes: String
    var createdAt: String
    var updatedAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "name": name,
            "goal": goal,
            "schedule": schedule,
            "trigger_kind": triggerKind,
            "trigger_value": triggerValue,
            "enabled": enabled ? "true" : "false",
            "cooldown_seconds": "\(cooldownSeconds)",
            "last_run_at": lastRunAt ?? "",
            "next_run_at": nextRunAt ?? "",
            "last_observed_value": lastObservedValue ?? "",
            "last_run_id": lastRunID ?? "",
            "last_status": lastStatus,
            "last_error": lastError ?? "",
            "run_count": "\(runCount)",
            "notes": notes,
            "created_at": createdAt,
            "updated_at": updatedAt
        ]
    }
}

struct RoutineFire: Codable {
    let jobID: String
    let runID: String
    let goal: String
    let reason: String
    let firedAt: String

    var dictionary: [String: String] {
        [
            "job_id": jobID,
            "run_id": runID,
            "goal": goal,
            "reason": reason,
            "fired_at": firedAt
        ]
    }
}

struct RoutineStore {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("routines.json")
    }

    static func create(
        name: String,
        goal: String,
        schedule: String = "",
        triggerKind: String = "schedule",
        triggerValue: String = "",
        cooldownSeconds: Int = 60,
        enabled: Bool = true,
        notes: String = ""
    ) throws -> RoutineJob {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("goal is required")
        }
        let now = Date()
        let normalizedSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTrigger = normalizeForSearch(triggerKind.isEmpty ? "schedule" : triggerKind)
        let job = RoutineJob(
            id: "routine-\(normalizeID(name.isEmpty ? goal : name))-\(UUID().uuidString.prefix(8))",
            name: name.isEmpty ? goal : name,
            goal: goal,
            schedule: normalizedSchedule,
            triggerKind: normalizedTrigger,
            triggerValue: triggerValue,
            enabled: enabled,
            cooldownSeconds: max(1, cooldownSeconds),
            lastRunAt: nil,
            nextRunAt: nextFireDate(schedule: normalizedSchedule, after: now).map(isoDateString),
            lastObservedValue: observedValue(kind: normalizedTrigger, value: triggerValue),
            lastRunID: nil,
            lastStatus: "created",
            lastError: nil,
            runCount: 0,
            notes: notes,
            createdAt: isoDateString(now),
            updatedAt: isoDateString(now)
        )
        var jobs = list()
        jobs.append(job)
        try write(jobs)
        return job
    }

    static func list() -> [RoutineJob] {
        guard let data = try? Data(contentsOf: url),
              let jobs = try? JSONDecoder().decode([RoutineJob].self, from: data)
        else { return [] }
        return jobs.sorted { lhs, rhs in
            let l = lhs.nextRunAt ?? lhs.updatedAt
            let r = rhs.nextRunAt ?? rhs.updatedAt
            return l < r
        }
    }

    @discardableResult
    static func remove(id: String) throws -> Bool {
        let before = list()
        let after = before.filter { $0.id != id }
        try write(after)
        return before.count != after.count
    }

    @discardableResult
    static func tick(now: Date = Date()) throws -> [RoutineFire] {
        var jobs = list()
        var fires: [RoutineFire] = []
        var changed = false
        for index in jobs.indices {
            var job = jobs[index]
            guard job.enabled else { continue }
            let evaluation = evaluate(job: job, now: now)
            if evaluation.observedValue != job.lastObservedValue {
                job.lastObservedValue = evaluation.observedValue
                changed = true
            }
            guard evaluation.shouldFire else {
                jobs[index] = job
                continue
            }
            do {
                let runID = try TaskQueue.submit(goal: job.goal)
                let firedAt = isoDateString(now)
                job.lastRunAt = firedAt
                job.lastRunID = runID
                job.lastStatus = "queued"
                job.lastError = nil
                job.runCount += 1
                job.updatedAt = firedAt
                if let next = nextFireDate(schedule: job.schedule, after: now) {
                    job.nextRunAt = isoDateString(next)
                } else if job.schedule.hasPrefix("at:") {
                    job.enabled = false
                    job.nextRunAt = nil
                }
                jobs[index] = job
                fires.append(RoutineFire(jobID: job.id, runID: runID, goal: job.goal, reason: evaluation.reason, firedAt: firedAt))
                changed = true
            } catch {
                job.lastStatus = "failed"
                job.lastError = error.localizedDescription
                job.updatedAt = isoDateString(now)
                jobs[index] = job
                changed = true
            }
        }
        if changed { try write(jobs) }
        return fires
    }

    static func status(limit: Int = 50) -> [String: String] {
        let jobs = Array(list().prefix(max(1, limit)))
        let nextWake = jobs.compactMap(\.nextRunAt).sorted().first ?? ""
        return [
            "schema": "aios.routines.v1",
            "root": url.path,
            "jobs": jsonStringValue(jobs.map(\.dictionary)),
            "job_count": "\(jobs.count)",
            "enabled_count": "\(jobs.filter(\.enabled).count)",
            "next_wake_at": nextWake,
            "supported_schedules": "every:<seconds>,at:<iso>,daily:HH:mm,weekly:mon@HH:mm,cron:<min hour day month weekday>",
            "supported_triggers": "schedule,file_exists,file_changed,app_running,frontmost_app"
        ]
    }

    static func nextWakeValues() -> [String] {
        list().compactMap { job in
            guard job.enabled, let value = job.nextRunAt, isoDate(from: value) != nil else { return nil }
            return value
        }
    }

    private static func write(_ jobs: [RoutineJob]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs.sorted { $0.createdAt < $1.createdAt }).write(to: url, options: [.atomic])
    }

    private static func evaluate(job: RoutineJob, now: Date) -> (shouldFire: Bool, reason: String, observedValue: String?) {
        guard cooldownElapsed(job: job, now: now) else {
            return (false, "cooldown", job.lastObservedValue)
        }
        let scheduleDue = job.nextRunAt.flatMap(isoDate(from:)).map { $0 <= now } ?? job.schedule.isEmpty
        switch job.triggerKind {
        case "", "schedule":
            return (scheduleDue, "schedule_due", job.lastObservedValue)
        case "file_exists":
            let exists = FileManager.default.fileExists(atPath: job.triggerValue.expandingTildeInPath)
            return (scheduleDue && exists, exists ? "file_exists" : "file_missing", exists ? "exists" : "missing")
        case "file_changed":
            let observed = observedValue(kind: job.triggerKind, value: job.triggerValue)
            let changed = observed != nil && job.lastObservedValue != nil && observed != job.lastObservedValue
            return (scheduleDue && changed, changed ? "file_changed" : "file_unchanged", observed)
        case "app_running":
            let running = appMatches(job.triggerValue)
            return (scheduleDue && running, running ? "app_running" : "app_not_running", running ? "running" : "not_running")
        case "frontmost_app":
            let front = frontmostMatches(job.triggerValue)
            return (scheduleDue && front, front ? "frontmost_app" : "frontmost_app_mismatch", front ? "frontmost" : "not_frontmost")
        default:
            return (false, "unsupported_trigger:\(job.triggerKind)", job.lastObservedValue)
        }
    }

    private static func cooldownElapsed(job: RoutineJob, now: Date) -> Bool {
        guard let lastRunAt = job.lastRunAt, let last = isoDate(from: lastRunAt) else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(max(1, job.cooldownSeconds))
    }

    private static func observedValue(kind: String, value: String) -> String? {
        switch kind {
        case "file_changed":
            let path = value.expandingTildeInPath
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.stringValue ?? ""
            let modified = (attrs[.modificationDate] as? Date).map { "\($0.timeIntervalSince1970)" } ?? ""
            return "\(path)|\(size)|\(modified)"
        case "file_exists":
            return FileManager.default.fileExists(atPath: value.expandingTildeInPath) ? "exists" : "missing"
        default:
            return nil
        }
    }

    private static func appMatches(_ query: String) -> Bool {
        let needle = normalizeForSearch(query)
        guard !needle.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains { app in
            normalizeForSearch([app.localizedName ?? "", app.bundleIdentifier ?? ""].joined(separator: " ")).contains(needle)
        }
    }

    private static func frontmostMatches(_ query: String) -> Bool {
        let needle = normalizeForSearch(query)
        guard !needle.isEmpty else { return false }
        let app = NSWorkspace.shared.frontmostApplication
        return normalizeForSearch([app?.localizedName ?? "", app?.bundleIdentifier ?? ""].joined(separator: " ")).contains(needle)
    }

    private static func nextFireDate(schedule: String, after date: Date) -> Date? {
        let trimmed = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("every:") {
            let seconds = Double(trimmed.dropFirst("every:".count)) ?? 60
            return date.addingTimeInterval(max(1, seconds))
        }
        if trimmed.hasPrefix("at:") {
            let text = String(trimmed.dropFirst("at:".count))
            guard let target = isoDate(from: text), target > date else { return nil }
            return target
        }
        if trimmed.hasPrefix("daily:") {
            return nextDaily(timeText: String(trimmed.dropFirst("daily:".count)), after: date)
        }
        if trimmed.hasPrefix("weekly:") {
            return nextWeekly(spec: String(trimmed.dropFirst("weekly:".count)), after: date)
        }
        if trimmed.hasPrefix("cron:") {
            return nextCron(spec: String(trimmed.dropFirst("cron:".count)), after: date)
        }
        return nil
    }

    private static func nextDaily(timeText: String, after date: Date) -> Date? {
        let parts = timeText.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = parts[0]
        components.minute = parts[1]
        guard let today = calendar.date(from: components) else { return nil }
        if today > date { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static func nextWeekly(spec: String, after date: Date) -> Date? {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let weekday = weekdayIndex(parts[0]),
              let daily = nextDaily(timeText: parts[1], after: date.addingTimeInterval(-7 * 86_400))
        else { return nil }
        let calendar = Calendar.current
        for offset in 0..<14 {
            guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let candidateWeekday = calendar.component(.weekday, from: candidateDay)
            guard candidateWeekday == weekday else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: candidateDay)
            let time = calendar.dateComponents([.hour, .minute], from: daily)
            components.hour = time.hour
            components.minute = time.minute
            if let candidate = calendar.date(from: components), candidate > date {
                return candidate
            }
        }
        return nil
    }

    private static func nextCron(spec: String, after date: Date) -> Date? {
        let fields = spec.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }
        var candidate = Calendar.current.date(byAdding: .minute, value: 1, to: date) ?? date.addingTimeInterval(60)
        candidate = floorToMinute(candidate)
        for _ in 0..<(366 * 24 * 60) {
            let comps = Calendar.current.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            if cronField(fields[0], matches: comps.minute ?? 0, kind: .minute),
               cronField(fields[1], matches: comps.hour ?? 0, kind: .hour),
               cronField(fields[2], matches: comps.day ?? 1, kind: .day),
               cronField(fields[3], matches: comps.month ?? 1, kind: .month),
               cronField(fields[4], matches: cronWeekday(comps.weekday ?? 1), kind: .weekday) {
                return candidate
            }
            candidate = Calendar.current.date(byAdding: .minute, value: 1, to: candidate) ?? candidate.addingTimeInterval(60)
        }
        return nil
    }

    private enum CronFieldKind {
        case minute, hour, day, month, weekday
    }

    private static func cronField(_ field: String, matches value: Int, kind: CronFieldKind) -> Bool {
        if field == "*" { return true }
        return field.split(separator: ",").contains { part in
            let text = String(part)
            if text.contains("/") {
                let pieces = text.split(separator: "/", maxSplits: 1).map(String.init)
                guard pieces.count == 2, let step = Int(pieces[1]), step > 0 else { return false }
                let base = pieces[0] == "*" ? range(for: kind) : parseCronValues(pieces[0], kind: kind)
                return base.contains(value) && value % step == 0
            }
            return parseCronValues(text, kind: kind).contains(value)
        }
    }

    private static func parseCronValues(_ text: String, kind: CronFieldKind) -> Set<Int> {
        if text == "*" { return range(for: kind) }
        if text.contains("-") {
            let parts = text.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            guard parts.count == 2 else { return [] }
            return Set(parts[0]...parts[1])
        }
        if let value = Int(text) { return [value] }
        if kind == .weekday, let value = weekdayIndex(text) {
            return [cronWeekdayFromCalendar(value)]
        }
        return []
    }

    private static func range(for kind: CronFieldKind) -> Set<Int> {
        switch kind {
        case .minute: return Set(0...59)
        case .hour: return Set(0...23)
        case .day: return Set(1...31)
        case .month: return Set(1...12)
        case .weekday: return Set(0...6)
        }
    }

    private static func weekdayIndex(_ text: String) -> Int? {
        let normalized = normalizeForSearch(text)
        let map = [
            "sun": 1, "sunday": 1, "0": 1, "7": 1,
            "mon": 2, "monday": 2, "1": 2,
            "tue": 3, "tuesday": 3, "2": 3,
            "wed": 4, "wednesday": 4, "3": 4,
            "thu": 5, "thursday": 5, "4": 5,
            "fri": 6, "friday": 6, "5": 6,
            "sat": 7, "saturday": 7, "6": 7
        ]
        return map[normalized]
    }

    private static func cronWeekday(_ calendarWeekday: Int) -> Int {
        calendarWeekday == 1 ? 0 : calendarWeekday - 1
    }

    private static func cronWeekdayFromCalendar(_ calendarWeekday: Int) -> Int {
        calendarWeekday == 1 ? 0 : calendarWeekday - 1
    }

    private static func floorToMinute(_ date: Date) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.second = 0
        comps.nanosecond = 0
        return Calendar.current.date(from: comps) ?? date
    }
}
