// Monitor input switcher over DDC/CI (VCP 0x60 "Input Source") for Apple Silicon Macs.
// Uses the private IOAVService I2C API (same approach as MonitorControl / m1ddc).
//
// Build:  ./build.sh
//   monitor-input list | get | set <input> | <input>   CLI
//   monitor-input tray                                 menu bar agent with global hotkeys

import AppKit
import Carbon.HIToolbox
import IOKit

// MARK: - DDC/CI over IOAVService

typealias IOAVService = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVService, _ chipAddress: UInt32, _ offset: UInt32,
                        _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVService, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

let ddcChip: UInt32 = 0x37      // DDC/CI 7-bit I2C address
let ddcHost: UInt32 = 0x51      // host "sub-address"
let vcpInput: UInt8 = 0x60

struct Display {
    let index: Int
    let name: String     // e.g. "PG32UQ"
    let vendor: String   // EDID manufacturer id, e.g. "AUS"
    let service: IOAVService

    func write(vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        for _ in 0..<3 {
            // The first write after idle is sometimes dropped, so send it twice (as MonitorControl does).
            var ok = false
            for _ in 0..<2 {
                usleep(10_000)
                if IOAVServiceWriteI2C(service, ddcChip, ddcHost, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
            }
            if ok { return true }
            usleep(50_000)
        }
        return false
    }

    func read(vcp: UInt8) -> UInt16? {
        var request: [UInt8] = [0x82, 0x01, vcp, 0]
        request[3] = request[0..<3].reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        for _ in 0..<5 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, ddcChip, ddcHost, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)   // MCCS: host must wait >= 40 ms before reading the reply
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(service, ddcChip, ddcHost, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // reply: 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { usleep(50_000); continue }
            return UInt16(reply[8]) << 8 | UInt16(reply[9])
        }
        return nil
    }

    func getInput() -> Int? { read(vcp: vcpInput).map { Int($0 & 0xFF) } }
    func setInput(_ value: Int) -> Bool { write(vcp: vcpInput, value: UInt16(value)) }
}

func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

// Walks the IOService plane: each external display has a framebuffer node (AppleCLCD2 /
// IOMobileFramebufferShim, carries EDID-derived attributes) followed by its DCPAVServiceProxy.
func allDisplays() -> [Display] {
    var result: [Display] = []
    var iter = io_iterator_t()
    let root = IORegistryGetRootEntry(0)   // 0 = default main port (works on macOS 11+)
    defer { IOObjectRelease(root) }
    guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iter) }

    var name = "", vendor = ""
    let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { nameBuf.deallocate() }

    while true {
        let entry = IOIteratorNext(iter)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }

        guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
        let cls = String(cString: nameBuf)

        if cls == "AppleCLCD2" || cls == "IOMobileFramebufferShim" {
            name = ""; vendor = ""
            if let attrs = registryProperty(entry, "DisplayAttributes") as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any] {
                name = product["ProductName"] as? String ?? ""
                vendor = product["ManufacturerID"] as? String ?? ""
            }
        } else if cls == "DCPAVServiceProxy" {
            guard registryProperty(entry, "Location") as? String == "External",
                  let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            result.append(Display(index: result.count, name: name, vendor: vendor, service: service))
        }
    }
    return result
}

// selector: "auto" (first ASUS display answering DDC, else first answering), index, or name substring.
func selectDisplay(_ selector: String) -> Display? {
    let displays = allDisplays()
    let sel = selector.trimmingCharacters(in: .whitespaces)
    if let idx = Int(sel) { return displays.first { $0.index == idx } }
    if sel.lowercased() != "auto" {
        return displays.first { $0.name.localizedCaseInsensitiveContains(sel) || $0.vendor.localizedCaseInsensitiveContains(sel) }
    }
    let responding = displays.filter { $0.getInput() != nil }
    return responding.first { $0.vendor.uppercased() == "AUS" } ?? responding.first
}

// MARK: - Input names

// MCCS values; ASUS DisplayWidget uses the same codes.
let inputNames: [(String, Int)] = [
    ("dvi", 0x03), ("dp", 0x0F), ("dp1", 0x0F), ("dp2", 0x10),
    ("hdmi", 0x11), ("hdmi1", 0x11), ("hdmi2", 0x12),
    ("usbc", 0x13), ("usbc1", 0x13), ("usbc2", 0x14),
    ("hdmi3", 0x53), ("hdmi4", 0x54),
]

func parseInput(_ s: String) throws -> Int {
    let s = s.trimmingCharacters(in: .whitespaces).lowercased()
    if let v = inputNames.first(where: { $0.0 == s })?.1 { return v }
    if s.hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) { return v }
    if let v = Int(s) { return v }
    throw MonitorError("Unknown input: \(s)")
}

func inputName(_ v: Int) -> String {
    let preferred = ["dvi", "dp1", "dp2", "hdmi1", "hdmi2", "usbc1", "usbc2", "hdmi3", "hdmi4"]
    let n = preferred.first { name in inputNames.contains { $0.0 == name && $0.1 == v } } ?? "?"
    return "\(n) (0x\(String(format: "%02X", v)))"
}

struct MonitorError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// "dp" -> switch to dp; "dp,hdmi1" -> cycle: go to the entry after the current one.
@discardableResult
func switchInput(_ spec: String, selector: String) throws -> String {
    guard let display = selectDisplay(selector) else { throw MonitorError("No DDC/CI display found (selector: \(selector))") }
    let targets = try spec.split(separator: ",").map { try parseInput(String($0)) }
    guard !targets.isEmpty else { throw MonitorError("Empty input list") }
    var target = targets[0]
    if targets.count > 1, let cur = display.getInput(), let pos = targets.firstIndex(of: cur) {
        target = targets[(pos + 1) % targets.count]
    }
    guard display.setInput(target) else { throw MonitorError("DDC write failed") }
    return "Display \(display.index) (\(display.vendor) \(display.name)) -> \(inputName(target))"
}

// MARK: - Menu bar agent with global hotkeys

let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/monitor-input.conf")

let defaultConfig = """
# hotkey = input   (input: dp, dp2, hdmi1, hdmi2, usbc, raw value, or a list to toggle: dp,hdmi1)
# modifiers: cmd, ctrl, opt (alt), shift
# monitor = auto | index | name substring (see: monitor-input list)
monitor = auto
ctrl+opt+1 = dp
ctrl+opt+2 = hdmi1
ctrl+opt+3 = hdmi2

"""

let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
    "space": kVK_Space, "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
]

func parseHotkey(_ s: String) -> (key: UInt32, mods: UInt32)? {
    var mods: UInt32 = 0
    var key: UInt32?
    for part in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch part {
        case "cmd", "command": mods |= UInt32(cmdKey)
        case "ctrl", "control": mods |= UInt32(controlKey)
        case "opt", "option", "alt": mods |= UInt32(optionKey)
        case "shift": mods |= UInt32(shiftKey)
        default:
            guard let code = keyCodes[part] else { return nil }
            key = UInt32(code)
        }
    }
    return key.map { ($0, mods) }
}

// Globals because the Carbon event handler is a C function pointer and cannot capture context.
enum State {
    static var actions: [String] = []
    static var refs: [EventHotKeyRef] = []
    static var selector = "auto"
}

func runAction(_ spec: String) {
    let selector = State.selector
    DispatchQueue.global(qos: .userInitiated).async {
        do { print(try switchInput(spec, selector: selector)) }
        catch { fputs("Error: \(error)\n", stderr); DispatchQueue.main.async { NSSound.beep() } }
    }
}

final class TrayApp: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Monitor input")
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let i = Int(hk.id)
            if i < State.actions.count { runAction(State.actions[i]) }
            return noErr
        }, 1, &spec, nil, nil)
        loadConfig()
    }

    @objc func loadConfig() {
        State.refs.forEach { UnregisterEventHotKey($0) }
        State.refs.removeAll()
        State.actions.removeAll()
        State.selector = "auto"

        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
        }

        let menu = NSMenu()
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.lowercased() == "monitor" { State.selector = val; continue }

            guard let hk = parseHotkey(key) else { fputs("Bad hotkey: \(key)\n", stderr); continue }
            let id = EventHotKeyID(signature: OSType(0x4D_49_4E_50), id: UInt32(State.actions.count))   // 'MINP'
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(hk.key, hk.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref = ref {
                State.refs.append(ref)
            } else {
                fputs("Hotkey \(key) is already taken\n", stderr)
            }
            State.actions.append(val)

            let item = NSMenuItem(title: "\(val)    \(key)", action: #selector(menuSwitch(_:)), keyEquivalent: "")
            item.representedObject = val
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit hotkeys…", action: #selector(editConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload hotkeys", action: #selector(loadConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func menuSwitch(_ sender: NSMenuItem) {
        if let spec = sender.representedObject as? String { runAction(spec) }
    }

    @objc func editConfig() {
        NSWorkspace.shared.open(configURL)
    }
}

// MARK: - CLI

func usage() {
    print("""
    monitor-input - switch monitor input source via DDC/CI (VCP 0x60), Apple Silicon

      monitor-input list                 show external displays and current input
      monitor-input get                  print current input
      monitor-input set <input>          switch input
      monitor-input <input>              same as set
      monitor-input set dp,hdmi1         toggle/cycle between inputs
      monitor-input tray                 menu bar agent with hotkeys (~/.config/monitor-input.conf)

      -m, --monitor <sel>   auto (default) | index from 'list' | name substring (e.g. PG32UQ)

      inputs: dp, dp2, hdmi1, hdmi2, hdmi3, hdmi4, usbc, usbc2, dvi, or a raw value (17, 0x11)
    """)
}

var args = Array(CommandLine.arguments.dropFirst())
var selector = "auto"
if let i = args.firstIndex(where: { $0 == "-m" || $0 == "--monitor" }), i + 1 < args.count {
    selector = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

do {
    switch args.first?.lowercased() {
    case nil, "-h", "--help":
        usage()
    case "list":
        let displays = allDisplays()
        if displays.isEmpty { print("No external displays found") }
        for d in displays {
            print("[\(d.index)] \(d.vendor) \(d.name)")
            print("    current input: \(d.getInput().map(inputName) ?? "n/a (no DDC/CI reply)")")
        }
    case "get":
        guard let v = selectDisplay(selector)?.getInput() else { throw MonitorError("Cannot read input source") }
        print(inputName(v))
    case "set":
        guard args.count >= 2 else { usage(); exit(2) }
        print(try switchInput(args[1], selector: selector))
    case "tray":
        let app = NSApplication.shared
        let delegate = TrayApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    default:
        print(try switchInput(args[0], selector: selector))
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
