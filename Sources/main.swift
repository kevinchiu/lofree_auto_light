// lofree-light: drive a Lofree keyboard's backlight from the MacBook's built-in keyboard backlight
// (lid open) or from a time-of-day schedule (lid closed).
//
// Protocol (reverse-engineered from Lofree's own web configurator, https://www.lofree.tech/keyboard/):
//   - The keyboard has a vendor HID collection (usage page 0xFF02) that takes 16-byte output reports with report ID 8:
//       [cmd, 0, addrHi, addrLo, len|0x80, data0..data9, checksum]
//       checksum = (0x55 - (sum(bytes 0..14) & 0xFF) - 8) & 0xFF
//   - cmd 7 writes the keyboard's settings memory:
//       0x2130 current light mode  [mode, 0x55-mode]
//       0x2132 light on/off        [state, 0x55-state]
//       0x2160 + mode*32           [colorIndex, speed, brightness(0-4), 0x55-sum]
//
// Transport: the report is sent as a plain USB HID SET_REPORT control transfer to the device, not through
// macOS's HID stack. Opening the HID interface would require Input Monitoring permission, because the same
// USB interface also carries keystrokes. A USB control transfer needs no permission, but it is write-only:
// the keyboard's replies arrive on the interrupt endpoint owned by the HID driver, and the firmware answers
// GET_REPORT with zeros. So this tool cannot read the keyboard's current settings; it only writes them.
//
// Built-in backlight: read through CoreBrightness's private KeyboardBrightnessClient, which needs no permission.

import Foundation
import IOKit
import IOUSBHost

struct LofreeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

// MARK: - USB transport

final class Keyboard {
    static let reportID: UInt8 = 8
    static let vendorUsagePage = 0xFF02
    // USB IDs that Lofree's web configurator lists for its wired keyboards (its 2.4 GHz dongle ID 0xFA0A is
    // left out, untested). The IDs aren't unique to Lofree: 0x05AC is Apple's, and 0x3554 is shared with other
    // products on the same chip family, Lofree's own mice included (different product IDs, different memory
    // map). Writing keyboard addresses to one of those could corrupt its settings, so a device must match a
    // listed vendor ID, a listed keyboard product ID, and say "Lofree" in its name.
    static let keyboardVendorIDs: Set<Int> = [0x05AC, 0x3554, 0x388D]
    static let keyboardProductIDs: Set<Int> = [0x024F, 0xF811, 0x0008, 0x0009, 0x0011, 0x0012, 0x0014, 0x0015]

    private let device: IOUSBHostDevice
    private let interfaceNumber: UInt16

    static var isConnected: Bool {
        guard let (service, _) = findService() else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Opens the first USB-attached Lofree keyboard. Returns nil when none is attached.
    static func open() throws -> Keyboard? {
        guard let (service, interfaceNumber) = findService() else { return nil }
        do {
            // Owning the USB device does not touch its HID interfaces, so typing keeps working.
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            return Keyboard(device: device, interfaceNumber: interfaceNumber)
        } catch {
            throw LofreeError("could not open the keyboard's USB device (\(error.localizedDescription))")
        }
    }

    private init(device: IOUSBHostDevice, interfaceNumber: UInt16) {
        self.device = device
        self.interfaceNumber = interfaceNumber
    }

    deinit { device.destroy() }

    /// Finds a Lofree USB device and the number of its interface that carries the vendor collection.
    private static func findService() -> (io_service_t, UInt16)? {
        var devices: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(devices) }

        while case let dev = IOIteratorNext(devices), dev != 0 {
            let name = registryProperty(dev, "USB Product Name") as? String ?? ""
            let vid = registryProperty(dev, "idVendor") as? Int ?? 0
            let pid = registryProperty(dev, "idProduct") as? Int ?? 0
            if name.localizedCaseInsensitiveContains("lofree"), keyboardVendorIDs.contains(vid), keyboardProductIDs.contains(pid),
               let iface = vendorInterface(of: dev) {
                return (dev, iface)
            }
            IOObjectRelease(dev)
        }
        return nil
    }

    private static func vendorInterface(of dev: io_service_t) -> UInt16? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(dev, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }

        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard let number = registryProperty(child, "bInterfaceNumber") as? Int else { continue }
            let pairs = IORegistryEntrySearchCFProperty(child, kIOServicePlane, "DeviceUsagePairs" as CFString,
                                                        kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
            if let pairs = pairs as? [[String: Any]],
               pairs.contains(where: { $0["DeviceUsagePage"] as? Int == vendorUsagePage }) {
                return UInt16(number)
            }
        }
        return nil
    }

    private static func checksum(_ p: [UInt8]) -> UInt8 {
        let sum = p[0..<15].reduce(0) { $0 + Int($1) } & 0xFF
        return UInt8(truncatingIfNeeded: 0x55 - sum - 8)
    }

    /// Writes `data` (at most 10 bytes) to the keyboard's settings memory at `addr`.
    func write(_ addr: Int, _ data: [UInt8]) throws {
        precondition(data.count <= 10)
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = 7 // WriteFlashData
        p[2] = UInt8((addr >> 8) & 0xFF)
        p[3] = UInt8(addr & 0xFF)
        p[4] = UInt8(data.count | 0x80)
        for (i, b) in data.enumerated() { p[5 + i] = b }
        p[15] = Keyboard.checksum(p)

        let report = [Keyboard.reportID] + p
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x21                      // host-to-device, class, interface
        request.bRequest = 0x09                           // HID SET_REPORT
        request.wValue = 0x0200 | UInt16(Keyboard.reportID) // output report, ID 8
        request.wIndex = interfaceNumber
        request.wLength = UInt16(report.count)

        var sent = 0
        do {
            try device.__send(request, data: NSMutableData(bytes: report, length: report.count),
                              bytesTransferred: &sent, completionTimeout: 1.0)
        } catch {
            throw LofreeError("sending to keyboard failed (\(error.localizedDescription))")
        }
        guard sent == report.count else { throw LofreeError("keyboard accepted \(sent) of \(report.count) bytes") }
        usleep(20_000) // the web configurator waits for each reply; we can't see replies, so pace the writes instead
    }
}

// MARK: - Lofree backlight

enum Level: Equatable, CustomStringConvertible, Decodable {
    case off
    case brightness(Int)
    static let range = 0...4

    init(parsing s: String) throws {
        if s.lowercased() == "off" { self = .off; return }
        guard let n = Int(s), Level.range.contains(n) else {
            throw LofreeError("level must be off or \(Level.range.lowerBound)-\(Level.range.upperBound), got \"\(s)\"")
        }
        self = .brightness(n)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { try self.init(parsing: String(n)) } else { try self.init(parsing: c.decode(String.self)) }
    }

    var description: String {
        switch self {
        case .off: return "off"
        case .brightness(let n): return "\(n)"
        }
    }
}

struct Backlight {
    static let modeAddr = 0x2130, stateAddr = 0x2132, effectBase = 0x2160

    // Brightness is stored per light mode, and the current mode can't be read back over this transport,
    // so brightness changes pin the keyboard to one mode. These are the values this keyboard was set to
    // (mode 0, color index 0, speed 2).
    static let mode = 0, colorIndex: UInt8 = 0, speed: UInt8 = 2

    let kb: Keyboard

    /// Writes `level`. `previous` is what this process last wrote, if anything; it lets brightness-only
    /// changes skip the mode and on/off writes, to keep wear on the keyboard's flash down.
    func apply(_ level: Level, previous: Level? = nil) throws {
        switch level {
        case .off:
            try kb.write(Backlight.stateAddr, [0, 0x55])
        case .brightness(let n):
            var wasOn = false
            if case .brightness? = previous { wasOn = true }
            if !wasOn {
                let m = UInt8(Backlight.mode)
                try kb.write(Backlight.modeAddr, [m, 0x55 &- m])
            }
            var effect = [Backlight.colorIndex, Backlight.speed, UInt8(n)]
            effect.append(UInt8(truncatingIfNeeded: 0x55 - effect.reduce(0) { $0 + Int($1) }))
            try kb.write(Backlight.effectBase + Backlight.mode * 32, effect)
            if !wasOn {
                try kb.write(Backlight.stateAddr, [1, 0x54])
            }
        }
    }
}

// MARK: - MacBook built-in keyboard backlight

@objc private protocol KeyboardBrightnessClient {
    func copyKeyboardBacklightIDs() -> NSArray?
    func isKeyboardBuiltIn(_ keyboardID: UInt64) -> Bool
    func brightness(forKeyboard keyboardID: UInt64) -> Float
    func isBacklightDimmed(onKeyboard keyboardID: UInt64) -> Bool
    func isBacklightSuppressed(onKeyboard keyboardID: UInt64) -> Bool
    func isAutoBrightnessEnabled(forKeyboard keyboardID: UInt64) -> Bool
}

final class BuiltInBacklight {
    struct Reading {
        var brightness: Float   // the slider value, 0-1 (set by you, or by auto-brightness)
        var idleDimmed: Bool    // turned off after a few seconds without input; not a brightness choice
        var autoBrightness: Bool
    }

    private let object: NSObject
    private let keyboardID: UInt64
    private var client: KeyboardBrightnessClient { unsafeBitCast(object, to: KeyboardBrightnessClient.self) }

    /// nil when this Mac has no built-in backlit keyboard or CoreBrightness has changed shape.
    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let object = cls.init()
        let selectors = ["copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:",
                         "isBacklightDimmedOnKeyboard:", "isBacklightSuppressedOnKeyboard:", "isAutoBrightnessEnabledForKeyboard:"]
        guard selectors.allSatisfy({ object.responds(to: NSSelectorFromString($0)) }) else { return nil }
        let client = unsafeBitCast(object, to: KeyboardBrightnessClient.self)
        guard let ids = client.copyKeyboardBacklightIDs() as? [NSNumber],
              let id = ids.map(\.uint64Value).first(where: { client.isKeyboardBuiltIn($0) }) else { return nil }
        self.object = object
        self.keyboardID = id
    }

    func read() -> Reading {
        let c = client
        let dimmed = c.isBacklightDimmed(onKeyboard: keyboardID)
        return Reading(brightness: c.brightness(forKeyboard: keyboardID), idleDimmed: dimmed,
                       autoBrightness: c.isAutoBrightnessEnabled(forKeyboard: keyboardID))
    }

    /// Maps the 0-1 slider onto off + Lofree levels 0-4 (five equal bands). Sticks with `current` until the
    /// value is clearly past that band's edge, so auto-brightness jitter at a boundary doesn't cause flapping.
    static func level(for brightness: Float, current: Level?) -> Level {
        guard brightness > 0.001 else { return .off }
        let x = Double(brightness) * 5
        if case .brightness(let c)? = current, x > Double(c) - 0.15, x < Double(c + 1) + 0.15 { return .brightness(c) }
        return .brightness(min(Level.range.upperBound, Int(x)))
    }
}

func lidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    return registryProperty(root, "AppleClamshellState") as? Bool ?? false
}

// MARK: - Schedule

struct Schedule: Decodable {
    struct Entry: Decodable {
        let time: String
        let level: Level
    }
    let entries: [Entry]

    enum CodingKeys: String, CodingKey { case entries = "schedule" }

    static var path: URL {
        if let p = ProcessInfo.processInfo.environment["LOFREE_LIGHT_CONFIG"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lofree-light/schedule.json")
    }

    static func load() throws -> Schedule {
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw LofreeError("cannot read schedule at \(path.path)") }
        let s = try JSONDecoder().decode(Schedule.self, from: data)
        guard !s.entries.isEmpty else { throw LofreeError("schedule in \(path.path) is empty") }
        for e in s.entries { _ = try hourMinute(e.time) }
        return s
    }

    static func hourMinute(_ t: String) throws -> (Int, Int) {
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            throw LofreeError("bad time \"\(t)\" (use HH:MM, 24-hour)")
        }
        return (parts[0], parts[1])
    }

    /// The schedule entry in effect at `now`, and the moment it started (today or yesterday).
    func current(at now: Date = Date()) -> (entry: Entry, since: Date) {
        let cal = Calendar.current
        var best: (Entry, Date)?
        for dayOffset in [-1, 0] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            for e in entries {
                let (h, m) = try! Schedule.hourMinute(e.time)
                guard let d = cal.date(bySettingHour: h, minute: m, second: 0, of: day), d <= now else { continue }
                if best == nil || d > best!.1 { best = (e, d) }
            }
        }
        return best!
    }
}

// MARK: - Deciding what the Lofree should show

struct Target: Equatable {
    var level: Level
    var key: String     // a new key means "apply now"; an unchanged key leaves manual Fn-key changes alone
    var reason: String
}

final class Controller {
    let builtIn = BuiltInBacklight()
    private var followed: Level?
    private var schedule: Schedule?
    private(set) var scheduleError: String?

    /// What the Lofree should show right now, or nil to leave it as it is.
    func target() -> Target? {
        if !lidClosed(), let builtIn {
            let r = builtIn.read()
            // Idle dimming switches the built-in light off a few seconds after the last input of any kind.
            // Mirroring that would blink the Lofree off at every pause, so hold the last level instead.
            if r.idleDimmed {
                guard let followed else { return nil }
                return Target(level: followed, key: "builtin:\(followed)", reason: "holding (MacBook backlight idle-dimmed)")
            }
            let level = BuiltInBacklight.level(for: r.brightness, current: followed)
            followed = level
            return Target(level: level, key: "builtin:\(level)",
                          reason: String(format: "following MacBook backlight %.0f%%%@", r.brightness * 100, r.autoBrightness ? " (auto)" : ""))
        }
        followed = nil
        do {
            schedule = try Schedule.load()
            scheduleError = nil
        } catch {
            scheduleError = "\(error)" // keep using the last schedule that loaded
        }
        guard let schedule else { return nil }
        let (entry, since) = schedule.current()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return Target(level: entry.level, key: "schedule:\(f.string(from: since)):\(entry.level)",
                      reason: "\(lidClosed() ? "lid closed" : "no built-in backlight"), schedule \(entry.time)")
    }
}

// MARK: - Daemon

func log(_ msg: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    print("\(f.string(from: Date())) \(msg)")
    fflush(stdout)
}

func runDaemon() -> Never {
    let controller = Controller()
    log("started (\(controller.builtIn == nil ? "no built-in keyboard backlight found, schedule only" : "following MacBook backlight when the lid is open"))")
    var appliedKey: String?, appliedLevel: Level?
    var pending: Target?, pendingTicks = 0
    var connected = false
    var lastProblem: String?

    while true {
        autoreleasepool {
            var problem: String?
            defer {
                if let problem, problem != lastProblem { log(problem) }
                lastProblem = problem
            }

            let nowConnected = Keyboard.isConnected
            if nowConnected != connected {
                log(nowConnected ? "Lofree connected" : "Lofree disconnected")
                connected = nowConnected
                appliedKey = nil      // re-apply after a re-plug; the keyboard may have been changed elsewhere
                appliedLevel = nil
            }
            let target = controller.target()
            problem = controller.scheduleError

            guard connected, let target, target.key != appliedKey else { pending = nil; return }
            // Apply only once the target has held for two consecutive checks, so a slider drag is one write.
            if target == pending { pendingTicks += 1 } else { pending = target; pendingTicks = 1 }
            guard pendingTicks >= 2 else { return }

            do {
                guard let kb = try Keyboard.open() else { return }
                try Backlight(kb: kb).apply(target.level, previous: appliedLevel)
                appliedKey = target.key
                appliedLevel = target.level
                pending = nil
                log("level \(target.level): \(target.reason)")
            } catch {
                problem = "\(error)"
            }
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

// MARK: - CLI

let usage = """
usage: lofree-light run               follow the MacBook backlight / schedule (what launchd runs)
       lofree-light status            show what `run` would set the Lofree to right now
       lofree-light set <off|0-4>     set the Lofree backlight once
schedule (used when the lid is closed): \(Schedule.path.path)
"""

func run(_ args: [String]) throws -> Int32 {
    switch args.first {
    case "run":
        runDaemon()
    case "status":
        let c = Controller()
        print("lid:      \(lidClosed() ? "closed" : "open")")
        if let b = c.builtIn {
            let r = b.read()
            print(String(format: "MacBook:  backlight %.0f%%%@%@", r.brightness * 100,
                         r.autoBrightness ? ", auto-brightness on" : "", r.idleDimmed ? ", idle-dimmed right now" : ""))
        } else {
            print("MacBook:  no built-in keyboard backlight found")
        }
        print("Lofree:   \(Keyboard.isConnected ? "connected over USB" : "not connected over USB")")
        if let t = c.target() {
            print("target:   level \(t.level) (\(t.reason))")
        } else {
            print("target:   no change (MacBook backlight is idle-dimmed; type something and re-run)")
        }
        if let e = c.scheduleError { print("schedule: \(e)") }
    case "set":
        guard args.count == 2 else { print(usage); return 2 }
        let level = try Level(parsing: args[1])
        guard let kb = try Keyboard.open() else { throw LofreeError("no Lofree keyboard connected over USB") }
        try Backlight(kb: kb).apply(level)
        print("sent: \(level)")
    default:
        print(usage)
        return args.first == "-h" || args.first == "--help" ? 0 : 2
    }
    return 0
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("lofree-light: \(error)\n".utf8))
    exit(1)
}
