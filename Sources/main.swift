// lofree-light: switch a Lofree keyboard's backlight on and off with the MacBook's built-in keyboard backlight
// (lid open) or a time-of-day schedule (lid closed). Brightness and effect are left to the keyboard's Fn keys.
//
// Protocol (reverse-engineered from Lofree's own web configurator, https://www.lofree.tech/keyboard/):
//   - The keyboard has a vendor HID collection (usage page 0xFF02) that takes 16-byte output reports with report ID 8:
//       [cmd, 0, addrHi, addrLo, len|0x80, data0..data9, checksum]
//       checksum = (0x55 - (sum(bytes 0..14) & 0xFF) - 8) & 0xFF
//   - cmd 7 writes the keyboard's settings memory (Lofree's configurator calls it WriteFlashData):
//       0x2130 current light mode  [mode, 0x55-mode]
//       0x2132 light on/off        [state, 0x55-state]     <- the only field this tool writes
//       0x2134 idle-off timer      [10 s units, 0x55-value]
//       0x2160 + mode*32           [colorIndex, speed, brightness(0-4), 0x55-sum]
//
// Flash wear: every write goes to the keyboard's settings flash, and the chip's endurance isn't published. So
// the tool writes only when it wants the light switched, and stops at a daily limit.
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

/// The tool only switches the Lofree's backlight on or off. Brightness and effect are whatever was last chosen
/// with the keyboard's Fn keys; the keyboard keeps them while the light is off.
enum Light: String, CustomStringConvertible, Codable {
    case on, off

    init(parsing s: String) throws {
        guard let light = Light(rawValue: s.lowercased()) else { throw LofreeError("expected on or off, got \"\(s)\"") }
        self = light
    }

    // Schedules from earlier versions used brightness levels 0-4; read any of them as on.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self), (0...4).contains(n) { self = .on } else { try self.init(parsing: c.decode(String.self)) }
    }

    var description: String { rawValue }
}

struct Backlight {
    static let stateAddr = 0x2132

    let kb: Keyboard

    /// Whether switching to `light` takes a write: not when `record` says it's already that way, unless `force`.
    static func needsWrite(_ light: Light, record: WriteRecord, force: Bool = false) -> Bool {
        force || record.written != light
    }

    /// Switches the light (one write), counting it in `record`.
    func apply(_ light: Light, record: inout WriteRecord, force: Bool = false) throws {
        guard Backlight.needsWrite(light, record: record, force: force) else { return }
        try kb.write(Backlight.stateAddr, light == .on ? [1, 0x54] : [0, 0x55])
        record.countWrite()
        record.written = light
    }
}

// MARK: - Write record

/// What lofree-light has written to the keyboard, shared by `run` and `set`. The keyboard can't be read back over
/// this transport, so this record is what lets `run` skip writes that wouldn't change anything and stay under a
/// daily limit. Changes made with the keyboard's Fn keys don't show up in it.
struct WriteRecord: Codable {
    var written: Light?     // what `run` or `set` last wrote; nil = unknown
    var applied: Light?     // what `run` last applied
    var day = ""            // the local date that `today` counts writes for
    var today = 0
    var total = 0
    var since = ""          // the date counting started

    static let dailyLimit = 10

    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/lofree-light/writes.json")
    }

    static func load() -> WriteRecord {
        guard let data = try? Data(contentsOf: path),
              let record = try? JSONDecoder().decode(WriteRecord.self, from: data) else {
            return WriteRecord(since: dayString(Date()))
        }
        return record
    }

    func save() throws {
        try FileManager.default.createDirectory(at: WriteRecord.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: WriteRecord.path, options: .atomic)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func writesToday(_ now: Date = Date()) -> Int { day == WriteRecord.dayString(now) ? today : 0 }

    mutating func countWrite(_ now: Date = Date()) {
        let d = WriteRecord.dayString(now)
        if day != d { day = d; today = 0 }
        today += 1
        total += 1
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

    /// On while the built-in backlight is on (slider above 0). Coming back on from off takes more than 2%, so
    /// auto-brightness hovering just above zero doesn't switch the Lofree back and forth.
    static func light(for brightness: Float, current: Light?) -> Light {
        if brightness <= 0.001 || (current == .off && brightness < 0.02) { return .off }
        return .on
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
        let level: Light
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

struct Target {
    var light: Light
    var reason: String
}

final class Controller {
    let builtIn = BuiltInBacklight()
    private var followed: Light?
    private var schedule: Schedule?
    private(set) var scheduleError: String?

    /// What the Lofree should show right now, or nil to leave it as it is.
    func target() -> Target? {
        if !lidClosed(), let builtIn {
            let r = builtIn.read()
            // Idle dimming switches the built-in light off a few seconds after the last input of any kind.
            // Mirroring that would blink the Lofree off at every pause, so hold the last state instead.
            if r.idleDimmed {
                guard let followed else { return nil }
                return Target(light: followed, reason: "holding (MacBook backlight idle-dimmed)")
            }
            let light = BuiltInBacklight.light(for: r.brightness, current: followed)
            followed = light
            return Target(light: light,
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
        let entry = schedule.current().entry
        return Target(light: entry.level, reason: "\(lidClosed() ? "lid closed" : "no built-in backlight"), schedule \(entry.time)")
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

/// A change is applied only after it has held for this many one-second checks, so dragging the slider through
/// zero, or auto-brightness briefly dipping to off, costs no writes.
let settleChecks = 10

func runDaemon() -> Never {
    let controller = Controller()
    var record = WriteRecord.load()
    log("started (\(controller.builtIn == nil ? "no built-in keyboard backlight found, schedule only" : "following MacBook backlight when the lid is open")); "
        + "\(record.writesToday()) of \(WriteRecord.dailyLimit) writes used today")
    var pending: Light?, pendingTicks = 0
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
            }
            let target = controller.target()
            problem = controller.scheduleError

            // Write only when the wanted state differs from the last one applied. Restarts, replugs, and switching
            // between the MacBook and the schedule cost nothing when they agree, and Fn-key changes stay until then.
            guard connected, let target, target.light != record.applied else { pending = nil; return }
            if target.light == pending { pendingTicks += 1 } else { pending = target.light; pendingTicks = 1 }
            guard pendingTicks >= settleChecks else { return }

            record = WriteRecord.load() // pick up writes made by `set`
            let needed = Backlight.needsWrite(target.light, record: record)
            if needed, record.writesToday() >= WriteRecord.dailyLimit {
                problem = "daily limit of \(WriteRecord.dailyLimit) writes reached; holding until tomorrow instead of switching the light \(target.light)"
                return
            }
            do {
                if needed {
                    guard let kb = try Keyboard.open() else { return }
                    try Backlight(kb: kb).apply(target.light, record: &record)
                }
                record.applied = target.light
                log("light \(target.light): \(target.reason) "
                    + (needed ? "(1 write, \(record.writesToday()) today)" : "(already \(target.light), no write)"))
            } catch {
                problem = "\(error)"
            }
            pending = nil // after a failure, wait another settle period before retrying
            do { try record.save() } catch { problem = "cannot save \(WriteRecord.path.path) (\(error.localizedDescription))" }
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

// MARK: - CLI

let usage = """
usage: lofree-light run               follow the MacBook backlight / schedule (what launchd runs)
       lofree-light status            show what `run` wants the Lofree's light to be right now
       lofree-light set <on|off>      switch the Lofree's light once
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
        let record = WriteRecord.load()
        if let t = c.target() {
            let state = t.light == record.applied ? "already applied"
                : Backlight.needsWrite(t.light, record: record) ? "1 write to apply" : "already \(t.light), no write needed"
            print("target:   \(t.light) (\(t.reason)), \(state)")
        } else if c.scheduleError != nil {
            print("target:   none (the schedule didn't load)")
        } else {
            print("target:   no change (MacBook backlight is idle-dimmed; type something and re-run)")
        }
        if let e = c.scheduleError { print("schedule: \(e)") }
        print("writes:   \(record.writesToday()) today (limit \(WriteRecord.dailyLimit)), \(record.total) since \(record.since)")
    case "set":
        guard args.count == 2 else { print(usage); return 2 }
        let light = try Light(parsing: args[1])
        guard let kb = try Keyboard.open() else { throw LofreeError("no Lofree keyboard connected over USB") }
        var record = WriteRecord.load()
        // Not held to the daily limit, and doesn't trust the record: you may be correcting an Fn-key change.
        defer { try? record.save() }
        try Backlight(kb: kb).apply(light, record: &record, force: true)
        print("sent: \(light) (1 write, \(record.writesToday()) today)")
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
