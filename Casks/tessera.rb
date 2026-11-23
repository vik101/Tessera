# Homebrew cask for Tessera. Install with:
#   brew tap vik101/tessera https://github.com/vik101/Tessera
#   brew install --cask vik101/tessera/tessera
# Tessera updates itself, so the cask always fetches the newest release.
cask "tessera" do
  version :latest
  sha256 :no_check

  url "https://github.com/vik101/Tessera/releases/latest/download/Tessera.zip"
  name "Tessera"
  desc "Rectangle-style window snapping plus adaptive auto-tiling"
  homepage "https://github.com/vik101/Tessera"

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "Tessera.app"

  # Tessera isn't notarized by Apple yet, so macOS would refuse to open a download.
  # Remove this once releases are notarized.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Tessera.app"]
  end

  uninstall quit: "com.vikram.Tessera"

  zap trash: [
    "~/Library/Application Support/com.vikram.Tessera",
    "~/Library/Preferences/com.vikram.Tessera.plist",
  ]
end
