// Monitor input switcher over DDC/CI (VCP 0x60 "Input Source") for Apple Silicon Macs.
// Uses the private IOAVService I2C API (same approach as MonitorControl / m1ddc).
//
// Build:  ./build.sh   (CLI binary + MonitorInput.app)
//   monitor-input list | get | set <input> | <input>   CLI
//   monitor-input tray                                 menu bar agent with global hotkeys
//   MonitorInput.app                                   same as 'tray'

import AppKit
import Carbon.HIToolbox
import IOKit
import ServiceManagement

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
// Same address with bit 7 set: the DCP firmware then talks to the monitor behind the built-in DP -> HDMI converter
// of the M1 Mac mini (and similar ports). With 0x37 the converter itself answers with null messages and drops
// writes. Found in BetterDisplay, which picks 0x37 / 0xB7 per display.
let ddcChipBehindConverter: UInt32 = 0xB7
let ddcHost: UInt32 = 0x51      // host "sub-address"
let vcpInput: UInt8 = 0x60

// All DDC traffic from the tray (hotkeys, picker) goes through one queue so commands never interleave on the bus.
let ddcQueue = DispatchQueue(label: "monitor-input.ddc", qos: .userInitiated)

final class Display {
    let index: Int
    let name: String     // e.g. "PG32UQ"
    let vendor: String   // EDID manufacturer id, e.g. "AUS"
    let service: IOAVService
    // Settled by the first successful read (see read(vcp:)); writes use it, so read before writing.
    private(set) var chip = ddcChip

    init(index: Int, name: String, vendor: String, service: IOAVService) {
        self.index = index
        self.name = name
        self.vendor = vendor
        self.service = service
    }

    func write(vcp: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        for _ in 0..<3 {
            // The first write after idle is sometimes dropped, so send it twice (as MonitorControl does).
            var ok = false
            for _ in 0..<2 {
                usleep(10_000)
                if IOAVServiceWriteI2C(service, chip, ddcHost, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
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
            guard IOAVServiceWriteI2C(service, chip, ddcHost, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)   // MCCS: host must wait >= 40 ms before reading the reply
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(service, chip, ddcHost, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // A null message (6E 80 BE) from a converter that answers for itself: try the other chip address.
            if reply[1] == 0x80 {
                chip = chip == ddcChip ? ddcChipBehindConverter : ddcChip
                continue
            }
            // reply: 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { usleep(50_000); continue }
            return UInt16(reply[8]) << 8 | UInt16(reply[9])
        }
        return nil
    }

    // MCCS capabilities string, read in chunks of up to 32 bytes with the F3 request (~1.5 s on the PG32UQ).
    func capabilities() -> String? {
        var caps: [UInt8] = []
        while caps.count < 4096 {
            guard let chunk = capabilitiesChunk(offset: caps.count) else { return nil }
            if chunk.isEmpty { break }
            caps += chunk
        }
        return caps.isEmpty ? nil : String(decoding: caps.filter { $0 != 0 }, as: UTF8.self)
    }

    private func capabilitiesChunk(offset: Int) -> [UInt8]? {
        var request: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF), 0]
        request[4] = request[0..<4].reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        for _ in 0..<5 {
            usleep(10_000)
            guard IOAVServiceWriteI2C(service, chip, ddcHost, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 38)
            guard IOAVServiceReadI2C(service, chip, ddcHost, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // reply: 6E <0x80 | len> E3 <offH> <offL> <data...> <chk>; len counts E3, the offset and the data
            let len = Int(reply[1] & 0x7F)
            guard reply[2] == 0xE3, (3...35).contains(len),
                  reply[0..<(2 + len)].reduce(UInt8(0x50), { $0 ^ $1 }) == reply[2 + len],
                  Int(reply[3]) << 8 | Int(reply[4]) == offset else { usleep(50_000); continue }
            return Array(reply[5..<(2 + len)])
        }
        return nil
    }

    func getInput() -> Int? { read(vcp: vcpInput).map { Int($0 & 0xFF) } }
    func setInput(_ value: Int) -> Bool { write(vcp: vcpInput, value: UInt16(value)) }
}

// Parsed capabilities, e.g. "(prot(monitor)...model(PG32UQ)...vcp(... 60(11 12 0F) ...))".
struct MonitorInfo {
    var model: String?
    var inputs: [Int] = []

    init(capabilities caps: String?) {
        guard let caps = caps else { return }
        model = firstGroup(caps, #"model\(([^)]*)\)"#)
        if let list = firstGroup(caps, #"\b60\(([0-9A-Fa-f ]*)\)"#) {
            inputs = list.split(separator: " ").compactMap { Int($0, radix: 16) }
        }
    }

    private func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
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

// selector: "auto" (first ASUS display answering DDC, else first answering, else first ASUS / first display:
// some links accept writes but never answer reads), index, or name substring.
func selectDisplay(_ selector: String) -> Display? {
    let displays = allDisplays()
    let sel = selector.trimmingCharacters(in: .whitespaces)
    if let idx = Int(sel) { return displays.first { $0.index == idx } }
    if sel.lowercased() != "auto" {
        return displays.first { $0.name.localizedCaseInsensitiveContains(sel) || $0.vendor.localizedCaseInsensitiveContains(sel) }
    }
    if displays.count <= 1 { return displays.first }
    let isAsus: (Display) -> Bool = { $0.vendor.uppercased() == "AUS" }
    let candidates = displays.filter(isAsus) + displays.filter { !isAsus($0) }
    return candidates.first { $0.getInput() != nil } ?? candidates.first
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

// Human-readable name for the picker.
func inputLabel(_ v: Int) -> String {
    switch v {
    case 0x03: return "DVI"
    case 0x0F: return "DisplayPort"
    case 0x10: return "DisplayPort 2"
    case 0x11: return "HDMI 1"
    case 0x12: return "HDMI 2"
    case 0x13: return "USB-C"
    case 0x14: return "USB-C 2"
    case 0x53: return "HDMI 3"
    case 0x54: return "HDMI 4"
    default: return String(format: "Input 0x%02X", v)
    }
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
    // Always read first: it also settles the chip address the write has to use.
    let current = display.getInput()
    var target = targets[0]
    if targets.count > 1, let cur = current, let pos = targets.firstIndex(of: cur) {
        target = targets[(pos + 1) % targets.count]
    }
    guard display.setInput(target) else { throw MonitorError("DDC write failed") }
    return "Display \(display.index) (\(display.vendor) \(display.name)) -> \(inputName(target))"
}

// MARK: - Launch at login (only from the .app bundle)

let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")

func loginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

func setLoginItem(_ on: Bool) throws {
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    if on && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
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
    ddcQueue.async {
        do { print(try switchInput(spec, selector: selector)) }
        catch { fputs("Error: \(error)\n", stderr); DispatchQueue.main.async { NSSound.beep() } }
    }
}

// Turns the display(s) off right away (the Mac keeps running), like the display sleep timer would.
func sleepDisplays() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["displaysleepnow"]
    do { try p.run() } catch { NSSound.beep(); fputs("pmset: \(error)\n", stderr) }
}

// Horizontal arrow from x1 to x2 with a filled triangular head at x2 (y grows down: drawn in flipped images).
func drawArrow(from x1: CGFloat, to x2: CGFloat, y: CGFloat, head: CGFloat, width: CGFloat) {
    let dir: CGFloat = x2 > x1 ? 1 : -1
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: x1, y: y))
    shaft.line(to: NSPoint(x: x2 - dir * head * 0.6, y: y))
    shaft.lineWidth = width
    shaft.stroke()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: x2, y: y))
    tip.line(to: NSPoint(x: x2 - dir * head, y: y - head * 0.75))
    tip.line(to: NSPoint(x: x2 - dir * head, y: y + head * 0.75))
    tip.close()
    tip.fill()
}

// Menu bar icon: outlined monitor with the two "switch" arrows of the app icon. A template image,
// so macOS tints it for light / dark menu bars.
func makeStatusIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
        NSColor.black.set()
        let body = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1, width: 17.5, height: 11.5), xRadius: 2.2, yRadius: 2.2)
        body.lineWidth = 1.5
        body.stroke()
        NSBezierPath(rect: NSRect(x: 9, y: 13, width: 2, height: 1.75)).fill()
        NSBezierPath(roundedRect: NSRect(x: 5.5, y: 14.5, width: 9, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
        drawArrow(from: 5, to: 15, y: 4.6, head: 2.4, width: 1.4)
        drawArrow(from: 15, to: 5, y: 8.9, head: 2.4, width: 1.4)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Monitor input"
    return image
}

// Popover under the menu bar icon: monitor name, its current input and one button per supported input.
final class InputPicker: NSObject, NSPopoverDelegate {
    static let fallbackInputs = [0x0F, 0x11, 0x12]

    let popover = NSPopover()
    let stack = NSStackView()
    let titleLabel = NSTextField(labelWithString: "")
    let getSelector: () -> String
    // Capabilities take ~1.5 s to read, so they are fetched once (warmup) and cached per monitor.
    // Touched only on ddcQueue.
    var cachedKey: String?
    var cachedInfo: MonitorInfo?
    // Main thread only.
    var last: Snapshot?
    var closedAt = Date.distantPast

    struct Snapshot {
        var name = ""
        var current: Int?
        var inputs: [Int] = []
        var error: String?
    }

    init(getSelector: @escaping () -> String) {
        self.getSelector = getSelector
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    // Reads the monitor name and supported inputs in the background right after startup.
    func warmup() {
        let selector = getSelector()
        ddcQueue.async {
            let snap = self.read(selector)
            DispatchQueue.main.async { if self.last == nil { self.last = snap } }
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        // A click on the icon closes the transient popover on mouse down; don't reopen it on that same click.
        if popover.isShown || Date().timeIntervalSince(closedAt) < 0.3 { popover.performClose(nil); return }

        // Show cached buttons immediately, then refresh the current input (~100 ms over DDC).
        render(last ?? Snapshot(name: "Reading monitor…"), placeholder: last == nil)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()

        let selector = getSelector()
        ddcQueue.async {
            let snap = self.read(selector)
            DispatchQueue.main.async {
                self.last = snap
                if self.popover.isShown { self.render(snap) }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) { closedAt = Date() }

    private func read(_ selector: String) -> Snapshot {
        guard let display = selectDisplay(selector) else { return Snapshot(error: "No DDC/CI display found") }
        let key = "\(display.vendor) \(display.name) \(display.index)"
        var snap = Snapshot(current: display.getInput())
        if cachedKey != key || cachedInfo == nil {
            cachedInfo = MonitorInfo(capabilities: display.capabilities())
            cachedKey = key
        }
        snap.name = cachedInfo?.model ?? (display.name.isEmpty ? "Display \(display.index)" : display.name)
        snap.inputs = cachedInfo?.inputs ?? []
        return snap
    }

    private func render(_ snap: Snapshot, placeholder: Bool = false) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(titleLabel)
        if let error = snap.error {
            titleLabel.stringValue = error
        } else if placeholder {
            titleLabel.stringValue = snap.name
        } else {
            titleLabel.stringValue = "\(snap.name)  –  " + (snap.current.map(inputLabel) ?? "input unknown")
            for value in Set(snap.inputs.isEmpty ? Self.fallbackInputs : snap.inputs).sorted() {
                let active = value == snap.current
                let button = NSButton(title: (active ? "●  " : "") + inputLabel(value), target: self, action: #selector(choose(_:)))
                button.tag = value
                button.controlSize = .large
                if active { button.font = .boldSystemFont(ofSize: NSFont.systemFontSize(for: .large)) }
                button.widthAnchor.constraint(equalToConstant: 220).isActive = true
                stack.addArrangedSubview(button)
            }
        }
        // Not DDC: works even when the monitor does not answer.
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(separator)
        let sleep = NSButton(title: "Sleep display", target: self, action: #selector(sleepClicked))
        sleep.controlSize = .large
        sleep.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(sleep)
        stack.layoutSubtreeIfNeeded()
        popover.contentSize = stack.fittingSize
    }

    @objc private func sleepClicked() {
        popover.performClose(nil)
        sleepDisplays()
    }

    @objc private func choose(_ sender: NSButton) {
        let target = sender.tag
        stack.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = false }
        titleLabel.stringValue = "Switching to \(inputLabel(target))…"
        let selector = getSelector()
        ddcQueue.async {
            var failure: String?
            do { try switchInput(String(target), selector: selector) } catch { failure = "\(error)" }
            DispatchQueue.main.async {
                if let failure = failure {
                    self.render(Snapshot(error: failure))
                } else {
                    self.last?.current = target
                    self.popover.performClose(nil)   // the picture usually leaves this Mac anyway
                }
            }
        }
    }
}

final class TrayApp: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    lazy var picker = InputPicker(getSelector: { State.selector })

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = makeStatusIcon()
            button.toolTip = "Monitor input"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        picker.warmup()
    }

    // Left click: input picker. Right click / ctrl+click: menu.
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            picker.toggle(relativeTo: sender)
        }
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

        menu.removeAllItems()
        let open = NSMenuItem(title: "Choose input…", action: #selector(openPicker), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let sleep = NSMenuItem(title: "Sleep display", action: #selector(sleepDisplaysClicked), keyEquivalent: "")
        sleep.target = self
        menu.addItem(sleep)
        menu.addItem(.separator())

        var errors: [String] = []
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.lowercased() == "monitor" { State.selector = val; continue }

            guard let hk = parseHotkey(key) else { errors.append("Bad hotkey: \(key)"); continue }
            let id = EventHotKeyID(signature: OSType(0x4D_49_4E_50), id: UInt32(State.actions.count))   // 'MINP'
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(hk.key, hk.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref = ref {
                State.refs.append(ref)
            } else {
                errors.append("\(key) is already taken by another app")
            }
            State.actions.append(val)

            let item = NSMenuItem(title: "\(val)    \(key)", action: #selector(menuSwitch(_:)), keyEquivalent: "")
            item.representedObject = val
            item.target = self
            menu.addItem(item)
        }

        if !errors.isEmpty {
            menu.addItem(.separator())
            for error in errors {
                fputs("\(error)\n", stderr)
                menu.addItem(withTitle: "⚠︎ \(error)", action: nil, keyEquivalent: "").isEnabled = false
            }
        }

        menu.addItem(.separator())
        if isAppBundle {
            let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
            login.target = self
            login.state = loginItemEnabled() ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(withTitle: "Edit hotkeys…", action: #selector(editConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload hotkeys", action: #selector(loadConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func sleepDisplaysClicked() { sleepDisplays() }

    @objc func openPicker() {
        if let button = statusItem.button { picker.toggle(relativeTo: button) }
    }

    @objc func menuSwitch(_ sender: NSMenuItem) {
        if let spec = sender.representedObject as? String { runAction(spec) }
    }

    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        do { try setLoginItem(!loginItemEnabled()) } catch { NSSound.beep(); fputs("Login item: \(error)\n", stderr) }
        sender.state = loginItemEnabled() ? .on : .off
    }

    @objc func editConfig() {
        // .conf has no default app; -t opens it in the default text editor.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", configURL.path]
        try? p.run()
    }
}

// MARK: - CLI

func usage() {
    print("""
    monitor-input - switch monitor input source via DDC/CI (VCP 0x60), Apple Silicon

      monitor-input list                 show external displays, current and supported inputs
      monitor-input get                  print current input
      monitor-input set <input>          switch input
      monitor-input <input>              same as set
      monitor-input set dp,hdmi1         toggle/cycle between inputs
      monitor-input tray                 menu bar agent with hotkeys (~/.config/monitor-input.conf)
      monitor-input login-item on|off    launch MonitorInput.app at login (run from inside the .app)

      -m, --monitor <sel>   auto (default) | index from 'list' | name substring (e.g. PG32UQ)

      inputs: dp, dp2, hdmi1, hdmi2, hdmi3, hdmi4, usbc, usbc2, dvi, or a raw value (17, 0x11)
    """)
}

func runTray() -> Never {
    let app = NSApplication.shared
    let delegate = TrayApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon
    app.run()
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }   // Finder's process serial number
var selector = "auto"
if let i = args.firstIndex(where: { $0 == "-m" || $0 == "--monitor" }), i + 1 < args.count {
    selector = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

do {
    switch args.first?.lowercased() {
    case nil where isAppBundle:
        runTray()
    case nil, "-h", "--help":
        usage()
    case "list":
        let displays = allDisplays()
        if displays.isEmpty { print("No external displays found") }
        for d in displays {
            print("[\(d.index)] \(d.name.isEmpty ? "(no display attributes, e.g. unused port)" : "\(d.vendor) \(d.name)")")
            let current = d.getInput()
            print("    current input: \(current.map(inputName) ?? "n/a (no DDC/CI reply)")")
            guard current != nil else { continue }
            guard let caps = d.capabilities() else { print("    capabilities: n/a (monitor did not answer)"); continue }
            let info = MonitorInfo(capabilities: caps)
            if let model = info.model { print("    model: \(model)") }
            if !info.inputs.isEmpty { print("    advertised inputs: \(info.inputs.map(inputName).joined(separator: ", "))") }
        }
    case "get":
        guard let v = selectDisplay(selector)?.getInput() else { throw MonitorError("Cannot read input source") }
        print(inputName(v))
    case "set":
        guard args.count >= 2 else { usage(); exit(2) }
        print(try switchInput(args[1], selector: selector))
    case "tray":
        runTray()
    case "login-item":
        guard isAppBundle else { throw MonitorError("login-item works only from inside MonitorInput.app") }
        switch args.dropFirst().first?.lowercased() {
        case "on": try setLoginItem(true)
        case "off": try setLoginItem(false)
        case nil, "status": break
        default: usage(); exit(2)
        }
        print("Launch at login: \(loginItemEnabled() ? "on" : "off") (\(SMAppService.mainApp.status.rawValue))")
    default:
        print(try switchInput(args[0], selector: selector))
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
