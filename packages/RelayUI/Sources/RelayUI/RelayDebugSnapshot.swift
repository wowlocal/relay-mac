import Cocoa
import TGUIKit

#if DEBUG
/// Debug builds: on the distributed notification `org.relaychat.RelayMac.debug.snapshot` every visible window
/// writes its layer tree to `<directory>/relay-debug/window-<n>.png`, so the UI can be looked at from a shell that
/// has no screen recording permission (`tools/relay-mac-snapshot.sh`).
public enum RelayDebugSnapshot {
    private static var observer: NSObjectProtocol?

    private static func describe(_ view: NSView, depth: Int, into lines: inout [String]) {
        if depth > 40 || lines.count > 4000 {
            return
        }
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: view)) + " " + NSStringFromRect(view.frame)
        if view.isHidden {
            line += " hidden"
        }
        if let text = view as? NSTextField {
            line += " \"" + text.stringValue + "\""
        }
        if let text = view as? TextView, let string = text.textLayout?.attributedString.string {
            line += " \"" + string.prefix(120).replacingOccurrences(of: "\n", with: " ") + "\""
        }
        if let text = view as? NSTextView {
            line += " \"" + text.string.prefix(80) + "\""
        }
        lines.append(line)
        for subview in view.subviews {
            self.describe(subview, depth: depth + 1, into: &lines)
        }
    }

    public static func install(directory: String) {
        if self.observer != nil {
            return
        }
        let output = (directory as NSString).appendingPathComponent("relay-debug")
        self.observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.relaychat.RelayMac.debug.snapshot"), object: nil, queue: .main, using: { _ in
            try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            var index = 0
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else {
                    continue
                }
                let scale = window.backingScaleFactor
                let width = Int(view.bounds.width * scale)
                let height = Int(view.bounds.height * scale)
                guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    continue
                }
                context.scaleBy(x: scale, y: scale)
                if layer.isGeometryFlipped || view.isFlipped {
                    context.translateBy(x: 0.0, y: view.bounds.height)
                    context.scaleBy(x: 1.0, y: -1.0)
                }
                layer.render(in: context)
                guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    continue
                }
                try? data.write(to: URL(fileURLWithPath: (output as NSString).appendingPathComponent("window-\(index).png")))
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let cached = rep.representation(using: .png, properties: [:]) {
                        try? cached.write(to: URL(fileURLWithPath: (output as NSString).appendingPathComponent("window-\(index)-cached.png")))
                    }
                }
                var lines: [String] = []
                self.describe(view, depth: 0, into: &lines)
                try? lines.joined(separator: "\n").write(toFile: (output as NSString).appendingPathComponent("window-\(index).txt"), atomically: true, encoding: .utf8)
                index += 1
            }
        })
    }
}
#endif
