class Simclaw < Formula
  desc "iOS Simulator interaction CLI for developers and AI agents"
  homepage "https://github.com/mindvalley/homebrew-simClaw"
  # Update url and sha256 after pushing the first GitHub release tag.
  # To generate sha256: curl -sL <tarball_url> | sha256sum
  url "https://github.com/mindvalley/homebrew-simClaw/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_UPDATE_AFTER_FIRST_RELEASE"
  license "MIT"
  version "1.0.0"

  # For local testing before GitHub release exists:
  #   brew tap mindvalley/sim /Users/justin/homebrew-simClaw
  #   brew install --HEAD mindvalley/sim/simclaw
  head "file:///Users/justin/homebrew-simClaw", using: :git

  # Runtime dependencies
  depends_on "jq"
  # swift and xcrun come from Xcode — not installable via Homebrew, documented in README
  depends_on :xcode => "15.0"

  def install
    bin.install "bin/sim"
    pkgshare.install "skills"
  end

  def post_install
    # Install bundled Claude Code skills into ~/.claude/skills/
    # This makes the skills available to Claude Code globally across all projects.
    skills_src = pkgshare/"skills"
    skills_dst = Pathname.new(ENV["HOME"]) / ".claude/skills"
    skills_dst.mkpath

    skills_src.each_child do |skill_dir|
      next unless skill_dir.directory?
      dst = skills_dst / skill_dir.basename
      dst.mkpath
      skill_dir.each_child do |f|
        FileUtils.cp f, dst / f.basename
      end
      opoo "Installed Claude skill: #{skill_dir.basename} → #{dst}"
    end
  end

  def caveats
    <<~EOS
      sim requires WebDriverAgent (WDA) for tap/swipe commands.
      One-time setup (run once per machine):

        git clone https://github.com/appium/WebDriverAgent /tmp/WebDriverAgent

      Then start a session before using tap/swipe:

        sim --device <UDID> setup <bundle_id_or_app_path>

      Claude Code skills have been installed to:
        ~/.claude/skills/

      They are available immediately in any Claude Code session.

      Full docs: https://github.com/mindvalley/homebrew-simClaw
    EOS
  end

  test do
    # Verify the script is executable and responds to --help
    assert_match "Usage:", shell_output("#{bin}/sim --help 2>&1", 0)
  end
end
