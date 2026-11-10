import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent
GIT = shutil.which("git")


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vcompress-update-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.env = dict(os.environ, HOME=str(self.root), GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Test",
                        GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_NAME="Test",
                        GIT_COMMITTER_EMAIL="test@example.invalid")
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.checkout = self.root / "checkout with spaces"
        self.git("init", "--bare", "-b", "main", self.remote)
        self.git("init", "-b", "main", self.seed)
        shutil.copy2(ROOT / "compress.sh", self.seed / "compress.sh")
        self.git("-C", self.seed, "add", "compress.sh")
        self.git("-C", self.seed, "commit", "-m", "initial")
        self.git("-C", self.seed, "remote", "add", "origin", self.remote)
        self.git("-C", self.seed, "push", "-u", "origin", "main")
        self.git("clone", self.remote, self.checkout)
        self.link = self.root / "vcompress"
        self.link.symlink_to(self.checkout / "compress.sh")

    def git(self, *args):
        return subprocess.check_output([GIT, *map(str, args)], env=self.env,
                                       stderr=subprocess.PIPE, text=True).strip()

    def publish_update(self):
        script = self.seed / "compress.sh"
        with script.open("a") as file:
            file.write("\n# test update\n")
        self.git("-C", self.seed, "commit", "-am", "update")
        self.git("-C", self.seed, "push")

    def update(self, *args, shell="/bin/bash", path=None):
        return subprocess.run([shell, str(path or self.link), "--update", *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_updates_via_symlink_and_reruns(self):
        self.publish_update()
        for shell in dict.fromkeys(("/bin/bash", shutil.which("bash"))):
            result = self.update(shell=shell)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("-C", self.checkout, "rev-parse", "HEAD"),
                         self.git("-C", self.seed, "rev-parse", "HEAD"))

    def test_relative_symlink_chain(self):
        self.link.unlink()
        self.link.symlink_to("checkout with spaces/compress.sh")
        outer = self.root / "outer"
        outer.symlink_to("vcompress")
        self.publish_update()
        self.assertEqual(self.update(path=outer).returncode, 0)

    def test_update_without_ffmpeg(self):
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("git", "dirname", "readlink"):
            (tools / name).symlink_to(shutil.which(name))
        self.env["PATH"] = str(tools)
        self.publish_update()
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_changes_are_preserved(self):
        self.publish_update()
        for kind in ("unstaged", "staged", "untracked"):
            with self.subTest(kind=kind):
                path = self.checkout / ("notes.txt" if kind == "untracked" else "compress.sh")
                original = path.read_bytes() if path.exists() else None
                with path.open("ab") as file:
                    file.write(b"\n# keep this local change\n")
                if kind == "staged":
                    self.git("-C", self.checkout, "add", "compress.sh")
                before = path.read_bytes()
                result = self.update()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("local changes", result.stderr)
                self.assertEqual(path.read_bytes(), before)
                # Only reset disposable test fixtures created by this test.
                if kind == "staged":
                    self.git("-C", self.checkout, "restore", "--staged", "compress.sh")
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_diverged_history_is_not_merged(self):
        (self.checkout / "local.txt").write_text("local commit")
        self.git("-C", self.checkout, "add", "local.txt")
        self.git("-C", self.checkout, "commit", "-m", "local")
        before = self.git("-C", self.checkout, "rev-parse", "HEAD")
        self.publish_update()
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual(self.git("-C", self.checkout, "rev-parse", "HEAD"), before)

    def test_standalone_copy_is_rejected(self):
        standalone = self.root / "standalone.sh"
        shutil.copy2(ROOT / "compress.sh", standalone)
        result = self.update(path=standalone)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a Git checkout", result.stderr)

    def test_extra_arguments_are_rejected(self):
        self.assertNotEqual(self.update("--recursive").returncode, 0)

    def test_remote_failure_leaves_checkout_unchanged(self):
        before = self.git("-C", self.checkout, "rev-parse", "HEAD")
        self.git("-C", self.checkout, "remote", "set-url", "origin", self.root / "missing.git")
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual(self.git("-C", self.checkout, "rev-parse", "HEAD"), before)


if __name__ == "__main__":
    unittest.main()
