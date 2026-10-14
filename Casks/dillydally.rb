cask "dillydally" do
  version "0.1.0"
  sha256 "b18697e0dd1d52fd705c59ed51d406fc579a5af9d9e89de8cc95043dad46452c"

  url "https://github.com/martynaskadisa/dillydally/releases/download/v#{version}/DillyDally.dmg"
  name "DillyDally"
  desc "Cast the screen to a TV with no AirPlay, over DLNA"
  homepage "https://github.com/martynaskadisa/dillydally"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "DillyDally.app"
  binary "#{appdir}/DillyDally.app/Contents/Resources/dillydally"

  # The app is signed ad hoc, and Gatekeeper refuses to open one that still has the download's quarantine mark.
  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/DillyDally.app"]
  end

  uninstall quit: "com.martynaskadisa.cast"

  zap trash: [
    "~/Library/Logs/DillyDally.log",
    "~/Library/Preferences/com.martynaskadisa.cast.plist",
  ]
end
