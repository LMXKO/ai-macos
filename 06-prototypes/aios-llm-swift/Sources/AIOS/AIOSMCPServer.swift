import Foundation

@MainActor
final class AIOSMCPServer {
    private let registry = ToolRegistry()

    func run() {
        while let request = readMessage() {
            guard let id = request["id"] else {
                continue
            }
            let method = request["method"] as? String ?? ""
            do {
                let result = try handle(method: method, params: request["params"] as? [String: Any] ?? [:])
                writeResponse(id: id, result: result)
            } catch {
                writeError(id: id, code: -32000, message: error.localizedDescription)
            }
        }
    }

    private func handle(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "aios-macos",
                    "version": "0.1.0"
                ]
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": registry.definitions.compactMap(mcpTool(from:))]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw RuntimeError("tools/call requires params.name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = registry.execute(ToolCall(id: "mcp", name: name, arguments: arguments, raw: [:]))
            return [
                "content": [
                    [
                        "type": "text",
                        "text": result.jsonString
                    ]
                ],
                "isError": !result.success
            ]
        default:
            throw RuntimeError("Unsupported MCP method: \(method)")
        }
    }

    private func mcpTool(from definition: [String: Any]) -> [String: Any]? {
        guard let function = definition["function"] as? [String: Any],
              let name = function["name"] as? String
        else { return nil }
        return [
            "name": name,
            "description": function["description"] as? String ?? "",
            "inputSchema": function["parameters"] as? [String: Any] ?? [
                "type": "object",
                "properties": [:]
            ]
        ]
    }

    private func readMessage() -> [String: Any]? {
        var headerData = Data()
        let input = FileHandle.standardInput
        while true {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            headerData.append(byte)
            if headerData.suffix(4) == Data("\r\n\r\n".utf8) {
                break
            }
        }
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let contentLength = header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
        guard let contentLength, contentLength > 0 else { return nil }
        let body = input.readData(ofLength: contentLength)
        guard body.count == contentLength,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object
    }

    private func writeResponse(id: Any, result: [String: Any]) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    private func writeError(id: Any, code: Int, message: String) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func writeJSON(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        FileHandle.standardOutput.write(data)
    }
}
