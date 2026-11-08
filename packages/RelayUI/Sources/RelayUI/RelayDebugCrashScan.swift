import Foundation
import Darwin

#if DEBUG
/// Debug builds: on SIGBUS or SIGSEGV, writes the symbols of every code address found on the crashing thread's stack
/// (from its stack pointer up) to `<directory>/relay-debug/crash-scan.txt`, then lets the crash continue. For crashes
/// whose frame chain is gone (a jump through a dead pointer leaves pc, lr and fp unusable in the crash report).
public enum RelayDebugCrashScan {
    private static var path: [CChar] = []
    private static var alternateStack: UnsafeMutableRawPointer?

    public static func install(directory: String) {
        if self.alternateStack != nil {
            return
        }
        let output = (directory as NSString).appendingPathComponent("relay-debug")
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        self.path = Array((output as NSString).appendingPathComponent("crash-scan.txt").utf8CString)
        let size = 256 * 1024
        let stack = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        self.alternateStack = stack
        var alternate = stack_t(ss_sp: stack, ss_size: size, ss_flags: 0)
        sigaltstack(&alternate, nil)
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = relayDebugCrashHandler
        action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND
        sigemptyset(&action.sa_mask)
        sigaction(SIGBUS, &action, nil)
        sigaction(SIGSEGV, &action, nil)
    }

    fileprivate static func scan(_ context: UnsafeMutableRawPointer?) {
        let fd = self.path.withUnsafeBufferPointer { open($0.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        guard fd >= 0 else {
            return
        }
        func put(_ text: String) {
            var text = text
            text.withUTF8 { _ = write(fd, $0.baseAddress, $0.count) }
        }
        guard let context = context?.assumingMemoryBound(to: ucontext_t.self), let machine = context.pointee.uc_mcontext else {
            put("no context\n")
            close(fd)
            return
        }
        let state = machine.pointee.__ss
        put("pc 0x\(String(state.__pc, radix: 16)) lr 0x\(String(state.__lr, radix: 16)) fp 0x\(String(state.__fp, radix: 16)) sp 0x\(String(state.__sp, radix: 16))\n")
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let start = UInt(state.__sp)
        let end = min(top, start + 1024 * 1024)
        var address = start
        var found = 0
        while address + 8 <= end && found < 300 {
            let value = UnsafePointer<UInt>(bitPattern: address)!.pointee
            var info = Dl_info()
            if value > 0x100000000, value & 3 == 0, dladdr(UnsafeRawPointer(bitPattern: value), &info) != 0, let symbol = info.dli_sname, let image = info.dli_fname {
                let name = String(cString: symbol)
                let file = (String(cString: image) as NSString).lastPathComponent
                let offset = value - UInt(bitPattern: info.dli_saddr)
                if offset < 0x10000 {
                    put("[sp+0x\(String(address - start, radix: 16))] \(file) \(name) + \(offset)\n")
                    found += 1
                }
            }
            address += 8
        }
        close(fd)
    }
}

private func relayDebugCrashHandler(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    RelayDebugCrashScan.scan(context)
    raise(signal)
}
#endif
