import Cocoa

#if DEBUG
/// Debug builds: commands from a shell (`tools/relay-mac-remote.swift`) on the distributed notification
/// `org.relaychat.RelayMac.debug.command`, whose object is the command as JSON (`{"action": "...", ...}`). The answer
/// goes to `<directory>/relay-debug/result.json` (`{"id", "ok", "error", "extra"}`). The app registers the actions
/// (`register`); `snapshot` is built in (RelayDebugSnapshot).
public enum RelayDebugRemote {
    public typealias Completion = (_ ok: Bool, _ error: String?, _ extra: [String: Any]) -> Void
    public typealias Handler = (_ command: [String: String], _ completion: @escaping Completion) -> Void

    private static var handlers: [String: Handler] = [:]
    private static var observer: NSObjectProtocol?
    private static var output: String = ""

    public static func register(_ action: String, _ handler: @escaping Handler) {
        self.handlers[action] = handler
    }

    public static func install(directory: String) {
        if self.observer != nil {
            return
        }
        self.output = (directory as NSString).appendingPathComponent("relay-debug")
        self.observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.relaychat.RelayMac.debug.command"), object: nil, queue: .main, using: { notification in
            guard let text = notification.object as? String, let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            var command: [String: String] = [:]
            for (key, value) in json {
                command[key] = "\(value)"
            }
            let id = command["id"] ?? ""
            let action = command["action"] ?? ""
            guard let handler = self.handlers[action] else {
                self.write(id: id, ok: false, error: "unknown action \(action)", extra: [:])
                return
            }
            handler(command, { ok, error, extra in
                self.write(id: id, ok: ok, error: error, extra: extra)
            })
        })
    }

    private static func write(id: String, ok: Bool, error: String?, extra: [String: Any]) {
        try? FileManager.default.createDirectory(atPath: self.output, withIntermediateDirectories: true)
        var result: [String: Any] = ["id": id, "ok": ok, "extra": extra]
        if let error {
            result["error"] = error
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: (self.output as NSString).appendingPathComponent("result.json")), options: .atomic)
    }
}
#endif
