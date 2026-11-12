# Homebrew cask template for EQ Ape, for a PERSONAL TAP (not homebrew/homebrew-cask).
#
# Tap repository: github.com/Mukimies/homebrew-tap   (the repo MUST be named homebrew-<something>;
#   "homebrew-tap" gives the short tap name Mukimies/tap)
# Location in the tap: Casks/eq-ape.rb
# Install:  brew install --cask Mukimies/tap/eq-ape
#       or: brew tap Mukimies/tap && brew install --cask eq-ape
#
# Per release: `dist/update-cask.sh <version> dist/out/EQ-Ape-<version>.dmg.sha256 > Casks/eq-ape.rb`
# prints this file with `version` and `sha256` replaced (the release workflow also prints it in the job
# summary). Never edit a published release's DMG; a new build is a new version.
#
# The first release (0.1.0-beta.1) is ad-hoc signed and NOT notarized. The official homebrew-cask repository
# does not accept such apps (see docs/DISTRIBUTION.md section 8), so this cask is for the personal tap only.
# `brew audit --cask` and `brew install` have never been run against this file.
cask "eq-ape" do
  version "0.1.0-beta.1"
  sha256 "REPLACE_WITH_SHA256_OF_EQ-Ape-0.1.0-beta.1.dmg"

  url "https://github.com/Mukimies/eq-ape/releases/download/v#{version}/EQ-Ape-#{version}.dmg"
  name "EQ Ape"
  desc "System-wide equalizer that reads Equalizer APO-style config files"
  homepage "https://github.com/Mukimies/eq-ape"

  # :github_latest ignores pre-releases, so use the releases list while only betas exist.
  livecheck do
    url :url
    strategy :github_releases
  end

  # The cask DSL only knows major macOS names, so Sonoma (14) is the floor; EQ Ape itself needs 14.2
  # (LSMinimumSystemVersion) and Homebrew cannot express that.
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "EQ Ape.app"

  zap trash: [
    "~/Library/Application Support/EQ Ape",
    "~/Library/Caches/org.eqape.EQApe",
    "~/Library/Preferences/org.eqape.EQApe.plist",
  ]

  # Delete this block once the DMG is notarized.
  caveats <<~EOS
    EQ Ape is a pre-release and is not notarized by Apple. macOS will refuse to open it at first:
    double-click it, close the alert, then open System Settings > Privacy & Security and click
    "Open Anyway" next to the EQ Ape message. The audio-capture permission will probably have to be
    granted again after each update. Answer the permission prompt promptly: an unanswered prompt can
    stall new audio for every app until it is answered.
  EOS
end
