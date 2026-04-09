class Simclaw < Formula
  desc "iOS Simulator interaction CLI for developers and AI agents"
  homepage "https://github.com/mindvalley/homebrew-sim"
  # Update url and sha256 after pushing the first GitHub release tag.
  # To generate sha256: curl -sL <tarball_url> | sha256sum
  url "https://github.com/mindvalley/homebrew-sim/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_UPDATE_AFTER_FIRST_RELEASE"
  license "MIT"
  version "1.0.0"

  # For local testing before GitHub release exists:
  #   brew tap mindvalley/sim /Users/justin/homebrew-sim
  #   brew install --HEAD mindvalley/sim/simclaw
  head "file:///Users/justin/homebrew-sim", using: :git

  # Runtime dependencies
  depends_on "jq"
  # swift and xcrun come from Xcode — not installable via Homebrew, documented in README
  depends_on :xcode => "15.0"

  def install
    bin.install "bin/sim"
  end

  def caveats
    <<~EOS
      sim requires WebDriverAgent (WDA) for tap/swipe commands.
      One-time setup (run once per machine):

        git clone https://github.com/appium/WebDriverAgent /tmp/WebDriverAgent

      Then start a session before using tap/swipe:

        sim --device <UDID> setup <bundle_id_or_app_path>

      Full docs: https://github.com/mindvalley/homebrew-sim
    EOS
  end

  test do
    # Verify the script is executable and responds to --help
    assert_match "Usage:", shell_output("#{bin}/sim --help 2>&1", 0)
  end
end
