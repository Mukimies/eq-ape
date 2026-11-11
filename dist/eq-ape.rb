# DRAFT Homebrew cask. For a personal tap this goes in
#   Mukimies/homebrew-tap/Casks/eq-ape.rb      (users: brew install --cask Mukimies/tap/eq-ape)
# For homebrew/homebrew-cask it only becomes acceptable once the app is notarized and the repo
# meets the notability thresholds (the Commons Clause licence is not mentioned in Homebrew's published
# rules, but that is unconfirmed; ask maintainers before submitting) (see docs/DISTRIBUTION.md).
# Replace version and sha256 (the sha256 is the content of the .dmg.sha256 file).
cask "eq-ape" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_EQ-Ape-0.1.0.dmg"

  url "https://github.com/Mukimies/eq-ape/releases/download/v#{version}/EQ-Ape-#{version}.dmg"
  name "EQ Ape"
  desc "System-wide equalizer that reads Equalizer APO config files"
  homepage "https://github.com/Mukimies/eq-ape"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Process taps need macOS 14.2; the cask DSL only knows major names, so Sonoma (14) is the floor
  # and the app itself must refuse to run on 14.0/14.1.
  depends_on arch: :arm64   # Apple Silicon only
  depends_on macos: ">= :sonoma"

  app "EQ Ape.app"

  # Uncomment ONLY if Sparkle (or another in-app updater) is built in; otherwise brew upgrade does updates.
  # auto_updates true

  zap trash: [
    "~/Library/Preferences/org.eqape.EQApe.plist",
    "~/Library/Application Support/EQ Ape",
    "~/Library/Caches/org.eqape.EQApe",
  ]

  # Personal tap + un-notarized build only. Delete once the DMG is notarized.
  # caveats <<~EOS
  #   EQ Ape is not notarized. After the first launch is refused, open
  #   System Settings > Privacy & Security and click "Open Anyway".
  #   The audio-capture permission must be granted again after each update.
  # EOS
end
