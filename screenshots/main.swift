// Draws the panel images in docs/ from the panel's own code, with a made-up TV.
// Run ./screenshots/render.sh rather than this.

import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tv = TV(ip: "192.168.1.50", name: "50MX900_Series", model: "TH-50MX900", size: "3840x2160")
func idle() -> CastModel { let m = CastModel(); m.searching = false; m.tvs = [tv]; return m }
func casting(_ mode: String, chosen: Bool = false) -> CastModel {
    let m = idle(); m.target = tv; m.phase = .casting; m.format = "4K · 60 · HEVC"; m.mbit = 28.4; m.delay = 2
    m.mode = mode; m.display = 1; m.windowChosen = chosen; return m
}
struct Card: View {
    let model: CastModel; var settings = false; var info = false; var dark = true
    var body: some View {
        Panel(model: model, showingSettings: settings, showingInfo: info)
            .background(RoundedRectangle(cornerRadius: 16).fill(dark ? Color(white: 0.1).opacity(0.92) : Color.white.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.12), radius: 20, y: 10)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}
func shoot<V: View>(_ name: String, dark: Bool = true, _ view: V) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    window.setContentSize(host.fittingSize)
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[1])/\(name).png"))
    window.orderOut(nil)
}
struct Backdrop: View {
    let dark: Bool
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                dark ? Color(red: 0.035, green: 0.04, blue: 0.065) : Color(red: 0.96, green: 0.965, blue: 0.98)
                // Soft pools of light, as if screens were glowing off to the sides.
                glow(Color(red: 0.16, green: 0.42, blue: 1.0), dark ? 0.60 : 0.40).frame(width: w * 0.9, height: h * 1.5).offset(x: -w * 0.34, y: -h * 0.3)
                glow(Color(red: 0.55, green: 0.30, blue: 1.0), dark ? 0.50 : 0.34).frame(width: w * 0.85, height: h * 1.4).offset(x: w * 0.36, y: h * 0.38)
                glow(Color(red: 0.10, green: 0.80, blue: 0.85), dark ? 0.26 : 0.26).frame(width: w * 0.6, height: h * 0.9).offset(x: w * 0.14, y: -h * 0.5)
                // A fine grid that fades out towards the edges.
                Canvas { context, size in
                    var path = Path()
                    var x: CGFloat = 0
                    while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 32 }
                    var y: CGFloat = 0
                    while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 32 }
                    context.stroke(path, with: .color(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)), lineWidth: 0.5)
                }
                .mask(RadialGradient(colors: [.white, .clear], center: .center, startRadius: 0, endRadius: max(w, h) * 0.55))
            }
        }
    }
}
func glow(_ color: Color, _ strength: Double) -> some View {
    Ellipse().fill(EllipticalGradient(stops: [.init(color: color.opacity(strength), location: 0),
                                              .init(color: color.opacity(strength * 0.45), location: 0.4),
                                              .init(color: color.opacity(0), location: 1)]))
}
func backdrop(_ dark: Bool) -> Backdrop { Backdrop(dark: dark) }

let icon: NSImage = {
    let image = NSWorkspace.shared.icon(forFile: CommandLine.arguments[2])
    image.size = NSSize(width: 512, height: 512)
    return image
}()

/// A stand-in for the macOS menu bar, with DillyDally's icon open.
struct MenuBar: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 15))
            Text("Finder").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            Image(nsImage: Glyph.menuBarImage(filled: true, dot: false))
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.16)))
                .padding(.horizontal, -9)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent").font(.system(size: 17))
            Image(systemName: "switch.2")
            Text("Wed Oct 14  11:39 AM")
        }
        .font(.system(size: 13.5, weight: .medium))
        .padding(.horizontal, 22)
        .frame(height: 32)
        .background(.primary.opacity(0.07))
    }
}

/// The menu bar with the panels hanging from it, beside the app's icon and name.
struct Poster<Content: View>: View {
    let dark: Bool, tagline: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            MenuBar()
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: icon).resizable().frame(width: 104, height: 104).padding(.leading, -8).padding(.bottom, 6)
                    Text("DillyDally").font(.system(size: 40, weight: .bold))
                    Text(tagline).font(.system(size: 18)).foregroundStyle(.secondary)
                        .frame(width: 250, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 72)
                HStack(alignment: .top, spacing: 20) { content }
            }
            .padding(.leading, 56).padding(.trailing, 20).padding(.top, 8).padding(.bottom, 56)
        }
        .background(Backdrop(dark: dark))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
DispatchQueue.main.async {
    let tagline = "Cast your Mac to a TV that has no AirPlay."
    shoot("panel", Poster(dark: true, tagline: tagline) {
        Card(model: idle()); Card(model: idle(), settings: true); Card(model: casting("extended"))
    })
    shoot("panel-light", dark: false, Poster(dark: false, tagline: tagline) {
        Card(model: idle(), dark: false); Card(model: idle(), settings: true, dark: false); Card(model: casting("extended"), dark: false)
    })
    shoot("modes", Poster(dark: true, tagline: "The whole screen, one window, or a display of its own.") {
        Card(model: casting("mirror")); Card(model: casting("window", chosen: true)); Card(model: casting("extended"))
    })
    exit(0)
}
app.run()
