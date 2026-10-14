// The cast itself, shared by the menu-bar app and the command-line tool.
//
// The TV has no AirPlay, so the capture helper (capture.swift) grabs picture
// and sound with ScreenCaptureKit, ffmpeg encodes them into an MPEG-TS stream
// served over HTTP, and the TV's DLNA media renderer is told to play that URL.
//
// The TV buffers very little by itself and can stutter when fed in real time,
// so one encoder runs continuously into a ring buffer and the TV starts
// playing a little behind the live edge (CastOptions.buffer). Picture and sound
// stay in sync either way because they share one container.

import Foundation

struct TV: Identifiable, Equatable {
    let ip: String
    let name: String
    let model: String
    let size: String  // the panel's own resolution, empty if the model is unknown

    var id: String { ip }
}

struct CastError: Error {
    let message: String
}

/// Seconds on a clock that never jumps.
func uptime() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

/// Splits a pipe's output into lines, keeping an unfinished one for the next read.
final class LineReader {
    private var rest = Data()

    func lines(adding data: Data) -> [String] {
        rest.append(data)
        var lines: [String] = []
        while let newline = rest.firstIndex(of: 0x0A) {
            lines.append(String(decoding: rest[rest.startIndex..<newline], as: UTF8.self))
            rest.removeSubrange(rest.startIndex...newline)
        }
        return lines
    }
}

// MARK: The TV

/// A Panasonic Viera's DLNA media renderer.
enum Viera {
    static let port = 55000
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let features = "DLNA.ORG_OP=01;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000"
    static let mime = "video/mpeg"
    /// Panel sizes by model name. TVs do not report this over DLNA, so it is a hand-kept list.
    static let knownSizes = ["TH-50MX900": "3840x2160"]

    /// A blocking request; never call it on the main thread.
    private static func fetch(_ request: URLRequest) -> (body: String, status: Int, error: Error?) {
        let done = DispatchSemaphore(value: 0)
        var result = ("", 0, nil as Error?)
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = (String(decoding: data ?? Data(), as: UTF8.self), (response as? HTTPURLResponse)?.statusCode ?? 0, error)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private static func get(_ url: String) -> String {
        guard let url = URL(string: url) else { return "" }
        return fetch(URLRequest(url: url, timeoutInterval: 5)).body
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    static func soap(_ tv: String, _ action: String, _ body: String = "") throws -> String {
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"\(avTransport)\"><InstanceID>0</InstanceID>\(body)</u:\(action)>"
            + "</s:Body></s:Envelope>"
        var request = URLRequest(url: URL(string: "http://\(tv):\(port)/dmr/control_2")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Data(envelope.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(avTransport)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let reply = fetch(request)
        if let error = reply.error {
            throw CastError(message: "cannot reach the TV at \(tv): \(error.localizedDescription)")
        }
        guard reply.status < 400 else {
            let code = firstMatch("<errorCode>(\\d+)</errorCode>", in: reply.body) ?? String(reply.status)
            let description = firstMatch("<errorDescription>(.*?)</errorDescription>", in: reply.body) ?? ""
            throw CastError(message: "TV rejected \(action): \(code) \(description)")
        }
        return reply.body
    }

    /// Find Viera media renderers on the local network with SSDP.
    static func discover() -> [TV] {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return [] }
        defer { close(s) }
        var ttl: UInt8 = 2
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var group = sockaddr_in()
        group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        group.sin_family = sa_family_t(AF_INET)
        group.sin_port = UInt16(1900).bigEndian
        group.sin_addr.s_addr = inet_addr("239.255.255.250")
        let search = Array(("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\nMX: 2\r\n"
            + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n").utf8)

        var found: [String: String] = [:]  // ip: where its description is
        for _ in 0..<3 where found.isEmpty {
            _ = withUnsafePointer(to: &group) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, search, search.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var reply = [UInt8](repeating: 0, count: 4096)
            while true {
                var sender = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &reply, reply.count, 0, $0, &length) }
                }
                guard count > 0 else { break }  // a second without replies
                let text = String(decoding: reply[0..<count], as: UTF8.self)
                guard let location = firstMatch("^location:\\s*(\\S+)", in: text), location.contains(":\(port)/dmr/") else { continue }
                let ip = String(cString: inet_ntoa(sender.sin_addr))
                if found[ip] == nil { found[ip] = location }
            }
        }
        return found.sorted { $0.key < $1.key }.map { ip, location in
            let description = get(location)
            let model = firstMatch("<modelName>(.*?)</modelName>", in: description) ?? ""
            return TV(ip: ip, name: firstMatch("<friendlyName>(.*?)</friendlyName>", in: description) ?? "Viera",
                      model: model, size: knownSizes[model] ?? "")
        }
    }

    static func model(of ip: String) -> String {
        firstMatch("<modelName>(.*?)</modelName>", in: get("http://\(ip):\(port)/dmr/ddd.xml")) ?? ""
    }

    static func play(_ tv: String, url: String) throws {
        let didl = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>MacBook screen</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):\(features)\">\(escape(url))</res>"
            + "</item></DIDL-Lite>"
        _ = try? soap(tv, "Stop")  // fails when nothing was playing
        try soap(tv, "SetAVTransportURI",
                 "<CurrentURI>\(escape(url))</CurrentURI><CurrentURIMetaData>\(escape(didl))</CurrentURIMetaData>")
        try soap(tv, "Play", "<Speed>1</Speed>")
    }

    /// This Mac's address as the TV sees it.
    static func localAddress(toward tv: String) -> String {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(s) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(port).bigEndian
        remote.sin_addr.s_addr = inet_addr(tv)
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, length) }
        }
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
        }
        return String(cString: inet_ntoa(local.sin_addr))
    }
}

// MARK: The stream

/// The encoder's output in a ring buffer addressed by absolute byte offset.
///
/// Readers join at an exact offset, so a TV that reconnects gets the bytes it
/// asked for instead of a restarted stream. Offsets that do not exist yet block
/// until the encoder has produced them.
final class Hub {
    static let chunk = 188 * 64   // entries are whole TS packets, so any entry is a valid start
    static let history = 60.0     // seconds kept behind the buffer so a slow or reconnecting TV can resume

    private let cond = NSCondition()
    private var chunks: [(offset: Int, time: Double, data: Data)] = []  // every entry `chunk` long
    private var total = 0
    private var stopping = false
    private var sent = 0
    private var tvPosition = 0
    private let buffer: Double

    init(buffer: Double) {
        self.buffer = buffer
    }

    private func locked<T>(_ body: () -> T) -> T {
        cond.lock()
        defer { cond.unlock() }
        return body()
    }

    func append(_ data: Data) {
        let now = uptime()
        locked {
            chunks.append((total, now, data))
            total += Hub.chunk
            let horizon = now - buffer - Hub.history
            if let keep = chunks.firstIndex(where: { $0.time >= horizon }), keep > 2048 {
                chunks.removeFirst(keep)  // in batches, as removing from the front moves the rest
            }
            cond.broadcast()
        }
    }

    func stop() {
        locked {
            stopping = true
            cond.broadcast()
        }
    }

    var produced: Int { locked { total } }

    var bufferedSeconds: Double {
        locked { chunks.first.map { uptime() - $0.time } ?? 0 }
    }

    /// Offset of the oldest chunk produced within the last `seconds`.
    func offsetBehindLive(_ seconds: Double) -> Int {
        let cutoff = uptime() - seconds
        return locked { chunks.first { $0.time >= cutoff }?.offset ?? total }
    }

    /// How far behind the live edge a reader at `position` is, in seconds.
    func delay(at position: Int) -> Double {
        locked {
            guard let first = chunks.first, position < total else { return 0 }
            return uptime() - chunks[max(0, (position - first.offset) / Hub.chunk)].time
        }
    }

    /// Bookkeeping for the front end: bytes that went to the TV, and how far it has read.
    func noteSent(_ count: Int, position: Int) {
        locked {
            sent += count
            tvPosition = position
        }
    }

    var progress: (sent: Int, position: Int) { locked { (sent, tvPosition) } }

    /// The next block from absolute offset `position`, which is moved past it; nil once the cast is over.
    func next(from position: inout Int) -> Data? {
        cond.lock()
        while total <= position && !stopping { cond.wait(until: Date().addingTimeInterval(5)) }
        guard !stopping, let first = chunks.first?.offset else {
            cond.unlock()
            return nil
        }
        if position < first { position = first }  // fell out of the ring: continue with the oldest data
        let index = (position - first) / Hub.chunk, skip = (position - first) % Hub.chunk
        let parts = chunks[index..<min(index + 32, chunks.count)].map(\.data)
        cond.unlock()
        var block = Data(capacity: parts.count * Hub.chunk)
        parts.forEach { block.append($0) }
        if skip > 0 { block.removeFirst(skip) }
        position += block.count
        return block
    }
}

/// Maps the TV's file offsets onto hub offsets for the current playback.
final class Session {
    private let hub: Hub
    private let bufferSeconds: Double
    private let lock = NSLock()
    private var base: Int?

    init(hub: Hub, bufferSeconds: Double) {
        self.hub = hub
        self.bufferSeconds = bufferSeconds
    }

    func reset() {
        lock.lock()
        base = nil
        lock.unlock()
    }

    func hubOffset(_ clientOffset: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if base == nil { base = hub.offsetBehindLive(bufferSeconds) }
        return base! + clientOffset
    }
}

/// Serves the stream to the TV: plain HTTP/1.0, one thread and one blocking socket per request.
final class StreamServer {
    static let fakeSize = 1_900_000_000  // advertised on range replies; TV firmware does signed 32-bit maths

    private let listener: Int32
    private let hub: Hub
    private let session: Session
    private let stats: Bool
    private let log: (String) -> Void

    init(port: Int, hub: Hub, session: Session, stats: Bool, log: @escaping (String) -> Void) throws {
        self.hub = hub
        self.session = session
        self.stats = stats
        self.log = log
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw CastError(message: "Port \(port) is in use. Is another cast still running?")
        }
    }

    func start() {
        Thread { [self] in
            while true {
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
                }
                guard client >= 0 else {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return  // stopped
                }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                let peer = String(cString: inet_ntoa(address.sin_addr))
                Thread { [self] in
                    serve(client, peer: peer)
                    close(client)
                }.start()
            }
        }.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func send(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let count = write(client, bytes.baseAddress! + done, bytes.count - done)
                if count > 0 { done += count } else if errno != EINTR { return false }
            }
            return true
        }
    }

    private func serve(_ client: Int32, peer: String) {
        var head = Data()
        var byte = [UInt8](repeating: 0, count: 2048)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &byte, byte.count)
            guard count > 0, head.count < 65536 else { return }
            head.append(contentsOf: byte[0..<count])
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ").map(String.init)
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD" else { return }
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        var start = 0
        var end: Int?
        if let rangeHeader, let from = firstMatch("^bytes=(\\d+)-", in: rangeHeader) {
            start = Int(from) ?? 0
            end = firstMatch("^bytes=\\d+-(\\d+)", in: rangeHeader).flatMap { Int($0) }
        }

        let partial = start > 0 || end != nil
        var reply = partial ? "HTTP/1.0 206 Partial Content\r\n" : "HTTP/1.0 200 OK\r\n"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(identifier: "GMT")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        reply += "Server: DillyDally\r\nDate: \(date.string(from: Date()))\r\n"
        if partial {
            let last = end ?? StreamServer.fakeSize - 1
            reply += "Content-Range: bytes \(start)-\(last)/\(StreamServer.fakeSize)\r\n"
            reply += "Content-Length: \(last - start + 1)\r\n"
        }
        reply += "Content-Type: \(Viera.mime)\r\nAccept-Ranges: bytes\r\ntransferMode.dlna.org: Streaming\r\n"
        reply += "contentFeatures.dlna.org: \(Viera.features)\r\nConnection: close\r\n\r\n"
        log("[\(peer)] \"\(lines[0])\" \(partial ? 206 : 200) -" + (rangeHeader.map { " Range: \($0)" } ?? ""))
        guard send(Data(reply.utf8), to: client), request[0] == "GET" else { return }

        // /live starts at the live edge, for inspecting the stream without touching the session.
        let live = request[1].hasPrefix("/live")
        var position = live ? hub.produced : session.hubOffset(start)
        var remaining = end.map { $0 - start + 1 }
        var sent = 0, blocked = 0.0, worst = 0.0, mark = uptime()
        while var block = hub.next(from: &position) {
            if let left = remaining {
                block = block.prefix(left)
                remaining = left - block.count
            }
            let began = uptime()
            guard send(block, to: client) else { return }
            let took = uptime() - began
            sent += block.count
            if !live { hub.noteSent(block.count, position: position) }
            blocked += took
            worst = max(worst, took)
            if remaining == 0 { return }
            if stats, began - mark >= 5 {
                log(String(format: "[stats] %5.1f Mbit/s to %@, reading %4.1f s behind live, "
                           + "send blocked %3.0f%% of the time, longest %.0f ms",
                           Double(sent) * 8 / (began - mark) / 1e6, peer, hub.delay(at: position),
                           blocked / (began - mark) * 100, worst * 1000))
                sent = 0
                blocked = 0
                worst = 0
                mark = began
            }
        }
    }
}

// MARK: The helper programs

/// A child process started with exactly the file descriptors it is given.
final class Child {
    let pid: pid_t
    private var status: Int32?
    private let lock = NSLock()

    /// `inherit` keeps its numbers in the child; `stdout` and `stderr` become the child's own.
    init(_ path: String, _ arguments: [String], inherit: [Int32], stdout: Int32, stderr: Int32,
         environment: [String: String]) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        inherit.forEach { posix_spawn_file_actions_addinherit_np(&actions, $0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))  // nothing else leaks into it
        var argv = ([path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0)=\($1)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard error == 0 else {
            throw CastError(message: "Could not start \((path as NSString).lastPathComponent): \(String(cString: strerror(error)))")
        }
        self.pid = pid
    }

    /// The exit code, if it has exited normally by now.
    func exitCode() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if status == nil {
            var result: Int32 = 0
            if waitpid(pid, &result, WNOHANG) == pid { status = result }
        }
        guard let status, status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    func signal(_ number: Int32) {
        lock.lock()
        if status == nil { kill(pid, number) }
        lock.unlock()
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard status == nil else { return }
        kill(pid, SIGKILL)
        var result: Int32 = 0
        waitpid(pid, &result, 0)
        status = result
    }
}

struct CastOptions {
    var tv: String?           // the TV's address; only --serve-only can do without
    var port = 8090
    var app: String?          // share this app's largest window instead of asking
    var display = false       // share the whole screen instead of asking
    var virtual = false       // make the TV a display of its own, which Screen Mirroring then controls
    var size = "auto"         // WIDTHxHEIGHT, or auto for the TV's own if its model is known
    var fps = 60
    var codec = "hevc"        // or h264, the safe choice for older TVs
    var bitrate: String?      // e.g. 20M; by default chosen from the size and codec
    var buffer = 2.0          // seconds the TV plays behind live, as a cushion against stutter
    var fill = false          // crop what is shared to the TV's shape instead of adding black bars
    var gain = 12.0           // audio boost in dB
    var audio = true
    var stats = false         // log send rate, delay and stalls every 5 s
    var serveOnly = false     // run the encoder and server without telling the TV to play
}

/// One cast, from start to stop. `log` gets lines for a person, `event` what a
/// front end needs to know, as the same objects the capture helper reports:
/// stream, phase, stats, lag, hint, mode, error and end. Both are called on
/// background threads.
final class Cast {
    static let displayName = "DillyDally"
    static let defaultSize = "1920x1080"
    static let bitrates = ["h264": ["1920x1080": "20M", "3840x2160": "45M"],
                           "hevc": ["1920x1080": "12M", "3840x2160": "30M"]]
    static let userStopped: Int32 = 3  // the helper's exit status when sharing is cancelled or stopped

    private var options: CastOptions
    private let log: (String) -> Void
    private let event: ([String: Any]) -> Void
    private let state = NSCondition()
    private var cancelled = false
    private var captureEnded = false
    private var stoppedByUser = false
    private var started = false
    private var finished = false
    private var hub: Hub!
    private var children: [Child] = []  // the encoder, then the capture helper

    init(_ options: CastOptions, log: @escaping (String) -> Void, event: @escaping ([String: Any]) -> Void) {
        self.options = options
        self.log = log
        self.event = event
    }

    /// Returns at once; the cast reports through `log` and `event`, and calls `onFinish` when everything is shut down.
    func start(onFinish: @escaping () -> Void = {}) {
        signal(SIGPIPE, SIG_IGN)  // a TV that hangs up must not take us with it
        state.lock()
        started = true
        state.unlock()
        Thread { [self] in
            var failure: String?
            do {
                try run()
            } catch {
                failure = (error as? CastError)?.message ?? error.localizedDescription
            }
            if let tv = options.tv, !options.serveOnly { _ = try? Viera.soap(tv, "Stop") }
            hub?.stop()
            children.forEach { $0.end() }
            server?.stop()
            if let failure {
                log(failure)
                event(["event": "end", "reason": "error", "message": failure])
            }
            state.lock()
            finished = true
            state.broadcast()
            state.unlock()
            onFinish()
        }.start()
    }

    /// Ask the cast to end. It stops the TV on its way out; `wait` returns when it has.
    func stop() {
        state.lock()
        cancelled = true
        state.broadcast()
        state.unlock()
    }

    func wait() {
        state.lock()
        while started && !finished { state.wait() }
        state.unlock()
    }

    /// Pass a signal on to the capture helper: SIGUSR1 opens its window chooser, or with `app` swaps the app between screens.
    func signalCapture(_ number: Int32) {
        state.lock()
        let helper = children.count > 1 ? children[1] : nil
        state.unlock()
        helper?.signal(number)
    }

    private var server: StreamServer?

    /// Wait for the cast to be over one way or the other; false if `seconds` passed first.
    private func waitForEnd(_ seconds: Double?) -> Bool {
        state.lock()
        defer { state.unlock() }
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        while !cancelled && !captureEnded {
            guard let deadline else { state.wait(); continue }
            if !state.wait(until: deadline) { break }
        }
        return cancelled || captureEnded
    }

    private func run() throws {
        if options.size == "auto" {
            options.size = options.tv.flatMap { Viera.knownSizes[Viera.model(of: $0)] } ?? Cast.defaultSize
        }
        let dimensions = options.size.split(separator: "x").compactMap { Int($0) }
        guard dimensions.count == 2 else { throw CastError(message: "The size has to be WIDTHxHEIGHT, not \(options.size).") }
        guard let rates = Cast.bitrates[options.codec] else { throw CastError(message: "The codec has to be hevc or h264.") }
        let bitrate = options.bitrate ?? rates[dimensions[0] * dimensions[1] > 1920 * 1080 ? "3840x2160" : "1920x1080"]!
        if options.codec == "h264" && options.fps > 30 && options.size != Cast.defaultSize && !options.serveOnly {
            log("4K H.264 cannot be encoded at 60 fps in real time; using 30 fps (HEVC can do 60).")
            options.fps = 30
        }
        log("Stream: \(options.size) at \(options.fps) fps, \(options.codec) \(bitrate)")
        event(["event": "stream", "size": options.size, "fps": options.fps, "codec": options.codec, "bitrate": bitrate])

        let hub = Hub(buffer: options.buffer)
        self.hub = hub
        let session = Session(hub: hub, bufferSeconds: options.buffer)
        let server = try StreamServer(port: options.port, hub: hub, session: session, stats: options.stats, log: log)
        self.server = server
        let url = "http://\(Viera.localAddress(toward: options.tv ?? "192.0.2.1")):\(options.port)/screen.ts"

        try startPipeline(bitrate: bitrate)
        server.start()
        reportStats()
        log("Serving \(url)")
        if options.app == nil && !options.display && !options.virtual {
            log("Choose what to share in the picker...")
            event(["event": "phase", "phase": "picking"])
        }
        var announced = options.serveOnly
        while hub.produced == 0 || hub.bufferedSeconds < (options.serveOnly ? 0 : options.buffer) {
            if waitForEnd(0.2) { break }
            if hub.produced > 0 && !announced {
                announced = true
                if options.buffer > 0 {
                    log("Buffering \(String(format: "%g", options.buffer)) s before starting the TV...")
                    event(["event": "phase", "phase": "buffering"])
                }
            }
        }
        if !waitForEnd(0), let tv = options.tv, !options.serveOnly {
            session.reset()
            try Viera.play(tv, url: url)
            log("Casting.")
            event(["event": "phase", "phase": "casting"])
        }
        _ = waitForEnd(nil)
        state.lock()
        let (cancelled, stoppedByUser) = (self.cancelled, self.stoppedByUser)
        state.unlock()
        if cancelled { return }
        guard stoppedByUser else { throw CastError(message: "The capture stopped unexpectedly.") }
        log("Sharing stopped.")
        event(["event": "end", "reason": "stopped"])
    }

    /// Start the capture helper and ffmpeg, joined by pipes, and the threads that read what they say.
    private func startPipeline(bitrate: String) throws {
        let folders = [Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(), Bundle.main.resourceURL]
        // A downloaded app carries its own ffmpeg; one built from source uses Homebrew's.
        // Apps launched from Finder do not get the shell's PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        let places = folders.compactMap({ $0?.path }) + environment["PATH"]!.split(separator: ":").map(String.init)
        guard let ffmpeg = places.map({ "\($0)/ffmpeg" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CastError(message: "ffmpeg was not found. Install it with: brew install ffmpeg")
        }
        guard let helper = folders.compactMap({ $0?.appendingPathComponent("capture").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CastError(message: "The capture helper is missing; build the app again with ./build.sh.")
        }

        func pipe() -> (read: Int32, write: Int32) {
            var ends: [Int32] = [0, 0]
            Darwin.pipe(&ends)
            return (ends[0], ends[1])
        }
        let video = pipe(), audio = pipe(), stream = pipe(), events = pipe(), notes = pipe()
        defer { [video.read, video.write, audio.read, audio.write, stream.write, events.write, notes.write].forEach { close($0) } }

        var capture = ["--video-fd", String(video.write), "--audio-fd", String(audio.write),
                       "--size", options.size, "--fps", String(options.fps), "--events"]
        if options.fill { capture.append("--fill") }
        if !options.audio { capture.append("--no-audio") }  // the TV wants an audio track, so the helper still sends silence
        if options.virtual { capture += ["--virtual", Cast.displayName] } else if options.display { capture.append("--display") }
        if let app = options.app { capture += ["--app", app] }

        var encode = ["-hide_banner", "-loglevel", "error", "-nostdin",
                      // Raw frames are megabytes each, so keep the input queue short.
                      "-thread_queue_size", "8",
                      "-f", "rawvideo", "-pixel_format", "nv12", "-video_size", options.size, "-framerate", String(options.fps),
                      "-i", "pipe:\(video.read)",
                      "-thread_queue_size", "1024", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", "pipe:\(audio.read)",
                      // Audio arrives at source level, which the TV plays quietly: boost it, with a limiter against clipping.
                      "-af", "volume=\(String(format: "%g", options.gain))dB,alimiter=limit=0.89:attack=5:release=50:level=0"]
        encode += options.codec == "hevc" ? ["-c:v", "hevc_videotoolbox", "-profile:v", "main"]
                                          : ["-c:v", "h264_videotoolbox", "-profile:v", "high"]
        encode += ["-realtime", "1", "-b:v", bitrate, "-g", String(options.fps),
                   "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
                   "-c:a", "aac", "-b:a", "192k",
                   "-f", "mpegts", "-flush_packets", "1", "pipe:1"]

        let encoder = try Child(ffmpeg, encode, inherit: [video.read, audio.read], stdout: stream.write, stderr: notes.write,
                                environment: environment)
        state.lock()
        children = [encoder]
        state.unlock()
        let grabber = try Child(helper, capture, inherit: [video.write, audio.write], stdout: events.write, stderr: notes.write,
                                environment: environment)
        state.lock()
        children.append(grabber)
        state.unlock()

        // What the helper and ffmpeg say for a person to read.
        follow(notes.read) { [log] line in
            if !line.hasPrefix("objc[") { log(line) }
        }
        // What the helper reports for the front end.
        follow(events.read) { [event] line in
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { event(object) }
        }
        // The stream itself.
        Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: Hub.chunk)
            reading: while true {
                var filled = 0
                while filled < Hub.chunk {
                    let count = buffer.withUnsafeMutableBytes { read(stream.read, $0.baseAddress! + filled, Hub.chunk - filled) }
                    if count > 0 { filled += count } else if count == 0 || errno != EINTR { break reading }
                }
                hub.append(Data(buffer))  // only whole chunks: a partial one would break packet alignment
            }
            close(stream.read)
            // The helper says why it ended, unless the encoder died first.
            var code: Int32?
            for _ in 0..<40 where code == nil {
                code = grabber.exitCode()
                if code == nil { usleep(50_000) }
            }
            state.lock()
            stoppedByUser = code == Cast.userStopped
            captureEnded = true
            state.broadcast()
            state.unlock()
        }.start()
    }

    private func follow(_ descriptor: Int32, _ handle: @escaping (String) -> Void) {
        Thread {
            let reader = LineReader()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 { reader.lines(adding: Data(buffer[0..<count])).forEach(handle) } else if count == 0 || errno != EINTR { break }
            }
            close(descriptor)
        }.start()
    }

    /// Every 2 s, tell the front end how fast the TV is taking the stream.
    private func reportStats() {
        Thread { [self] in
            var last = 0
            while !waitForEnd(2) {
                let (sent, position) = hub.progress
                if position > 0 {
                    event(["event": "stats", "mbit": (Double(sent - last) * 8 / 2e6 * 10).rounded() / 10,
                           "behind": (hub.delay(at: position) * 10).rounded() / 10])
                }
                last = sent
            }
        }.start()
    }
}
