class Simclaw < Formula
  desc "iOS Simulator interaction CLI for developers and AI agents"
  homepage "https://github.com/justinchampappilly-mindvalley/homebrew-simClaw"
  url "https://github.com/justinchampappilly-mindvalley/homebrew-simClaw/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "60bed1b13cf582f2c00be011f130e92549e5b6702e6a27ba7b54bf344a5dcd25"
  license "MIT"
  version "1.0.0"

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

      Full docs: https://github.com/justinchampappilly-mindvalley/homebrew-simClaw
    EOS
  end

  test do
    # Verify the script is executable and responds to --help
    assert_match "Usage:", shell_output("#{bin}/sim --help 2>&1", 0)
  end
end
