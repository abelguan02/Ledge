import Foundation
@main struct SignatureTests {
    static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let host = try PeerSignature.requirement(at: app, identifier: "local.ledge.desktop")
        let service = try PeerSignature.requirement(at: app.appendingPathComponent("Contents/XPCServices/CodexService.xpc"), identifier: "local.ledge.desktop.CodexService")
        precondition(host.contains("cdhash H") && service.contains("cdhash H") && host != service)
        do { _ = try PeerSignature.requirement(at: app, identifier: "local.aihud.desktop"); fatalError("Ming identity must not be accepted") }
        catch is AIError { }
        print("PASS host/XPC signatures and wrong-identity rejection; app not launched")
    }
}
