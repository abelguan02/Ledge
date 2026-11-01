import Foundation

struct CodexLaunch {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    static func quote(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast().description
    }
    static func disabledMCP(_ text: String) throws -> [String] {
        try rejectEscapedKeys(text)
        let inline = try NSRegularExpression(pattern: #"(?m)^\s*(?:mcp_servers|"mcp_servers"|'mcp_servers')\s*(?:=|\.)"#)
        guard inline.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else {
            throw AIError.problem("Codex 使用了暂不支持的内联工具配置；HUD 未启用这些工具。")
        }
        let pattern = #"(?m)^\s*\[\s*mcp_servers\.("(?:\\.|[^"\\])*"|'[^']*'|[A-Za-z0-9_-]+)(?:\.[^\]]*)?\s*\](?:\s*#.*)?$"#
        let expression = try NSRegularExpression(pattern: pattern)
        var settings: Set<String> = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            settings.insert("mcp_servers.\(text[range]).enabled=false")
        }
        // Reject unfamiliar declarations instead of silently enabling tools.
        let declarations = text.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("#") && line.hasPrefix("[") && line.contains("mcp_servers")
        }
        guard declarations.count == expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) else {
            throw AIError.problem("Codex 工具配置格式尚未支持；未自动启用工具。")
        }
        return settings.sorted()
    }

    // The declaration matcher below intentionally supports only literal keys.
    // Lex key positions before matching: TOML basic quoted keys decode escapes,
    // so an escaped root must not silently bypass the MCP disable overrides.
    // Values (including multiline strings/arrays) and comments are not keys.
    private static func rejectEscapedKeys(_ text: String) throws {
        let chars = Array(text)
        var offset = 0
        var containers: [Character] = []
        var inValue = false, inHeader = false, multiline = false
        var quote: Character?
        while offset < chars.count {
            let char = chars[offset]
            if let delimiter = quote {
                if char == "\\" && delimiter == "\"" {
                    guard inValue else { throw AIError.problem("Codex 工具配置格式尚未支持：键名含转义字符；未自动启用工具。") }
                    offset += 2; continue
                }
                if char == delimiter {
                    if multiline {
                        if offset + 2 < chars.count, chars[offset + 1] == delimiter, chars[offset + 2] == delimiter {
                            // TOML permits one or two literal quotes immediately
                            // before the closing triple quote (runs of 4 or 5).
                            var end = offset + 3
                            while end < chars.count && end < offset + 5 && chars[end] == delimiter { end += 1 }
                            quote = nil; multiline = false; offset = end; continue
                        }
                    } else { quote = nil }
                }
                offset += 1; continue
            }
            if char == "#" {
                while offset < chars.count && chars[offset] != "\n" { offset += 1 }
                continue
            }
            if char == "\n" {
                if containers.isEmpty { inValue = false; inHeader = false }
            }
            else if char == "\"" || char == "'" {
                quote = char
                multiline = offset + 2 < chars.count && chars[offset + 1] == char && chars[offset + 2] == char
                if multiline {
                    guard inValue else { throw AIError.problem("Codex 工具配置格式尚未支持；未自动启用工具。") }
                    offset += 3; continue
                }
            } else if char == "=" && !inHeader { inValue = true }
            else if char == "[" {
                if inValue { containers.append(char) } else { inHeader = true }
            } else if char == "{" && inValue { containers.append(char); inValue = false }
            else if char == "]" && inHeader { inHeader = false; inValue = true }
            else if char == "]" || char == "}" { _ = containers.popLast(); inValue = true }
            else if char == "," && containers.last == "{" { inValue = false }
            offset += 1
        }
    }
    static func make(directory: URL) throws -> CodexLaunch {
        let binary = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw CodexConnectionError.unavailable }
        // Normal network and Codex-owned account maintenance are allowed. Tool
        // subprocesses remain disabled; this process is only a text assistant.
        let profile = "(version 1)(allow default)(deny process-exec)(allow process-exec (literal \(quote(binary))))"
        var settings = [
            "sqlite_home=\(quote(directory.path))", "log_dir=\(quote(directory.path))",
            "history.persistence=\"none\"", "analytics.enabled=false", "notify=[]",
            "model_provider=\"openai\"", "web_search=\"disabled\"", "project_doc_max_bytes=0",
            "skills.include_instructions=false", "features.skip_host_skill_discovery=true",
            "features.hooks=false", "features.codex_hooks=false", "features.plugin_hooks=false",
            "features.plugins=false", "features.apps=false", "features.connectors=false",
            "features.shell_snapshot=false", "features.shell_tool=false", "features.unified_exec=false",
            "features.js_repl=false", "features.multi_agent=false", "features.multi_agent_v2=false",
            "features.memory_tool=false", "features.tool_search=false", "features.skill_search=false"]
        // A blank table would MERGE with user MCP entries. Disable each declared
        // server explicitly, without exporting configuration or credentials.
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let config = home.appendingPathComponent("config.toml")
        if FileManager.default.fileExists(atPath: config.path) {
            let text = try String(contentsOf: config, encoding: .utf8)
            settings += try disabledMCP(text)
        }
        var env = CodexConnection.environment(ProcessInfo.processInfo.environment)
        env["TMPDIR"] = directory.path
        let args = ["-p", profile, binary, "app-server", "--stdio"] + settings.flatMap { ["-c", $0] }
        return CodexLaunch(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: args, environment: env)
    }
}
