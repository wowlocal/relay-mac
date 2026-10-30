import Foundation
// Sends one command to a running debug build of Relay for macOS (RelayDebugRemote) and prints the answer:
//   relay-mac-remote action=open-chat query=Town\ Square
// Values come as key=value arguments; `password` may come from the environment (RELAY_REMOTE_PASSWORD) instead.
var command: [String: String] = ["id": UUID().uuidString]
for argument in CommandLine.arguments.dropFirst() {
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 {
        command[parts[0]] = parts[1]
    }
}
if command["password"] == nil, let password = ProcessInfo.processInfo.environment["RELAY_REMOTE_PASSWORD"] {
    command["password"] = password
}
let resultPath = NSHomeDirectory() + "/Library/Application Support/org.relaychat.RelayMac/debug/relay-debug/result.json"
let data = try! JSONSerialization.data(withJSONObject: command)
DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.relaychat.RelayMac.debug.command"), object: String(data: data, encoding: .utf8), userInfo: nil, deliverImmediately: true)
let deadline = Date().addingTimeInterval(Double(command["timeout"] ?? "10") ?? 10)
while Date() < deadline {
    if let result = FileManager.default.contents(atPath: resultPath), let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any], json["id"] as? String == command["id"] {
        print(String(data: result, encoding: .utf8) ?? "")
        exit((json["ok"] as? Bool) == true ? 0 : 1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
print("no answer")
exit(2)
