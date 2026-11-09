// lofree-light: set a Lofree keyboard's backlight brightness from a time-of-day schedule.
//
// Protocol (reverse-engineered from Lofree's own web configurator, https://www.lofree.tech/keyboard/):
//   - Vendor HID collection, usage page 0xFF02 / usage 2, report ID 8, 16-byte in/out reports.
//   - Request:  [cmd, 0, addrHi, addrLo, len|0x80, data0..data9, checksum]
//     checksum = (0x55 - (sum(bytes 0..14) & 0xFF) - 8) & 0xFF
//   - The device echoes [cmd, status, addrHi, addrLo, len|0x80, data...] on input report 8.
//   - cmd 8 reads and cmd 7 writes the keyboard's settings memory:
//       0x2130 current light mode  [mode, 0x55-mode]
//       0x2132 light on/off        [state, 0x55-state]
//       0x2160 + mode*32           [colorIndex, speed, brightness(0-4), 0x55-sum]

import Foundation
import IOKit.hid

// MARK: - HID transport

struct LofreeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class Keyboard {
    static let reportID: UInt8 = 8
    static let lofreeVendorIDs: Set<Int> = [0x3554, 0x388D]

    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var lastReport: [UInt8]?

    /// Finds the keyboard's vendor-config interface. Returns nil when no Lofree keyboard is attached.
    static func open() throws -> Keyboard? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kIOHIDDeviceUsagePageKey: 0xFF02, kIOHIDDeviceUsageKey: 2] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard let set = IOHIDManagerCopyDevices(manager) as NSSet?,
              let devices = set.allObjects as? [IOHIDDevice] else { return nil }

        let match = devices.first { dev in
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? ""
            let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            return product.localizedCaseInsensitiveContains("lofree") || lofreeVendorIDs.contains(vid)
        }
        guard let device = match else { return nil }

        // kIOHIDOptionsTypeNone = shared access; never seize the interface, it also carries keystrokes.
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            throw LofreeError(String(format: "could not open keyboard HID interface (IOReturn 0x%08x)%@", rc,
                                     rc == kIOReturnNotPermitted ? " — grant Input Monitoring permission" : ""))
        }
        return Keyboard(device)
    }

    private init(_ device: IOHIDDevice) {
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { ctx, _, _, _, reportID, report, length in
            guard let ctx, reportID == UInt32(Keyboard.reportID) else { return }
            let kb = Unmanaged<Keyboard>.fromOpaque(ctx).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.count == 17, bytes[0] == Keyboard.reportID { bytes.removeFirst() } // strip report ID
            kb.lastReport = bytes
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deallocate()
    }

    private static func checksum(_ p: [UInt8]) -> UInt8 {
        let sum = p[0..<15].reduce(0) { $0 + Int($1) } & 0xFF
        return UInt8(truncatingIfNeeded: 0x55 - sum - 8)
    }

    /// Sends one 16-byte command and waits for the device's echo.
    private func transfer(_ cmd: UInt8, addr: Int, data: [UInt8] = [], length: Int? = nil) throws -> [UInt8] {
        precondition(data.count <= 10)
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = cmd
        p[2] = UInt8((addr >> 8) & 0xFF)
        p[3] = UInt8(addr & 0xFF)
        p[4] = UInt8((length ?? data.count) | 0x80)
        for (i, b) in data.enumerated() { p[5 + i] = b }
        p[15] = Keyboard.checksum(p)

        let out = [Keyboard.reportID] + p
        for _ in 0..<3 {
            lastReport = nil
            let rc = out.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Keyboard.reportID), $0.baseAddress!, $0.count)
            }
            guard rc == kIOReturnSuccess else {
                throw LofreeError(String(format: "sending to keyboard failed (IOReturn 0x%08x)", rc))
            }
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.02, true)
                if let r = lastReport, r.count >= 16, r[0] == cmd, r[2] == p[2], r[3] == p[3],
                   r[15] == Keyboard.checksum(r) {
                    return r
                }
            }
        }
        throw LofreeError("keyboard did not answer command \(cmd) @0x\(String(addr, radix: 16))")
    }

    func read(_ addr: Int, count: Int) throws -> [UInt8] {
        let r = try transfer(8, addr: addr, length: count)
        return Array(r[5..<(5 + count)])
    }

    func write(_ addr: Int, _ data: [UInt8]) throws {
        _ = try transfer(7, addr: addr, data: data)
        guard try read(addr, count: data.count) == data else {
            throw LofreeError("write to 0x\(String(addr, radix: 16)) did not stick")
        }
    }
}

// MARK: - Backlight model

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

    let kb: Keyboard

    struct Status { var mode: Int; var on: Bool; var brightness: Int; var effect: [UInt8] }

    func status() throws -> Status {
        let ms = try kb.read(Backlight.modeAddr, count: 4)  // [mode, ~mode, state, ~state]
        let mode = Int(ms[0])
        guard mode < 16 else { throw LofreeError("unexpected light mode \(mode)") }
        let effect = try kb.read(Backlight.effectBase + mode * 32, count: 4)
        return Status(mode: mode, on: ms[2] == 1, brightness: Int(effect[2]), effect: effect)
    }

    /// Applies `level`, writing only what differs. Returns a short description of what changed.
    @discardableResult
    func apply(_ level: Level) throws -> String {
        let s = try status()
        switch level {
        case .off:
            guard s.on else { return "already off" }
            try kb.write(Backlight.stateAddr, [0, 0x55])
            return "turned off"
        case .brightness(let n):
            var changes: [String] = []
            if !s.on {
                try kb.write(Backlight.stateAddr, [1, 0x54])
                changes.append("turned on")
            }
            if s.brightness != n {
                var e = Array(s.effect[0..<3])
                e[2] = UInt8(n)
                e.append(UInt8(truncatingIfNeeded: 0x55 - e.reduce(0) { $0 + Int($1) }))
                try kb.write(Backlight.effectBase + s.mode * 32, e)
                changes.append("brightness \(s.brightness) -> \(n)")
            }
            return changes.isEmpty ? "already at \(n)" : changes.joined(separator: ", ")
        }
    }
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

// Remembers which schedule slot was last applied, so manual Fn-key changes are left alone until the next slot.
enum AppliedSlot {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/lofree-light/last-applied")
    }
    static func key(_ entry: Schedule.Entry, _ since: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return "\(f.string(from: since)) level=\(entry.level)"
    }
    static func read() -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ key: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (key + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - CLI

func log(_ msg: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    print("\(f.string(from: Date())) \(msg)")
}

func requireKeyboard() throws -> Backlight {
    guard let kb = try Keyboard.open() else { throw LofreeError("no Lofree keyboard found") }
    return Backlight(kb: kb)
}

let usage = """
usage: lofree-light status            show current backlight mode/state/brightness
       lofree-light set <off|0-4>     set the backlight now
       lofree-light auto [--force]    apply the schedule if a new slot has started
       lofree-light auto --dry-run    show which slot is in effect, change nothing
schedule: \(Schedule.path.path)
"""

func run(_ args: [String]) throws -> Int32 {
    switch args.first {
    case "status":
        let s = try requireKeyboard().status()
        print("light: \(s.on ? "on" : "off"), mode: \(s.mode), brightness: \(s.brightness) (range \(Level.range.lowerBound)-\(Level.range.upperBound))")
    case "set":
        guard args.count == 2 else { print(usage); return 2 }
        let level = try Level(parsing: args[1])
        print(try requireKeyboard().apply(level))
    case "auto":
        let flags = Set(args.dropFirst())
        guard flags.isSubset(of: ["--force", "--dry-run"]) else { print(usage); return 2 }
        let (entry, since) = try Schedule.load().current()
        let key = AppliedSlot.key(entry, since)
        if flags.contains("--dry-run") {
            print("in effect: \(entry.time) -> \(entry.level)  (slot \(key); last applied: \(AppliedSlot.read() ?? "never"))")
            return 0
        }
        if !flags.contains("--force"), AppliedSlot.read() == key { return 0 }
        guard let kb = try Keyboard.open() else { return 0 } // not plugged in; retry on next run
        let result = try Backlight(kb: kb).apply(entry.level)
        try AppliedSlot.write(key)
        log("slot \(entry.time) level \(entry.level): \(result)")
    default:
        print(usage)
        return args.isEmpty ? 2 : (args.first == "-h" || args.first == "--help" ? 0 : 2)
    }
    return 0
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("lofree-light: \(error)\n".utf8))
    exit(1)
}
