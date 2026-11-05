import Foundation

@main struct CodexLaunchTests {
    static func main() throws {
        // JSON's optional slash escapes are invalid TOML/Seatbelt escapes.
        precondition(CodexLaunch.quote("/tmp/HUD space") == "\"/tmp/HUD space\"")
        precondition(CodexLaunch.quote("/tmp/a\"b") == "\"/tmp/a\\\"b\"")
        let result = try CodexLaunch.disabledMCP("[mcp_servers.first]\nurl='synthetic'\n[mcp_servers.first.env]\nA='synthetic'\n[mcp_servers.\"second-tool\"] # comment\n")
        precondition(result == ["mcp_servers.\"second-tool\".enabled=false", "mcp_servers.first.enabled=false"])
        for text in ["mcp_servers = { first = {} }", "[mcp_servers]\nfirst = {}", "[profiles.a.mcp_servers.first]",
                     "mcp_servers.foo.url = 'https://synthetic.invalid'", "mcp_servers . foo . url = 'synthetic'",
                     "\"mcp_servers\".foo.url = 'synthetic'", "'mcp_servers'.foo.url = 'synthetic'",
                     #"["mcp_\u0073ervers".remote]"# + "\nurl='https://synthetic.invalid/mcp'",
                     #""mcp_\u0073ervers".remote.url='https://synthetic.invalid/mcp'"#,
                     #"["\U0000006dcp_servers".remote]"#,
                     #"[mcp_servers."escaped\u002dname"]"#,
                     #"profiles = { a = { "mcp_\u0073ervers" = {} } }"#,
                     #"note = """quote"""""# + "\n" + #"["mcp_\u0073ervers".remote]"#,
                     #"note = '''quote'''''"# + "\n" + #"["mcp_\u0073ervers".remote]"#] {
            do { _ = try CodexLaunch.disabledMCP(text); fatalError("Unsupported config must fail closed") } catch is AIError {}
        }
        for newline in ["\n", "\r\n"] {
            let escaped = ["# Configuration", #"["mcp\u005fservers".remote]"#, "url='https://synthetic.invalid'"].joined(separator: newline)
            do { _ = try CodexLaunch.disabledMCP(escaped); fatalError("Escaped server declaration must fail closed") } catch is AIError {}
            let normal = try CodexLaunch.disabledMCP("# Configuration" + newline + "[mcp_servers.remote]" + newline)
            precondition(normal == ["mcp_servers.remote.enabled=false"])
        }
        let empty = try CodexLaunch.disabledMCP("# [mcp_servers.ignored]\nmodel='synthetic'")
        precondition(empty.isEmpty)
        let values = #"""
        # ["mcp_\u0073ervers".comment]
        description = "unicode \u006dcp_servers and escaped quote \""
        list = [
          "\u006dcp_servers",
          { value = "escaped \u0061", other = "normal" }
        ]
        note = """multiline
        \u006dcp_servers = string content
        """
        literal = '''literal "quoted" content'''
        [mcp_servers.safe]
        url = "https://synthetic.invalid/\u0061"
        """#
        let allowed = try CodexLaunch.disabledMCP(values)
        precondition(allowed == ["mcp_servers.safe.enabled=false"])
        print("PASS launch boundary: escaped keys fail closed; escaped values/comments/multiline arrays remain supported; no real configuration or process")
    }
}
