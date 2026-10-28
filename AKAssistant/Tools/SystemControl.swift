import AppKit
import Carbon.HIToolbox
import IOKit.ps

/// Runs command-line tools (osascript, pmset, mdfind…) off the main thread.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        let error: String
        var ok: Bool { status == 0 }
    }

    static func run(_ path: String, _ arguments: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, output: "", error: error.localizedDescription))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    output: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    error: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }

    static func appleScript(_ source: String) async -> Result {
        await run("/usr/bin/osascript", ["-e", source])
    }

    /// macOS refused to let Duck Keyboard control another app (Privacy & Security › Automation).
    static func isAutomationDenied(_ result: Result) -> Bool {
        result.error.contains("-1743") || result.error.localizedCaseInsensitiveContains("not authorized")
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Presses keys as if you typed them. Needs the Accessibility permission Duck Keyboard already has.
enum KeySender {
    static func press(_ key: Int, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let code = CGKeyCode(key)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    /// Media and special keys (volume, brightness, play/pause), as on the keyboard's top row.
    enum Special: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7, play = 16, next = 17, previous = 18
    }

    static func press(_ key: Special, times: Int = 1) {
        for _ in 0..<max(1, times) {
            post(key, down: true)
            post(key, down: false)
        }
    }

    private static func post(_ key: Special, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (key.rawValue << 16) | ((down ? 0xa : 0xb) << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// Waits (up to ~0.3 s) until you've let go of ⌘ ⌥ ⌃ ⇧, so the held hotkey can't mix with the keys we press.
    static func waitForModifiersReleased() async {
        for _ in 0..<20 where !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}

/// Answers for "what's my battery", "how much space do I have", …
enum SystemInfo {
    static func time() -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "It's \(f.string(from: .now))."
    }

    static func date() -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        return "Today is \(f.string(from: .now))."
    }

    static func battery() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return "I couldn't read the battery."
        }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d["Type"] as? String) == "InternalBattery" else { continue }
            let current = d["Current Capacity"] as? Int ?? 0
            let maxCapacity = d["Max Capacity"] as? Int ?? 100
            let percent = maxCapacity > 0 ? Int((Double(current) / Double(maxCapacity) * 100).rounded()) : current
            let charging = d["Is Charging"] as? Bool ?? false
            let onPower = (d["Power Source State"] as? String) == "AC Power"
            var text = "Battery is at \(percent)%"
            if charging {
                text += " and charging"
                if let toFull = d["Time to Full Charge"] as? Int, toFull > 0 { text += ", full in about \(DurationText.spoken(Double(toFull * 60)))" }
            } else if onPower {
                text += ", plugged in"
            } else if let toEmpty = d["Time to Empty"] as? Int, toEmpty > 0 {
                text += ", about \(DurationText.spoken(Double(toEmpty * 60))) left"
            }
            return text + "."
        }
        return "This Mac doesn't have a battery; it's running on power."
    }

    static func storage() -> String {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else {
            return "I couldn't read the disk space."
        }
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if let total = values.volumeTotalCapacity {
            return "You have \(freeText) free of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))."
        }
        return "You have \(freeText) free."
    }

    static func memory() -> String {
        let bytes = Int64(ProcessInfo.processInfo.physicalMemory)
        return "This Mac has \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)) of memory."
    }

    static func uptime() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var seconds = ProcessInfo.processInfo.systemUptime
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            seconds = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }
        let days = Int(seconds) / 86_400
        let rest = seconds - Double(days * 86_400)
        let restText = DurationText.spoken((rest / 60).rounded() * 60)
        return "Your Mac has been on for " + (days > 0 ? "\(days) day\(days == 1 ? "" : "s") and \(restText)." : "\(restText).")
    }

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]
        let number = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        if let name = names[v.majorVersion] { return "You're on macOS \(name) \(number)." }
        return "You're on macOS \(number)."
    }

    static func ipAddress() -> String {
        var addresses: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "I couldn't read the network address." }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses[String(cString: entry.ifa_name)] = String(cString: host)
            }
        }
        guard let ip = addresses["en0"] ?? addresses["en1"] ?? addresses.values.sorted().first else {
            return "You don't seem to be connected to a network."
        }
        return "Your local IP address is \(ip)."
    }

    static func clipboard() -> String {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return "There's no text on your clipboard."
        }
        let short = text.count > 600 ? String(text.prefix(600)) + "…" : text
        return "Your clipboard has: \(short)"
    }
}
