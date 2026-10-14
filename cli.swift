// dillydally, the cast without the menu-bar app: the same engine (engine.swift)
// driven from a terminal. build.sh puts it in the app bundle, next to the
// capture helper it needs.

import Foundation

let usage = """
    usage: dillydally [options]

    Cast this Mac to a Panasonic Viera TV. Without options it finds the TV and
    asks what to share; Ctrl-C stops the cast.

      --list             list the TVs found on the network
      --stop             stop playback on the TV
      --tv ADDRESS       the TV's address, instead of looking for it
      --app NAME         share this app's largest window instead of asking
      --display          share the whole screen instead of asking
      --virtual          make the TV a display of its own, as the app does;
                         Screen Mirroring in the menu bar then says what it shows
      --size WxH         stream size (default: the TV's own, or 1920x1080)
      --fps N            frames per second (default 60)
      --codec CODEC      hevc (default) or h264, for older TVs
      --bitrate RATE     e.g. 20M (default: chosen from the size and codec)
      --buffer SECONDS   how far behind live the TV plays (default 2)
      --fill             crop to the TV's shape instead of adding black bars
      --gain DB          audio boost (default 12)
      --no-audio         send silence
      --port N           port of the stream's HTTP server (default 8090)
      --stats            log send rate, delay and stalls every 5 s
      --serve-only       encode and serve without telling the TV to play
      --events           report progress as JSON lines on stdout
    """

func quit(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@main
enum CommandLineTool {
    static func main() {
        var options = CastOptions()
        var list = false, stop = false, events = false
        var arguments = CommandLine.arguments.dropFirst()

        func value(_ option: String) -> String {
            guard let value = arguments.popFirst() else { quit("\(option) needs a value.") }
            return value
        }

        func number<T: LosslessStringConvertible>(_ option: String) -> T {
            let text = value(option)
            guard let number = T(text) else { quit("\(option) needs a number, not \(text).") }
            return number
        }

        while let argument = arguments.popFirst() {
            switch argument {
            case "--list": list = true
            case "--stop": stop = true
            case "--tv": options.tv = value(argument)
            case "--app": options.app = value(argument)
            case "--display": options.display = true
            case "--virtual": options.virtual = true
            case "--size": options.size = value(argument)
            case "--fps": options.fps = number(argument)
            case "--codec": options.codec = value(argument)
            case "--bitrate": options.bitrate = value(argument)
            case "--buffer": options.buffer = number(argument)
            case "--fill": options.fill = true
            case "--gain": options.gain = number(argument)
            case "--no-audio": options.audio = false
            case "--port": options.port = number(argument)
            case "--stats": options.stats = true
            case "--serve-only": options.serveOnly = true
            case "--events": events = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default: quit("Unknown option \(argument).\n\n\(usage)")
            }
        }

        setvbuf(stdout, nil, _IOLBF, 0)  // events are read line by line, also through a pipe

        if list {
            for tv in Viera.discover() { print([tv.ip, tv.name, tv.model, tv.size].joined(separator: "\t")) }
            exit(0)
        }

        if options.tv == nil && !options.serveOnly {
            guard let tv = Viera.discover().first else { quit("No TV found on the network. Is it on? Otherwise pass --tv ADDRESS.") }
            FileHandle.standardError.write(Data("Found \(tv.name) at \(tv.ip)\n".utf8))
            options.tv = tv.ip
        }

        if stop {
            do {
                try Viera.soap(options.tv!, "Stop")
            } catch {
                quit((error as? CastError)?.message ?? error.localizedDescription)
            }
            exit(0)
        }

        var failed = false
        let cast = Cast(options, log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) { event in
            if ["end", "error"].contains(event["event"] as? String), event["reason"] as? String != "stopped" { failed = true }
            guard events, let line = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) else { return }
            print(String(decoding: line, as: UTF8.self))
        }

        // Ctrl-C and kill end the cast cleanly, so the TV is told to stop; SIGUSR1 goes on to the capture helper.
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGUSR1] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { number == SIGUSR1 ? cast.signalCapture(number) : cast.stop() }
            source.resume()
            sources.append(source)
        }

        cast.start()
        cast.wait()
        exit(failed ? 1 : 0)
    }
}
