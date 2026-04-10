cask "puremac" do
  version "1.0.1"
  sha256 "42430e0b9dcbf947ebb580c6adc7c563df3d67404754ba6f1fa3fb761585aaca"

  url "https://github.com/momenbasel/PureMac/releases/download/v#{version}/PureMac-v#{version}.zip"
  name "PureMac"
  desc "Free, open-source macOS cleaning utility"
  homepage "https://github.com/momenbasel/PureMac"

  app "PureMac.app"

  zap trash: [
    "~/Library/Preferences/com.puremac.app.plist",
    "~/Library/Caches/com.puremac.app",
    "~/Library/LaunchAgents/com.puremac.scheduler.plist",
  ]
end
