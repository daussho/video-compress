from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).parent


class CompletionTests(unittest.TestCase):
    def test_bash_flag_prefixes_and_filename_fallback(self):
        for shell in dict.fromkeys(("/bin/bash", shutil.which("bash"))):
            for prefix, expected in (("--rec", "--recursive"), ("--up", "--update"),
                                     ("--ver", "--verbose"),
                                     ("--", "--recursive\n--update\n--verbose"), ("file name", ""),
                                     ("--unknown", ""), ("", "")):
                with self.subTest(shell=shell, prefix=prefix):
                    result = subprocess.run([shell, "-c", '''
source "$1"
COMP_WORDS=(vcompress "$2")
COMP_CWORD=1
_vcompress_complete
if (( ${#COMPREPLY[@]} )); then printf '%s\\n' "${COMPREPLY[@]}"; fi
''', "test", str(ROOT / "completions/vcompress.bash"), prefix],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)
            registration = subprocess.check_output([shell, "-c", 'source "$1"; complete -p vcompress',
                                                    "test", str(ROOT / "completions/vcompress.bash")], text=True)
            self.assertIn("-o default", registration)

    @unittest.skipUnless(shutil.which("zsh"), "Zsh not installed")
    def test_zsh_registration_flags_and_file_completion(self):
        result = subprocess.run([shutil.which("zsh"), "-f", "-c", '''
autoload -Uz compinit
compinit -D -u
source "$1"
[[ "${_comps[vcompress]}" == _vcompress ]] || exit 1
_arguments() { printf '%s\\n' "$@"; }
_vcompress
''', "test", str(ROOT / "completions/vcompress.zsh")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--recursive[", result.stdout)
        self.assertIn("--update[", result.stdout)
        self.assertIn("--verbose[", result.stdout)
        self.assertIn(":_files", result.stdout)


if __name__ == "__main__":
    unittest.main()
