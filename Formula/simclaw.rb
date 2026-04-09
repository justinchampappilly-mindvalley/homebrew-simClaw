class Simclaw < Formula
  desc "iOS Simulator interaction CLI for developers and AI agents"
  homepage "https://github.com/justinchampappilly-mindvalley/homebrew-simClaw"
  url "https://github.com/justinchampappilly-mindvalley/homebrew-simClaw/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "f8c46f011173b2bcf2bf0b0d0792e6f4fb746b2228666053d4948f75e3eb5fb5"
  license "MIT"
  version "1.0.1"

  # Runtime dependencies
  depends_on "jq"
  # swift and xcrun come from Xcode — not installable via Homebrew, documented in README
  depends_on :xcode => "15.0"

  def install
    bin.install "bin/sim"
    pkgshare.install "skills"
  end

  def caveats
    <<~EOS
      sim requires WebDriverAgent (WDA) for tap/swipe commands.
      One-time setup (run once per machine):

        git clone https://github.com/appium/WebDriverAgent /tmp/WebDriverAgent

      Then start a session before using tap/swipe:

        sim --device <UDID> setup <bundle_id_or_app_path>

      To install bundled Claude Code skills (qa-branch and others):

        sim install-skills

      This copies skills to ~/.claude/skills/ making them available in any
      Claude Code session immediately.

      Full docs: https://github.com/justinchampappilly-mindvalley/homebrew-simClaw
    EOS
  end

  test do
    # Verify the script is executable and responds to --help
    assert_match "Usage:", shell_output("#{bin}/sim --help 2>&1", 0)
  end
end
