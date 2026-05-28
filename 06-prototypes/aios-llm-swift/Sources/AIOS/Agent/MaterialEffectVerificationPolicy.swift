import Foundation

struct MaterialEffectVerificationPolicy {
    static var materialEffectKindList: [String] {
        materialEffectKinds.sorted()
    }

    static func requiresExplicitVerification(call: ToolCall, result: ToolResult, kind: String) -> Bool {
        guard materialEffectKinds.contains(kind) else { return false }
        if call.name == "app_skill_execute_adapter" { return true }
        if result.data["adapter_protocol_valid"] != nil || result.data["adapter_payload"] != nil {
            return true
        }
        return false
    }

    static func explicitlyVerified(_ result: ToolResult) -> Bool? {
        bool(result.data["verified"]) ?? bool(result.data["effect_verified"])
    }

    private static let materialEffectKinds: Set<String> = [
        "external_message_sent",
        "file_saved",
        "file_created",
        "file_exists",
        "folder_created",
        "pdf_exported",
        "calendar_event_created",
        "reminder_created",
        "note_created",
        "mail_draft_created",
        "shortcut_ran",
        "shell_command_submitted",
        "document_exported",
        "file_uploaded"
    ]
}
