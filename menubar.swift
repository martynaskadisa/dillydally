// DillyDally's menu-bar app. The panel has two faces: before a cast it asks
// which TV; during one it shows how the cast is doing. The TV is an extra
// display to macOS, so what it shows is chosen with Screen Mirroring in the
// menu bar, not here. The settings sit on a page behind the gear.
//
// The cast itself is in engine.swift, which reports back as events.
//
// Build: ./build.sh

import SwiftUI

func resolutionName(_ size: String) -> String {
    ["3840x2160": "4K", "1920x1080": "1080p"][size] ?? size
}

enum Setting {
    static let sound = "sound"
    static let size = "size"      // "auto" or WIDTHxHEIGHT
    static let fps = "fps"
    static let codec = "codec"    // "h264" or "hevc"
    static let buffer = "buffer"  // seconds
    static let tv = "tv"          // name of the TV cast to last

    static let defaults: [String: Any] = [
        sound: true, size: "auto", fps: 60, codec: "hevc", buffer: 2,
    ]
}

final class CastModel: ObservableObject {
    enum Phase { case idle, starting, casting }
    @Published var tvs: [TV] = []
    @Published var searching = false
    @Published var selected: String?     // ip of the TV the Cast button goes to
    @Published var phase = Phase.idle
    @Published var target: TV?
    @Published var step = ""             // what a starting cast is waiting for
    @Published var hint = ""             // something the user has to do, e.g. grant a permission
    @Published var failure = ""          // why the last cast ended, unless it was asked to
    @Published var format = ""           // e.g. "4K · 60 · HEVC"
    @Published var mbit = 0.0
    @Published var behind = 0.0          // how far behind live the TV is reading, seconds
    @Published var lag = 0.0             // how far behind real time the encoder is, seconds
    @Published var delay = 0             // the running cast's --buffer
    @Published var display: CGDirectDisplayID = 0  // the TV's display, while it is one of this Mac's screens
    @Published var movedApp: NSRunningApplication?  // the app we put on the TV's display
    @Published var moving = false
    @Published var windowChosen = false  // in window mode: the window has been picked for DillyDally too
    @Published var mode = ""             // what macOS has the TV's display doing: mirror, extended, window or off
    @Published var blink = false         // flips while a cast is starting, for the menu-bar icon

    private let defaults = UserDefaults.standard
    private let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/DillyDally.log")  // the casts' log, for working out what went wrong
    private var cast: Cast?
    private var blinkTimer: Timer?

    var fallingBehind: Bool { lag > 0.5 || behind > Double(delay) + 3 }
    var needsAttention: Bool { phase == .idle ? !failure.isEmpty : !hint.isEmpty || fallingBehind || (mode == "window" && !windowChosen) }

    init() {
        defaults.register(defaults: Setting.defaults)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let cast = self?.cast else { return }
            cast.stop()  // it stops the TV on its way out
            cast.wait()
        }
        search()
    }

    func search() {
        guard !searching else { return }
        searching = true
        DispatchQueue.global().async {
            let found = Viera.discover()
            DispatchQueue.main.async {
                self.tvs = found
                self.searching = false
                if !found.contains(where: { $0.ip == self.selected }) {
                    let last = self.defaults.string(forKey: Setting.tv)
                    self.selected = (found.first { $0.name == last } ?? found.first)?.ip
                }
            }
        }
    }

    func start(_ tv: TV) {
        let previous = cast
        stop()
        let buffer = defaults.integer(forKey: Setting.buffer)
        var options = CastOptions()
        options.tv = tv.ip
        options.virtual = true
        options.size = defaults.string(forKey: Setting.size) ?? "auto"
        options.fps = defaults.integer(forKey: Setting.fps)
        options.codec = defaults.string(forKey: Setting.codec) ?? "hevc"
        options.buffer = Double(buffer)
        options.audio = defaults.bool(forKey: Setting.sound)

        // Earlier casts stay in the log until it has grown large.
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? nil
        if size == nil || size! > 500_000 { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let logFile = try? FileHandle(forWritingTo: logURL)
        _ = try? logFile?.seekToEnd()
        let logQueue = DispatchQueue(label: "log")
        let log: (String) -> Void = { line in
            logQueue.async { logFile?.write(Data((line + "\n").utf8)) }
        }
        log("--- cast started \(Date().formatted())")
        var ending: String?  // set once the cast or the helper has said why it is ending

        var cast: Cast!
        cast = Cast(options, log: log) { event in
            DispatchQueue.main.async {
                guard self.cast === cast else { return }
                switch event["event"] as? String {
                case "error": ending = event["text"] as? String
                case "end": ending = ending ?? (event["message"] as? String ?? "")
                default: self.handle(event, tv: tv)
                }
            }
        }
        let started = cast!

        self.cast = started
        target = tv
        selected = tv.ip
        defaults.set(tv.name, forKey: Setting.tv)
        phase = .starting
        step = "Starting…"
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            guard let self, self.phase == .starting else { return timer.invalidate() }
            self.blink.toggle()
        }
        failure = ""
        delay = buffer

        // The cast being replaced has to let go of its port and its display first.
        DispatchQueue.global().async {
            previous?.wait()
            DispatchQueue.main.async {
                guard self.cast === started else { return }
                started.start {
                    DispatchQueue.main.async {
                        guard self.cast === started else { return }  // stopped here, or replaced by a newer cast
                        self.reset()
                        self.failure = ending ?? ""
                    }
                }
            }
        }
    }

    private func handle(_ event: [String: Any], tv: TV) {
        switch event["event"] as? String {
        case "phase":
            switch event["phase"] as? String {
            case "picking": step = "Choose what to share…"
            case "display": step = "Choose what to show…"
            case "buffering": step = "Buffering…"
            case "casting": phase = .casting
            default: break
            }
        case "stream":
            let codec = ["hevc": "HEVC", "h264": "H.264"][event["codec"] as? String ?? ""] ?? ""
            format = [resolutionName(event["size"] as? String ?? ""), "\(event["fps"] as? Int ?? 0)", codec]
                .joined(separator: " · ")
        case "stats":
            mbit = event["mbit"] as? Double ?? 0
            behind = event["behind"] as? Double ?? 0
        case "lag":
            lag = event["seconds"] as? Double ?? 0
        case "hint":
            hint = sentence(event["text"] as? String ?? "")
        case "mode":
            mode = event["mode"] as? String ?? ""
            windowChosen = event["chosen"] as? Bool ?? false
            if let id = event["display"] as? Int { display = CGDirectDisplayID(id) }
            if mode != "extended" { movedApp = nil }  // macOS has taken its windows back
        default: break
        }
    }

    private func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst() + (text.hasSuffix(".") ? "" : ".")
    }

    func stop() {
        guard let cast else { return }
        reset()
        cast.stop()
    }

    /// Apps with a window that could go on the TV.
    var movableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
            .sorted { $0.localizedName!.localizedCaseInsensitiveCompare($1.localizedName!) == .orderedAscending }
    }

    /// Puts an app's main window full screen on the TV's display, or back on this Mac's own.
    func move(_ app: NSRunningApplication, toTV: Bool) {
        let name = app.localizedName ?? "the app"
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            hint = "Allow DillyDally under Accessibility in System Settings so it can move windows, then try again."
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) != .success {
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            value = (windows as? [AXUIElement])?.first
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            hint = "\(name) has no window to move."
            return
        }
        let window = value as! AXUIElement
        let target = toTV ? display : CGMainDisplayID()
        hint = ""
        moving = true
        Task { @MainActor in
            let fullScreen = "AXFullScreen" as CFString
            // A full-screen window cannot be moved, and the animations need a moment each.
            AXUIElementSetAttributeValue(window, fullScreen, kCFBooleanFalse)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var bounds = CGDisplayBounds(target)
            if let origin = AXValueCreate(.cgPoint, &bounds.origin), let size = AXValueCreate(.cgSize, &bounds.size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, origin)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            AXUIElementSetAttributeValue(window, fullScreen, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.moving = false
            guard self.mode == "extended" else { return }
            self.movedApp = toTV ? app : nil
            if !toTV { app.activate() }
        }
    }

    /// Opens the chooser for the window or app to show, in "Window or App" mode.
    func chooseWindow() {
        cast?.signalCapture(SIGUSR1)
    }

    func restart() {
        if let target { start(target) }
    }

    private func reset() {
        cast = nil
        target = nil
        phase = .idle
        step = ""
        hint = ""
        format = ""
        mbit = 0
        behind = 0
        lag = 0
        mode = ""
        display = 0
        movedApp = nil
        moving = false
    }

}

// MARK: - Pieces
//
// The panel is put together like the system's own menu-bar panels (Sound,
// Battery): a bold title, gray section labels, rows with an icon in a circle,
// hairlines between the sections and plain rows of actions at the bottom.

/// The highlight a row gets under the pointer. Like the system's, it reaches out past the panel's margin,
/// to 7 points from the panel's edge, and has round ends that follow the panel's corners.
struct Highlight: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .background(Capsule().fill(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
            .padding(.horizontal, -7)
            .onHover { hovering = $0 }
    }
}

/// A row with its icon in a circle, which is filled with the accent color when the thing is in use.
struct DeviceRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var active = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 32)
    }
}

/// An action as a plain line of text, as at the bottom of the system's panels.
struct MenuRow: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(height: 22).modifier(Highlight())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel

struct Panel: View {
    @ObservedObject var model: CastModel
    @AppStorage(Setting.sound) private var sound = true
    @AppStorage(Setting.size) private var size = "auto"
    @AppStorage(Setting.fps) private var fps = 60
    @AppStorage(Setting.codec) private var codec = "hevc"
    @AppStorage(Setting.buffer) private var buffer = 2
    @State private var showingSettings = false
    @State private var showingInfo = false  // the explanations sit behind an info button
    static let width: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingSettings {
                settingsPage
            } else {
                switch model.phase {
                case .idle: setup
                case .starting: starting
                case .casting: monitor
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if model.phase == .idle { model.search() }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).fontWeight(.bold).frame(height: 22)
    }

    private func label(_ text: String) -> some View {
        Text(text).fontWeight(.semibold).foregroundStyle(.secondary).frame(height: 22)
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
    }

    private var infoButton: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: showingInfo ? "info.circle.fill" : "info.circle").foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What is this?")
    }

    private var rule: some View {
        Divider().padding(.vertical, 6)
    }

    private var settingsRow: some View {
        MenuRow("DillyDally Settings…") { showingSettings = true }
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .padding(.vertical, 4)
    }

    // MARK: Before casting

    private var setup: some View {
        Group {
            HStack {
                title("DillyDally")
                Spacer()
                infoButton
            }
            if showingInfo {
                note("Makes the TV an extra display. Screen Mirroring in the menu bar then chooses what it shows.")
            }
            if !model.failure.isEmpty {
                message(model.failure, symbol: "exclamationmark.triangle.fill", color: .red)
            }
            rule
            HStack {
                label("Cast to")
                Spacer()
                Button(action: model.search) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Look for TVs again")
                .opacity(model.searching ? 0.3 : 1)
                .disabled(model.searching)
            }
            ForEach(model.tvs) { tv in
                Button {
                    model.start(tv)
                } label: {
                    DeviceRow(symbol: "tv", title: tv.name) {
                        Text(resolutionName(tv.size)).foregroundStyle(.secondary)
                    }
                    .modifier(Highlight())
                }
                .buttonStyle(.plain)
            }
            if model.tvs.isEmpty {
                HStack(spacing: 8) {
                    if model.searching { ProgressView().controlSize(.small) }
                    Text(model.searching ? "Looking for TVs…" : "No TV found. Is it on?").foregroundStyle(.secondary)
                }
                .frame(height: 32)
            }
            rule
            settingsRow
        }
    }

    // MARK: Starting

    private var starting: some View {
        Group {
            title("DillyDally")
            rule
            label("Casting to")
            DeviceRow(symbol: "tv", title: model.target?.name ?? "", active: true) {
                ProgressView().controlSize(.small)
            }
            let asking = model.step.hasPrefix("Choose what to show")
            HStack {
                Text(model.mode == "window" ? "Choose the window once more…" : model.step).frame(height: 22)
                Spacer()
                if model.mode == "window" || asking { infoButton }
            }
            if showingInfo, model.mode == "window" {
                note("macOS does not tell DillyDally which window or app you picked, so pick it again in the chooser.")
            } else if showingInfo, asking {
                note("macOS is asking what to show on the TV: the whole screen, one window or app, or a display of its own. If you see no question, open Screen Mirroring in the menu bar.")
            }
            if !model.hint.isEmpty {
                message(model.hint, symbol: "hand.point.up.left.fill", color: .orange)
            }
            rule
            if model.mode == "window" { MenuRow("Choose Window or App…", action: model.chooseWindow) }
            MenuRow("Cancel", action: model.stop)
        }
    }

    // MARK: Casting

    private var monitor: some View {
        Group {
            HStack(spacing: 5) {
                title("DillyDally")
                Spacer()
                Circle().fill(model.fallingBehind ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(model.fallingBehind ? "Falling behind" : "Smooth").foregroundStyle(.secondary)
            }
            note(health).monospacedDigit()
            if model.fallingBehind {
                note(model.lag > 0.5 ? "This Mac cannot encode fast enough. Try 30 frames a second or 1080p."
                                     : "The TV is not keeping up with the stream. Is the Wi-Fi busy?")
            }
            if !model.hint.isEmpty {
                message(model.hint, symbol: "hand.point.up.left.fill", color: .orange)
            }
            rule
            label("Casting to")
            DeviceRow(symbol: "tv", title: model.target?.name ?? "", active: true) {}
            rule
            label("Screen Mirroring")
            DeviceRow(symbol: modeSymbol, title: modeTitle) {}
            rule
            if model.mode == "extended", model.display != 0 {
                if let app = model.movedApp {
                    MenuRow("Bring \(app.localizedName ?? "the App") Back to This Mac") { model.move(app, toTV: false) }
                        .disabled(model.moving)
                } else {
                    Menu {
                        ForEach(model.movableApps, id: \.processIdentifier) { app in
                            Button { model.move(app, toTV: true) } label: {
                                if let icon = menuIcon(app) { Image(nsImage: icon) }
                                Text(app.localizedName ?? "")
                            }
                        }
                    } label: {
                        HStack {
                            Text(model.moving ? "Moving…" : "Move an App to the TV")
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .frame(height: 22)
                        .modifier(Highlight())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .disabled(model.moving)
                }
            }
            if model.mode == "window" {
                MenuRow(model.windowChosen ? "Choose Another Window…" : "Choose Window or App…", action: model.chooseWindow)
            }
            MenuRow("Display Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
            }
            settingsRow
            MenuRow("Stop Casting", action: model.stop)
        }
    }

    /// The app's icon at the size a menu draws one. The copy keeps the app's own icon at full size.
    private func menuIcon(_ app: NSRunningApplication) -> NSImage? {
        guard let icon = app.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// The three modes go by the names Screen Mirroring gives them.
    private var modeTitle: String {
        switch model.mode {
        case "mirror": return "Entire Screen"
        case "window": return model.windowChosen ? "Window or App" : "Choose the window once more"
        case "off": return "This Mac's screen is off"
        case "waiting": return "Waiting for Screen Mirroring"
        default: return "Extended Display"
        }
    }

    private var modeSymbol: String {
        switch model.mode {
        case "mirror": return "rectangle.on.rectangle"
        case "window": return "macwindow.badge.plus"
        case "off": return "moon"
        case "waiting": return "questionmark.square.dashed"
        default: return "rectangle.split.2x1"
        }
    }

    private var health: String {
        var parts = [model.format, model.delay == 0 ? "no buffer" : "\(model.delay) s buffer"].filter { !$0.isEmpty }
        if model.mbit > 0 { parts.append(String(format: "%.0f Mbit/s", model.mbit)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Settings

    private var settingsPage: some View {
        Group {
            HStack {
                Button {
                    showingSettings = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        title("Settings")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                infoButton
            }
            rule
            section("Picture") {
                row("Resolution", $size, [("Auto", "auto"), ("1080p", "1920x1080"), ("4K", "3840x2160")],
                    "Auto is the TV's own resolution when its model is known, otherwise 1080p.")
                row("Frame rate", $fps, [("30", 30), ("60", 60)],
                    "60 is smoother. 30 is easier on this Mac and on the Wi-Fi.")
                row("Codec", $codec, [("H.264", "h264"), ("HEVC", "hevc")],
                    "HEVC looks better at the same size. H.264 is for older TVs, and manages 4K only at 30 frames a second.")
            }
            rule
            section("Playback") {
                row("Buffer", $buffer, [("Off", 0), ("2 s", 2), ("5 s", 5), ("10 s", 10)],
                    "How far behind this Mac the TV plays. A longer buffer rides out Wi-Fi hiccups.")
                toggle("Sound", $sound, "Off sends the picture alone. This Mac's own speakers are not changed either way.")
            }
            rule
            if model.phase != .idle {
                MenuRow("Restart Cast with These Settings") {
                    model.restart()
                    showingSettings = false
                }
            }
            MenuRow("Reset to Defaults") {
                for key in [Setting.size, Setting.fps, Setting.codec, Setting.buffer, Setting.sound] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            MenuRow("Quit DillyDally") { NSApp.terminate(nil) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) { content() }
        }
    }

    @ViewBuilder private func row<Value: Hashable>(_ title: String, _ selection: Binding<Value>,
                                      _ choices: [(String, Value)], _ info: String) -> some View {
        GridRow {
            Text(title).frame(width: 78, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(choices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        explanation(info)
    }

    @ViewBuilder private func toggle(_ title: String, _ isOn: Binding<Bool>, _ info: String) -> some View {
        GridRow {
            Text(title).frame(width: 78, alignment: .leading)
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        explanation(info)
    }

    /// What a setting does, under its row while the info button is on.
    @ViewBuilder private func explanation(_ text: String) -> some View {
        if showingInfo {
            note(text).font(.system(size: 12)).padding(.bottom, 4).gridCellColumns(2)
        }
    }
}

// MARK: - Menu bar

/// The mark from glyph.swift: outlined when idle, solid while casting, blinking
/// between the two while a cast starts, with a dot when something needs a look.
struct MenuBarIcon: View {
    @ObservedObject var model: CastModel

    var body: some View {
        Image(nsImage: Glyph.menuBarImage(filled: model.phase == .casting || (model.phase == .starting && model.blink),
                                          dot: model.needsAttention))
    }
}

@main
struct CastApp: App {
    @StateObject private var model = CastModel()

    init() {
        // When the menu bar runs out of room macOS hides icons from the left, and a new icon starts
        // leftmost. Start at the right end instead, where the sharing indicators cannot push it out;
        // once it has been dragged somewhere, that is remembered under the same key.
        let position = "NSStatusItem Preferred Position Item-0"
        if UserDefaults.standard.object(forKey: position) == nil { UserDefaults.standard.set(1.0, forKey: position) }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
