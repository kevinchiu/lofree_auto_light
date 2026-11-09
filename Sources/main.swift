// lofree-light: set a Lofree keyboard's backlight brightness from a time-of-day schedule.
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

import Foundation
import IOKit
import IOUSBHost

struct LofreeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - USB transport

final class Keyboard {
    static let reportID: UInt8 = 8
    static let vendorUsagePage = 0xFF02
    static let lofreeVendorIDs: Set<Int> = [0x3554, 0x388D]

    private let device: IOUSBHostDevice
    private let interfaceNumber: UInt16

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

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Finds a Lofree USB device and the number of its interface that carries the vendor collection.
    private static func findService() -> (io_service_t, UInt16)? {
        var devices: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(devices) }

        while case let dev = IOIteratorNext(devices), dev != 0 {
            let name = property(dev, "USB Product Name") as? String ?? ""
            let vid = property(dev, "idVendor") as? Int ?? 0
            if name.localizedCaseInsensitiveContains("lofree") || lofreeVendorIDs.contains(vid),
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
            guard let number = property(child, "bInterfaceNumber") as? Int else { continue }
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

    // Brightness is stored per light mode, and the current mode can't be read back over this transport,
    // so the schedule pins the keyboard to one mode. These are the values this keyboard was set to
    // (mode 0, color index 0, speed 2).
    static let mode = 0, colorIndex: UInt8 = 0, speed: UInt8 = 2

    let kb: Keyboard

    func apply(_ level: Level) throws {
        switch level {
        case .off:
            try kb.write(Backlight.stateAddr, [0, 0x55])
        case .brightness(let n):
            let m = UInt8(Backlight.mode)
            var effect = [Backlight.colorIndex, Backlight.speed, UInt8(n)]
            effect.append(UInt8(truncatingIfNeeded: 0x55 - effect.reduce(0) { $0 + Int($1) }))
            try kb.write(Backlight.modeAddr, [m, 0x55 &- m])
            try kb.write(Backlight.effectBase + Backlight.mode * 32, effect)
            try kb.write(Backlight.stateAddr, [1, 0x54])
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

let usage = """
usage: lofree-light set <off|0-4>     set the backlight now
       lofree-light auto [--force]    apply the schedule if a new slot has started
       lofree-light auto --dry-run    show which slot is in effect, change nothing
schedule: \(Schedule.path.path)
"""

func run(_ args: [String]) throws -> Int32 {
    switch args.first {
    case "set":
        guard args.count == 2 else { print(usage); return 2 }
        let level = try Level(parsing: args[1])
        guard let kb = try Keyboard.open() else { throw LofreeError("no Lofree keyboard connected over USB") }
        try Backlight(kb: kb).apply(level)
        print("sent: \(level)")
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
        try Backlight(kb: kb).apply(entry.level)
        try AppliedSlot.write(key)
        log("slot \(entry.time): sent level \(entry.level)")
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
