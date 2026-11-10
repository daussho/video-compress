import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).parent


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vcompress-install-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout with spaces"
        self.checkout.mkdir()
        for name in ("install.sh", "compress.sh"):
            shutil.copyfile(ROOT / name, self.checkout / name)
            (self.checkout / name).chmod(0o755)
        shutil.copytree(ROOT / "completions", self.checkout / "completions")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("dirname", "readlink", "mkdir", "ln"):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.env = dict(os.environ, HOME=str(self.root / "home"), PATH=str(self.bin),
                        PLATFORM="Darwin", MOCK_BIN=str(self.bin), LOG=str(self.root / "log"))
        self.tool("uname", 'echo "$PLATFORM"')
        self.tool("id", 'echo "${MOCK_UID:-1000}"')
        for tool in ("git", "ffmpeg", "ffprobe"):
            self.tool(tool, "exit 0")
        self.tool("sudo", 'echo "sudo $*" >> "$LOG"; exec "$@"')
        self.tool("apt-get", '''echo "apt-get $*" >> "$LOG"
if [[ "$1" == install ]]; then
  /bin/cp "$MOCK_BIN/git" "$MOCK_BIN/ffmpeg"
  /bin/cp "$MOCK_BIN/git" "$MOCK_BIN/ffprobe"
fi''')
        self.tool("brew", '''echo "brew $*" >> "$LOG"
/bin/cp "$MOCK_BIN/git" "$MOCK_BIN/ffmpeg"
/bin/cp "$MOCK_BIN/git" "$MOCK_BIN/ffprobe"''')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def install(self, shell="/bin/bash"):
        return subprocess.run([shell, str(self.checkout / "install.sh")],
                              env=self.env, capture_output=True, text=True)

    def piped_install(self, shell="/bin/bash"):
        return subprocess.run([shell], input=(self.checkout / "install.sh").read_text(),
                              env=self.env, capture_output=True, text=True)

    def mock_clone(self):
        self.env["MOCK_CHECKOUT"] = str(self.checkout)
        git = self.bin / "git"
        git.write_text(f'''#!{sys.executable}
import os, pathlib, shutil, sys
args = sys.argv[1:]
with open(os.environ["LOG"], "a") as log:
    log.write("git " + " ".join(args) + "\\n")
if args[0] == "clone":
    if os.environ.get("CLONE_FAIL"):
        sys.exit(1)
    target = pathlib.Path(args[2])
    target.mkdir()
    (target / ".git").mkdir()
    (target / ".git/origin").write_text(args[1])
    shutil.copy2(pathlib.Path(os.environ["MOCK_CHECKOUT"]) / "compress.sh", target / "compress.sh")
    shutil.copytree(pathlib.Path(os.environ["MOCK_CHECKOUT"]) / "completions", target / "completions")
elif args[0] == "-C":
    print((pathlib.Path(args[1]) / ".git/origin").read_text())
else:
    sys.exit(1)
''')
        git.chmod(0o755)

    def test_piped_install_and_rerun(self):
        self.mock_clone()
        for platform in ("Darwin", "Linux"):
            self.env["PLATFORM"] = platform
            result = self.piped_install()
            self.assertEqual(result.returncode, 0, result.stderr)
            home = Path(self.env["HOME"])
            self.assertEqual((home / ".local/bin/vcompress").resolve(),
                             (home / ".local/share/video-compress/compress.sh").resolve())
        self.assertEqual((self.root / "log").read_text().count("git clone "), 1)

    def test_piped_install_with_path_bash(self):
        self.mock_clone()
        result = self.piped_install(shutil.which("bash"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((Path(self.env["HOME"]) / ".local/bin/vcompress").is_symlink())

    def test_local_install_with_path_bash(self):
        result = self.install(shutil.which("bash"))
        self.assertEqual(result.returncode, 0, result.stderr)
        link = Path(self.env["HOME"]) / ".local/bin/vcompress"
        self.assertEqual(link.resolve(), (self.checkout / "compress.sh").resolve())

    def test_piped_install_rejects_unrelated_checkout(self):
        self.mock_clone()
        target = Path(self.env["HOME"]) / ".local/share/video-compress"
        (target / ".git").mkdir(parents=True)
        (target / ".git/origin").write_text("https://example.invalid/other.git")
        result = self.piped_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different repository", result.stderr)
        self.assertFalse((Path(self.env["HOME"]) / ".local/bin/vcompress").exists())

    def test_piped_clone_failure(self):
        self.mock_clone()
        self.env["CLONE_FAIL"] = "1"
        result = self.piped_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((Path(self.env["HOME"]) / ".local/bin/vcompress").exists())

    def test_piped_install_can_install_git(self):
        self.mock_clone()
        (self.bin / "git").rename(self.root / "git-template")
        self.env["GIT_TEMPLATE"] = str(self.root / "git-template")
        self.tool("brew", '''echo "brew $*" >> "$LOG"
if IFS= read -r unexpected; then exit 1; fi
/bin/cp "$GIT_TEMPLATE" "$MOCK_BIN/git"''')
        result = self.piped_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("brew install git", (self.root / "log").read_text())

    def test_install_and_rerun(self):
        for platform in ("Darwin", "Linux"):
            self.env["PLATFORM"] = platform
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
            link = Path(self.env["HOME"]) / ".local/bin/vcompress"
            self.assertEqual(link.resolve(), (self.checkout / "compress.sh").resolve())
            self.assertIn('export PATH="$HOME/.local/bin:$PATH"', result.stdout)
        self.assertFalse((self.root / "log").exists())

    def test_completion_activation_instructions(self):
        for shell, completion in (("/bin/zsh", "vcompress.zsh"), ("/bin/bash", "vcompress.bash")):
            with self.subTest(shell=shell):
                self.env["SHELL"] = shell
                result = self.install()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(completion, result.stdout)
                self.assertIn("source ", result.stdout)
        self.assertFalse((Path(self.env["HOME"]) / ".zshrc").exists())
        self.assertFalse((Path(self.env["HOME"]) / ".bashrc").exists())

    def test_macos_installs_missing_ffmpeg(self):
        (self.bin / "ffprobe").unlink()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "log").read_text(), "brew install ffmpeg\n")

    def test_ubuntu_installs_missing_ffmpeg(self):
        self.env["PLATFORM"] = "Linux"
        (self.bin / "ffmpeg").unlink()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "log").read_text(),
                         "sudo apt-get update\napt-get update\n"
                         "sudo apt-get install -y ffmpeg\napt-get install -y ffmpeg\n")

    def test_root_does_not_use_sudo(self):
        self.env.update(PLATFORM="Linux", MOCK_UID="0")
        (self.bin / "ffmpeg").unlink()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("sudo", (self.root / "log").read_text())

    def test_existing_command_is_not_overwritten(self):
        link = Path(self.env["HOME"]) / ".local/bin/vcompress"
        link.parent.mkdir(parents=True)
        link.write_text("keep me")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(link.read_text(), "keep me")

    def test_missing_homebrew(self):
        (self.bin / "ffmpeg").unlink()
        (self.bin / "brew").unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Install Homebrew", result.stderr)

    def test_unsupported_platform(self):
        self.env["PLATFORM"] = "Windows_NT"
        self.assertNotEqual(self.install().returncode, 0)

    def test_package_install_failure(self):
        (self.bin / "ffmpeg").unlink()
        self.tool("brew", "exit 1")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((Path(self.env["HOME"]) / ".local/bin/vcompress").exists())

    def test_linux_file_size_and_small_file_skip(self):
        self.env["PLATFORM"] = "Linux"
        for tool in ("date", "awk"):
            (self.bin / tool).symlink_to(shutil.which(tool))
        stat = self.bin / "stat"
        stat.write_text(f'''#!{sys.executable}
import pathlib, sys
assert sys.argv[1:3] == ["-c%s", "--"], sys.argv
print(pathlib.Path(sys.argv[3]).stat().st_size)
''')
        stat.chmod(0o755)
        self.tool("ffmpeg", 'echo "unexpected ffmpeg invocation" >&2; exit 1')
        source = self.root / "tiny.mp4"
        source.write_bytes(b"untouched")
        result = subprocess.run(["/bin/bash", str(self.checkout / "compress.sh"), str(source)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Summary: 0 compressed, 1 skipped, 0 failed", result.stdout)
        self.assertNotIn("unexpected ffmpeg", result.stderr)
        self.assertEqual(source.read_bytes(), b"untouched")

    def prepare_compression_output_test(self):
        self.env["PLATFORM"] = "Darwin" if sys.platform == "darwin" else "Linux"
        for name in ("stat", "date", "awk", "mv", "rm", "grep"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.tool("ffprobe", '''case "$*" in
  *stream=codec_type*) ;;
  *format=duration*) echo 100 ;;
  *stream=codec_name*) echo h264 ;;
  *) echo '1920,1080,3000000' ;;
esac''')
        self.tool("ffmpeg", '''if [[ "$1" == -encoders ]]; then echo h264_videotoolbox; exit 0; fi
if [[ " $* " == *" -f lavfi "* ]]; then exit 0; fi
echo "$*" >> "$LOG"
case " $* " in
  *" -loglevel error "*) echo 'compact progress' >&2 ;;
  *) echo 'ffmpeg version test' >&2; echo 'Stream mapping:' >&2 ;;
esac
if [[ "$FAIL_ENCODE" == 1 ]]; then echo 'Encoder failed' >&2; exit 1; fi
for last; do :; done
printf video > "$last"''')

    def run_compression_output_test(self, name, *flags):
        source = self.root / (name + ".mp4")
        with source.open("wb") as fixture:
            fixture.truncate(70 * 1024 * 1024)
        result = subprocess.run(["/bin/bash", str(self.checkout / "compress.sh"), str(source), *flags],
                                env=self.env, capture_output=True, text=True)
        return source, result

    def test_concise_output_by_default(self):
        self.prepare_compression_output_test()
        source, result = self.run_compression_output_test("quiet")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(source.exists())
        self.assertIn("Compressing:", result.stdout)
        self.assertIn("compact progress", result.stderr)
        self.assertIn("Summary: 1 compressed", result.stdout)
        self.assertNotIn("ffmpeg version", result.stderr)
        self.assertNotIn("Stream mapping", result.stderr)
        self.assertNotIn("Estimated savings", result.stdout)
        self.assertNotIn("Deleted original", result.stdout)
        self.assertIn("-hide_banner -loglevel error -stats", (self.root / "log").read_text())

    def test_verbose_output_restores_details(self):
        self.prepare_compression_output_test()
        source, result = self.run_compression_output_test("verbose", "--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(source.exists())
        self.assertIn("ffmpeg version", result.stderr)
        self.assertIn("Stream mapping", result.stderr)
        self.assertIn("Deleted original", result.stdout)
        self.assertIn("Elapsed:", result.stdout)
        self.assertNotIn("-loglevel error", (self.root / "log").read_text())

    def test_errors_remain_visible_in_both_modes(self):
        self.prepare_compression_output_test()
        self.env["FAIL_ENCODE"] = "1"
        for flags in ((), ("--verbose",)):
            with self.subTest(flags=flags):
                source, result = self.run_compression_output_test("failure", *flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(source.exists())
                self.assertIn("Encoder failed", result.stderr)
                self.assertIn("compression failed", result.stderr)
                self.assertIn("Summary: 0 compressed, 0 skipped, 1 failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
