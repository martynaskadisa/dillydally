// Captures a window, an app or a whole display with ScreenCaptureKit and writes
// it out for the cast (engine.swift) to pipe into ffmpeg:
//
//   --video-fd  raw NV12 frames, exactly --size big, exactly --fps per second
//   --audio-fd  48 kHz stereo 32-bit float PCM (f32le) of the shared content
//
// What to share is chosen in the macOS sharing picker, and can be changed later
// from the menu-bar sharing indicator. --display and --app skip the picker.
//
// --virtual NAME creates an invisible extra display exactly --size big and
// shares that: whatever is put on it reaches the TV pixel for pixel, with no
// scaling, cropping or notch. With --app, that app's window is moved onto it
// and made full screen (needs Accessibility permission; otherwise move it by
// hand with the green window button's "Move to NAME"). SIGUSR1 then swaps the
// app between the Mac's own screen and the virtual one, since you cannot see
// what you are doing on a display that only the TV shows.
//
// Both outputs are paced against one clock and never skip, so ffmpeg can count
// frames and samples to get timestamps that stay in sync. Missing frames are
// filled by repeating the last one, missing audio with silence.
//
// To macOS the virtual display is one more screen, so Screen Mirroring in the
// menu bar decides what it shows: this Mac's whole screen (the built-in screen
// then takes the TV's shape), one window or app, or an extended desktop.
//
// --events reports progress as one JSON object per line on stdout, for a front end.
//
// Exit status: 0 reader went away, 3 the user cancelled or stopped sharing, 1 error.
//
// Build: swiftc -O -import-objc-header virtualdisplay.h capture.swift -o capture

import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct Options {
    var videoFD: Int32 = 3
    var audioFD: Int32 = 4
    var width = 1920
    var height = 1080
    var fps = 60
    var fill = false
    var audio = true
    var display = false
    var app: String?
    var virtual: String?
    var events = false
}

var eventsEnabled = false

func note(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    FileHandle.standardError.write("capture \(time): \(message)\n".data(using: .utf8)!)
}

func emit(_ event: String, _ fields: [String: Any] = [:]) {
    guard eventsEnabled,
          var line = try? JSONSerialization.data(withJSONObject: fields.merging(["event": event]) { $1 }) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

/// Something the user has to do or know about.
func hint(_ message: String) {
    note(message)
    emit("hint", ["text": message])
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    note(message)
    if status == 1 { emit("error", ["text": message]) }
    exit(status)
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = args.next() else { fail("\(flag) needs a value") }
        return v
    }
    while let arg = args.next() {
        switch arg {
        case "--video-fd": o.videoFD = Int32(value(arg)) ?? 3
        case "--audio-fd": o.audioFD = Int32(value(arg)) ?? 4
        case "--size":
            let parts = value(arg).split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { fail("--size wants WIDTHxHEIGHT") }
            (o.width, o.height) = (parts[0], parts[1])
        case "--fps": o.fps = Int(value(arg)) ?? 60
        case "--fill": o.fill = true
        case "--no-audio": o.audio = false
        case "--display": o.display = true
        case "--app": o.app = value(arg)
        case "--virtual": o.virtual = value(arg)
        case "--events": o.events = true
        default: fail("unknown option \(arg)")
        }
    }
    return o
}

let options = parseOptions()
eventsEnabled = options.events
let sampleRate = 48000
let channels = 2
let bytesPerFrame = channels * MemoryLayout<Float32>.size
let chunkBytes = sampleRate / 100 * bytesPerFrame  // 10 ms
let primeBytes = chunkBytes * 6                     // jitter buffer before draining
let maxPendingBytes = chunkBytes * 50               // drop audio older than 0.5 s
let lumaBytes = options.width * options.height
let frameBytes = lumaBytes * 3 / 2
let frameInterval = 1.0 / Double(options.fps)
let videoDelay = 3 * frameInterval                  // lets frames arrive before their slot is written
let maxQueuedFrames = 12

func now() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var pending = Data()
    private var primed = false
    private var frames: [(time: Double, data: Data)] = []
    private var current: Data = {
        // Black in video-range NV12.
        var black = Data(repeating: 16, count: frameBytes)
        black.replaceSubrange(lumaBytes..<frameBytes, with: Data(repeating: 128, count: frameBytes - lumaBytes))
        return black
    }()
    private var clockOffset: Double?
    private var stream: SCStream?
    private(set) var running = false
    var isCapturing: Bool { stream != nil }
    /// Set to be told when the stream is lost instead of ending the cast: the
    /// TV then holds the last picture until `use` is given something new.
    var onLost: (() -> Void)?

    /// Start sharing `filter`, or switch to it if a stream is already running.
    func use(_ filter: SCContentFilter) {
        Task { @MainActor in
            do {
                let config = self.configuration(for: filter)
                if let stream = self.stream {
                    try await stream.updateContentFilter(filter)
                    try await stream.updateConfiguration(config)
                    return
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture.video"))
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "capture.audio"))
                self.stream = stream
                try await stream.startCapture()
                if !self.running {
                    self.running = true
                    self.startWriters()
                }
            } catch {
                guard self.running, let onLost = self.onLost else { fail(error.localizedDescription) }
                note("capture lost: \(error.localizedDescription)")
                if let stream = self.stream {
                    self.stream = nil
                    try? await stream.stopCapture()
                }
                onLost()
            }
        }
    }

    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = options.width
        config.height = options.height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 6
        config.showsCursor = true
        config.scalesToFit = true  // the system scales and letterboxes into the output size
        config.capturesAudio = options.audio
        config.sampleRate = sampleRate
        config.channelCount = channels
        config.excludesCurrentProcessAudio = true

        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { return config }
        var rect = CGRect(origin: .zero, size: size)
        if filter.style != .window {
            // The strip beside a MacBook's notch is menu bar or plain black; leave it out.
            let top = notchHeight(of: filter)
            rect.origin.y += top
            rect.size.height -= top
        }
        if options.fill {
            // Crop the middle to the output's shape so nothing is left black.
            let shape = CGFloat(options.width) / CGFloat(options.height)
            let width = min(rect.width, rect.height * shape)
            let height = min(rect.height, rect.width / shape)
            rect = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        if rect.size != size {
            config.sourceRect = rect
        }
        return config
    }

    private func notchHeight(of filter: SCContentFilter) -> CGFloat {
        let id = filter.includedDisplays.first?.displayID ?? CGMainDisplayID()
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
        return screen?.safeAreaInsets.top ?? 0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer)
        default: break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }  // idle frames carry no picture

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) == 2,
              CVPixelBufferGetWidthOfPlane(pixels, 0) == options.width,
              CVPixelBufferGetHeightOfPlane(pixels, 0) == options.height else { return }

        // Repack without the row padding ffmpeg's rawvideo reader does not expect.
        var data = Data(count: frameBytes)
        data.withUnsafeMutableBytes { raw in
            var destination = raw.baseAddress!
            for plane in 0..<2 {
                guard let source = CVPixelBufferGetBaseAddressOfPlane(pixels, plane) else { return }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
                for row in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
                    memcpy(destination, source + row * stride, options.width)
                    destination += options.width
                }
            }
        }

        let arrival = now()
        var time = sampleBuffer.presentationTimeStamp.seconds
        lock.lock()
        if clockOffset == nil {
            // Frame times are normally on the host clock; if not, fall back to arrival time.
            clockOffset = abs(arrival - time) < 0.5 ? 0 : arrival - time
        }
        time += clockOffset!
        frames.append((time, data))
        if frames.count > maxQueuedFrames { frames.removeFirst() }
        lock.unlock()
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        let count = sampleBuffer.numSamples
        guard count > 0 else { return }
        var interleaved = [Float32](repeating: 0, count: count * channels)
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            if buffers.count >= channels {
                // Planar: one buffer per channel.
                for ch in 0..<channels {
                    guard let src = buffers[ch].mData?.assumingMemoryBound(to: Float32.self) else { continue }
                    for i in 0..<count { interleaved[i * channels + ch] = src[i] }
                }
            } else if let src = buffers[0].mData?.assumingMemoryBound(to: Float32.self) {
                let srcChannels = max(1, Int(buffers[0].mNumberChannels))
                for i in 0..<count {
                    for ch in 0..<channels {
                        interleaved[i * channels + ch] = src[i * srcChannels + min(ch, srcChannels - 1)]
                    }
                }
            }
        }
        let data = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        pending.append(data)
        if pending.count > maxPendingBytes {
            let excess = (pending.count - maxPendingBytes) / bytesPerFrame * bytesPerFrame
            pending.removeFirst(excess)
        }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stopping from the menu-bar sharing indicator ends the cast.
        let stoppedByUser = (error as NSError).code == SCStreamError.userStopped.rawValue
        if stoppedByUser { fail("sharing stopped", status: 3) }
        guard let onLost else { fail("stream stopped: \(error.localizedDescription)") }
        note("capture lost: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil }
            onLost()
        }
    }

    /// The newest frame shown at or before `time`.
    private func frame(at time: Double) -> Data {
        lock.lock()
        defer { lock.unlock() }
        while let first = frames.first, first.time <= time {
            current = first.data
            frames.removeFirst()
        }
        return current
    }

    /// Next 10 ms of audio, or silence while the jitter buffer refills.
    private func nextChunk() -> Data {
        lock.lock()
        defer { lock.unlock() }
        if !primed && pending.count >= primeBytes { primed = true }
        if primed && pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            return Data(chunk)
        }
        primed = false
        return Data(count: chunkBytes)
    }

    /// Run `next` once per `interval` from `start`, catching up instead of skipping when the pipe was slow.
    /// `reportEvery` > 0 also reports how far behind the clock the pipe's reader has let us fall.
    private func pace(from start: Double, every interval: Double, fd: Int32, reportEvery: Int = 0,
                      next: @escaping (Int) -> Data) {
        Thread {
            var written = 0
            while true {
                let wait = start + Double(written) * interval - now()
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
                if reportEvery > 0, written % reportEvery == 0 {
                    emit("lag", ["seconds": (max(0, -wait) * 100).rounded() / 100])
                }
                if !writeAll(fd, next(written)) { exit(0) }  // reader went away
                written += 1
            }
        }.start()
    }

    private func startWriters() {
        let start = now()
        pace(from: start, every: frameInterval, fd: options.videoFD, reportEvery: options.fps * 2) { index in
            self.frame(at: start + Double(index) * frameInterval - videoDelay)
        }
        pace(from: start, every: 0.01, fd: options.audioFD) { _ in self.nextChunk() }
    }
}

final class PickerObserver: NSObject, SCContentSharingPickerObserver {
    let capture: Capture

    init(capture: Capture) {
        self.capture = capture
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        capture.use(filter)
        if watchedDisplay != kCGNullDirectDisplay, CGDisplayIsOnline(watchedDisplay) == 0 {
            windowChosen = true
            note("capturing the chosen window or app")
            emit("mode", ["mode": "window", "chosen": true])
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        if !capture.running, watchedDisplay == kCGNullDirectDisplay { fail("nothing chosen", status: 3) }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        fail("picker failed: \(error.localizedDescription)")
    }
}

func wholeDisplay() async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else { fail("no display found") }
    return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
}

func largestWindow(ofAppNamed name: String) async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let windows = content.windows.filter {
        $0.windowLayer == 0 && $0.frame.width >= 200 && $0.frame.height >= 200
            && ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(name)
    }
    guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
        fail("no open window of an app called \"\(name)\"")
    }
    return SCContentFilter(desktopIndependentWindow: window)
}

/// An extra display that exists only while this process runs, exactly as big as the stream.
func makeVirtualDisplay(named name: String) -> CGVirtualDisplay {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = DispatchQueue(label: "capture.display")
    descriptor.name = name
    descriptor.maxPixelsWide = UInt(options.width)
    descriptor.maxPixelsHigh = UInt(options.height)
    // Only the proportions matter; this is a 50-inch 16:9 panel.
    descriptor.sizeInMillimeters = CGSize(width: 1107, height: 1107 * options.height / options.width)
    descriptor.vendorID = 0x4341
    descriptor.productID = 0x5354
    // macOS remembers what each display was last used for, and a remembered
    // "Window or App" waits silently for a window to be chosen. A display it
    // has never seen gets the full "What do you want to show?" prompt.
    descriptor.serialNum = UInt32.random(in: 2...UInt32.max)
    guard let display = CGVirtualDisplay(descriptor: descriptor) else { fail("could not create a virtual display") }
    let settings = CGVirtualDisplaySettings()
    // 4K is run as a Retina 1080p desktop so the app's interface stays readable on the TV.
    let retina = options.width >= 3840
    settings.hiDPI = retina ? 1 : 0
    let scale = retina ? 2 : 1
    settings.modes = [CGVirtualDisplayMode(width: UInt(options.width / scale), height: UInt(options.height / scale),
                                           refreshRate: Double(options.fps))]
    guard display.apply(settings) else { fail("could not set up the virtual display") }
    return display
}

/// A Retina display also lists its size at 1x, and macOS may put it on that one.
/// Returns whether the mode had to be changed.
func selectFullMode(of id: CGDirectDisplayID) -> Bool {
    let all = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(id, all) as? [CGDisplayMode] ?? []
    guard CGDisplayCopyDisplayMode(id)?.pixelWidth != options.width,
          let mode = modes.first(where: { $0.pixelWidth == options.width && $0.pixelHeight == options.height })
    else { return false }
    CGDisplaySetDisplayMode(id, mode, nil)
    return true
}

/// The display whose picture is the virtual display's: itself, unless it has
/// been made a mirror of another one.
func source(of id: CGDirectDisplayID) -> CGDirectDisplayID {
    let mirrored = CGDisplayMirrorsDisplay(id)
    return mirrored == kCGNullDirectDisplay ? id : mirrored
}

func filter(showing id: CGDirectDisplayID) async -> SCContentFilter? {
    let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content?.displays.first(where: { $0.displayID == source(of: id) }), display.width > 0 else {
        return nil
    }
    return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
}

/// A new display takes a moment to come online.
func filter(forDisplay id: CGDirectDisplayID) async throws -> SCContentFilter {
    note("waiting for the display")
    emit("phase", ["phase": "display"])
    var modeChecked = false
    for _ in 0..<600 {
        if CGDisplayIsOnline(id) != 0, !modeChecked {
            modeChecked = true
            if selectFullMode(of: id) { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        if CGDisplayIsOnline(id) != 0, let filter = await filter(showing: id) { return filter }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    fail("the virtual display never came online")
}

var watchedDisplay = kCGNullDirectDisplay
var displayCheck: DispatchWorkItem?
var lastDisplayState = ""
var windowChosenAt = 0.0
var windowChosen = false { didSet { windowChosenAt = now() } }  // sharing a window chosen in our own picker while the display is away

/// Whether Screen Mirroring has the display in "Window or App" mode, which
/// only a private part of the window server can say. nil if it will not.
func isMirroringWindows(_ id: CGDirectDisplayID) -> Bool? {
    guard let manager = windowMirroringManager(), manager.responds(to: NSSelectorFromString("windowMirroringDisplays")),
          let displays = manager.perform(NSSelectorFromString("windowMirroringDisplays"))?.takeUnretainedValue() as? NSSet
    else { return nil }
    return displays.contains(NSNumber(value: id))
}

func windowMirroringManager() -> NSObject? {
    let shared = NSSelectorFromString("shared")
    guard let type = NSClassFromString("SLWindowMirroringManager") as? NSObject.Type, type.responds(to: shared) else { return nil }
    return type.perform(shared)?.takeUnretainedValue() as? NSObject
}

/// A display in that mode is covered by a "shield" window until a window or
/// app has been picked for it, so this says whether macOS is still waiting for one.
func isShielded(_ id: CGDirectDisplayID) -> Bool {
    let shield = NSSelectorFromString("shieldWindowForDisplay:")
    guard let manager = windowMirroringManager(), manager.responds(to: shield) else { return false }
    guard let number = manager.perform(shield, with: NSNumber(value: id))?.takeUnretainedValue() as? NSNumber else { return false }
    // The manager goes on naming the shield after it has been taken down.
    let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return onScreen.contains { $0[kCGWindowNumber as String] as? UInt32 == number.uint32Value }
}

/// The window last clicked, and when: macOS has a window picked by clicking
/// on it, which is the only clue to which one it is mirroring.
var lastClick: (window: CGWindowID, time: Double)?

func watchClicks() {
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
        guard let point = CGEvent(source: nil)?.location else { return }
        // Front to back. The picker lays a highlight of its own over each window.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, !executable(of: pid).hasSuffix("/ControlCenter"),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  let number = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            lastClick = (number, now())
            note("click on window \(number) of \(window[kCGWindowOwnerName as String] as? String ?? "?")")
            return
        }
    }
}

/// The window just picked for macOS to mirror, if a click gave it away.
func pickedWindow() async -> SCContentFilter? {
    guard let click = lastClick, now() - click.time < 5 else {
        note("no recent click to go by" + (lastClick.map { ": the last was \(Int(now() - $0.time)) s ago" } ?? ""))
        return nil
    }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
          let window = content.windows.first(where: { $0.windowID == click.window }) else {
        note("the clicked window \(click.window) cannot be captured")
        return nil
    }
    note("capturing the window that was clicked: \(window.owningApplication?.applicationName ?? "?")")
    return SCContentFilter(desktopIndependentWindow: window)
}

/// Whether macOS is still asking what to show on a new display, or having a
/// window picked for it. Both are drawn by Control Center's helper, and a
/// display counts as mirroring windows from the moment the question is asked.
func macOSIsAsking() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
        return executable(of: pid).hasSuffix("/ControlCenterHelper")
    }
}

func executable(of pid: pid_t) -> String {
    var path = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
}

/// In "Window or App" mode the display stays offline and nothing is drawn on
/// it: macOS only hands the chosen windows to a receiver of its own, and does
/// not say which they are. So ask for the window once more and capture it directly.
func chooseWindow() {
    guard CGDisplayIsOnline(watchedDisplay) == 0 else { return }
    NSApplication.shared.activate(ignoringOtherApps: true)
    SCContentSharingPicker.shared.present()
}

/// Reports what Screen Mirroring has the display doing and points the capture
/// at it. While there is nothing to capture it keeps looking.
func followDisplay() async {
    let id = watchedDisplay
    let online = CGDisplayIsOnline(id) != 0
    if online, selectFullMode(of: id) { return }  // which calls back here again
    let filter = online ? await filter(showing: id) : nil
    // "Window or App" takes the display offline, as does this Mac's screen going to sleep.
    // Offline, it is in that mode, or waiting to be told what to show, or this Mac's screen is asleep.
    let awake = CGDisplayIsActive(CGMainDisplayID()) != 0
    let mode = online ? (CGDisplayIsInMirrorSet(id) != 0 ? "mirror" : "extended")
                      : !awake ? "off" : isMirroringWindows(id) ?? true && !isShielded(id) && !macOSIsAsking() ? "window" : "waiting"
    let size = CGDisplayCopyDisplayMode(id)
    var state = "display \(id): \(mode), showing display \(source(of: id)), "
        + "\(size?.pixelWidth ?? 0)x\(size?.pixelHeight ?? 0), main display \(CGMainDisplayID())"
    if !online {
        state += ", window mirroring \(isMirroringWindows(id).map(String.init) ?? "unknown"), "
            + "shielded \(isShielded(id)), asking \(macOSIsAsking())"
    }
    if state != lastDisplayState {
        lastDisplayState = state
        note(state)
        emit("mode", ["mode": mode, "chosen": false, "display": Int(id)])
        windowChosen = false
        if mode == "window" {
            if let picked = await pickedWindow() {
                capture.use(picked)
                windowChosen = true
                emit("mode", ["mode": "window", "chosen": true])
            } else {
                chooseWindow()
            }
        }
    }
    if let filter {
        capture.use(filter)
    } else {
        if mode == "window", windowChosen, !capture.isCapturing, now() - windowChosenAt > 3 {
            // The window we were showing has gone, or could not be captured.
            windowChosen = false
            emit("mode", ["mode": mode, "chosen": false])
            chooseWindow()
        }
        checkDisplay(after: 1)
    }
}

func checkDisplay(after delay: Double) {
    DispatchQueue.main.async {
        displayCheck?.cancel()
        let check = DispatchWorkItem { Task { await followDisplay() } }
        displayCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }
}

/// Screen Mirroring in the menu bar can change what the display shows at any
/// time, and some changes end the stream. This keeps the display at full
/// resolution, follows it from screen to screen and restarts the capture.
func watchDisplay(_ id: CGDirectDisplayID) {
    watchedDisplay = id
    capture.onLost = { checkDisplay(after: 1) }
    watchClicks()
    if options.app == nil {  // with --app the signal swaps the app between screens instead
        signal(SIGUSR1, SIG_IGN)
        swapSignal.setEventHandler { chooseWindow() }
        swapSignal.resume()
    }
    checkDisplay(after: 0)
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
        guard !flags.contains(.beginConfigurationFlag) else { return }
        checkDisplay(after: 1.5)  // one change arrives as a burst of callbacks; wait for it to settle
    }, nil)
}

/// Put an app's main window full screen on a display, through the Accessibility API.
/// Returns whether it could.
func moveApp(named name: String, toDisplay id: CGDirectDisplayID, called displayName: String) async -> Bool {
    let advice = "move it yourself: hover the green window button and choose \"Move to \(displayName)\""
    guard AXIsProcessTrusted() else {
        hint("no Accessibility permission to move \(name); \(advice)")
        return false
    }
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.activationPolicy == .regular && ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
    }) else {
        hint("\(name) is not running; open it, then \(advice)")
        return false
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) != .success {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
        value = (windows as? [AXUIElement])?.first
    }
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        hint("\(name) has no window to move; \(advice)")
        return false
    }
    let window = value as! AXUIElement
    let fullScreen = "AXFullScreen" as CFString
    // A full-screen window cannot be moved, and the animations need a moment each.
    AXUIElementSetAttributeValue(window, fullScreen, kCFBooleanFalse)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    var bounds = CGDisplayBounds(id)
    if let origin = AXValueCreate(.cgPoint, &bounds.origin), let size = AXValueCreate(.cgSize, &bounds.size) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, origin)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
    AXUIElementSetAttributeValue(window, fullScreen, kCFBooleanTrue)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    return true
}

func reportApp() {
    emit("app", ["on": appIsOnVirtualDisplay ? "tv" : "mac"])
}

var virtualDisplay: CGVirtualDisplay?  // kept alive for as long as we share it
var appIsOnVirtualDisplay = false
var appIsMoving = false
let swapSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon
let capture = Capture()
let observer = PickerObserver(capture: capture)

// The picker stays registered even with --display/--app, so the menu-bar indicator can switch content.
let picker = SCContentSharingPicker.shared
var pickerConfiguration = SCContentSharingPickerConfiguration()
pickerConfiguration.allowedPickerModes = [.singleWindow, .singleApplication, .singleDisplay]
picker.defaultConfiguration = pickerConfiguration
picker.add(observer)
picker.isActive = true

DispatchQueue.main.async {
    if let name = options.virtual {
        let display = makeVirtualDisplay(named: name)
        virtualDisplay = display
        Task {
            do {
                guard let app = options.app else {
                    // Starts the capture once Screen Mirroring has been told what to show.
                    emit("phase", ["phase": "display"])
                    watchDisplay(display.displayID)
                    return
                }
                let filter = try await filter(forDisplay: display.displayID)
                do {
                    appIsOnVirtualDisplay = await moveApp(named: app, toDisplay: display.displayID, called: name)
                    reportApp()
                    signal(SIGUSR1, SIG_IGN)  // handled by the dispatch source instead
                    swapSignal.setEventHandler {
                        guard !appIsMoving else { return }
                        appIsMoving = true
                        let toTV = !appIsOnVirtualDisplay
                        Task {
                            if await moveApp(named: app, toDisplay: toTV ? display.displayID : CGMainDisplayID(),
                                             called: name) {
                                appIsOnVirtualDisplay = toTV
                            }
                            reportApp()
                            appIsMoving = false
                        }
                    }
                    swapSignal.resume()
                }
                capture.use(filter)
                watchDisplay(display.displayID)
            } catch {
                fail(error.localizedDescription)
            }
        }
    } else if options.display || options.app != nil {
        Task {
            do {
                capture.use(try await options.display ? wholeDisplay() : largestWindow(ofAppNamed: options.app!))
            } catch {
                fail(error.localizedDescription)
            }
        }
    } else {
        app.activate(ignoringOtherApps: true)
        picker.present()
    }
}
app.run()
