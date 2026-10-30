# Homebrew formula for ansirender, AnsiView's command line renderer.
# Lives in the tap btray77/homebrew-ansiview as Formula/ansirender.rb (see "Homebrew" in README.md).
class Ansirender < Formula
  desc "Render and convert classic BBS ANSI art (PNG, GIF, WebP, MP4, HTML, text)"
  homepage "https://github.com/btray77/AnsiView"
  url "https://github.com/btray77/AnsiView/archive/refs/tags/v2.0.0.tar.gz"
  # Owner step: replace with `shasum -a 256` of the tag's tarball once v2.0.0 is tagged.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  # The code is MIT; the bundled Px437 fonts in AnsiCore_AnsiCore.bundle are CC BY-SA 4.0.
  license all_of: ["MIT", "CC-BY-SA-4.0"]
  head "https://github.com/btray77/AnsiView.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on "xcodegen" => :build
  depends_on :macos

  def install
    system "xcodegen", "generate"
    # Ad hoc signed, everything (derived data, package checkouts) inside the build directory.
    # Homebrew already sandboxes the build, and Swift Package Manager cannot nest its own
    # manifest sandbox inside it, so that one is turned off.
    xcodebuild "-project", "AnsiView.xcodeproj", "-scheme", "ansirender",
               "-configuration", "Release", "-derivedDataPath", "build",
               "-clonedSourcePackagesDirPath", "build/SourcePackages",
               "-IDEPackageSupportDisableManifestSandbox=YES",
               "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "CODE_SIGN_STYLE=Manual",
               "OTHER_CODE_SIGN_FLAGS=", "ARCHS=#{Hardware::CPU.arch}", "ONLY_ACTIVE_ARCH=YES",
               "build"
    products = "build/Build/Products/Release"
    # The renderer loads its bundled fonts from the resource bundle next to the binary.
    libexec.install "#{products}/ansirender", "#{products}/AnsiCore_AnsiCore.bundle"
    bin.write_exec_script libexec/"ansirender"
  end

  test do
    assert_match "ansirender ", shell_output("#{bin}/ansirender --version")
    (testpath/"test.ans").write "\e[1;33mHello\e[0m \e[44mBrew\e[0m\r\n"
    output = shell_output("#{bin}/ansirender #{testpath}/test.ans #{testpath}/test.png")
    assert_match "80x1 cells", output
    assert_path_exists testpath/"test.png"
    assert_match "same", shell_output("#{bin}/ansirender --roundtrip #{testpath}/test.ans")
  end
end
