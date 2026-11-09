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

    def install(self):
        return subprocess.run(["/bin/bash", str(self.checkout / "install.sh")],
                              env=self.env, capture_output=True, text=True)

    def test_install_and_rerun(self):
        for platform in ("Darwin", "Linux"):
            self.env["PLATFORM"] = platform
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
            link = Path(self.env["HOME"]) / ".local/bin/vcompress"
            self.assertEqual(link.resolve(), (self.checkout / "compress.sh").resolve())
            self.assertIn('export PATH="$HOME/.local/bin:$PATH"', result.stdout)
        self.assertFalse((self.root / "log").exists())

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


if __name__ == "__main__":
    unittest.main()
