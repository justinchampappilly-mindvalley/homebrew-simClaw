class Simclaw < Formula
  desc "iOS Simulator interaction CLI for developers and AI agents"
  homepage "https://github.com/justinchampappilly-mindvalley/homebrew-simClaw"
  url "https://github.com/justinchampappilly-mindvalley/homebrew-simClaw/archive/refs/tags/v1.0.4.tar.gz"
  sha256 "6e2999280e41122a1da75ebf1db164b22ca9fd58a0e5f4ad4402502f147a9380"
  license "MIT"
  version "1.0.4"

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
