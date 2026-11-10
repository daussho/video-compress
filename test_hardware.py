import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent


class HardwareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vcompress-hardware-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "bin"
        self.tools.mkdir()
        self.device = self.root / "render device"
        self.device.touch()
        self.source = self.root / "video.mp4"
        with self.source.open("wb") as file:
            file.truncate(50 * 1024 * 1024)
        self.log = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        VCOMPRESS_VAAPI_DEVICE=str(self.device), CALL_LOG=str(self.log),
                        PROBE_OK="1", ENCODE_OK="1", HEIGHT="720")
        self.tool("uname", "#!/bin/sh\necho Linux\n")
        self.tool("stat", '''#!/usr/bin/env python3
import pathlib, sys
assert sys.argv[1:3] == ['-c%s', '--']
print(pathlib.Path(sys.argv[-1]).stat().st_size)
''')
        self.tool("ffmpeg", '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args == ['-encoders']:
    print('h264_vaapi')
    sys.exit(0)
if 'lavfi' in args:
    sys.exit(0 if os.environ['PROBE_OK'] == '1' else 1)
if os.environ['ENCODE_OK'] != '1':
    sys.exit(1)
pathlib.Path(args[-1]).write_bytes(b'encoded video')
''')
        self.tool("ffprobe", '''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
if not pathlib.Path(args[-1]).exists():
    sys.exit(1)
entry = args[args.index('-show_entries') + 1]
duration = 'N/A' if pathlib.Path(args[-1]).name.startswith('unknown') else os.environ.get('DURATION', '10')
print({'stream=codec_name': 'h264',
       'stream=width,height,bit_rate': '1280,' + os.environ['HEIGHT'] + ',' + os.environ.get('BITRATE', '2000000'),
       'format=duration': duration, 'stream=codec_type,bit_rate': ''}[entry])
''')

    def tool(self, name, contents):
        path = self.tools / name
        path.write_text(contents)
        path.chmod(0o755)

    def run_compress(self, *flags):
        result = subprocess.run(["/bin/bash", str(ROOT / "compress.sh"), str(self.source), *flags],
                                env=self.env, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_vaapi_encoding_and_gpu_downscaling(self):
        result, calls = self.run_compress()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Video encoder: h264_vaapi", result.stdout)
        self.assertEqual(len(calls), 2)
        encode = calls[-1]
        self.assertEqual(encode[encode.index('-vaapi_device') + 1], str(self.device))
        self.assertEqual(encode[encode.index('-c:v') + 1], 'h264_vaapi')
        self.assertEqual(encode[encode.index('-vf') + 1],
                         'format=nv12,hwupload,scale_vaapi=w=-2:h=480')
        self.assertNotIn('Estimated savings:', result.stdout)
        self.assertIn('-hide_banner', encode)
        self.assertEqual(encode[encode.index('-loglevel') + 1], 'error')
        self.assertIn('-stats', encode)
        self.assertFalse(self.source.exists())
        self.assertTrue((self.root / 'video_out.mp4').exists())

    def test_verbose_vaapi_output(self):
        result, calls = self.run_compress('--verbose')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Estimated savings:', result.stdout)
        self.assertNotIn('-hide_banner', calls[-1])
        self.assertNotIn('-loglevel', calls[-1])

    def test_small_video_is_not_upscaled(self):
        self.env['HEIGHT'] = '360'
        result, calls = self.run_compress()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][calls[-1].index('-vf') + 1], 'format=nv12,hwupload')

    def test_failed_probe_uses_software(self):
        self.env['PROBE_OK'] = '0'
        result, calls = self.run_compress()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Video encoder: libx264', result.stdout)
        self.assertIn('libx264', calls[-1])
        self.assertNotIn('Estimated savings:', result.stdout)

    def test_missing_device_uses_software_without_probe(self):
        self.device.unlink()
        result, calls = self.run_compress()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn('libx264', calls[-1])

    def test_encoding_failure_preserves_original(self):
        self.env['ENCODE_OK'] = '0'
        result, calls = self.run_compress()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.source.exists())
        self.assertFalse((self.root / 'video_out.mp4').exists())
        self.assertEqual(len(calls), 2)  # No silent software retry.

    def test_ctrl_c_stops_batch_and_prints_report(self):
        second = self.root / "second.mp4"
        with second.open("wb") as file:
            file.truncate(self.source.stat().st_size)
        self.device.unlink()
        self.tool("ffmpeg", f"""#!/bin/sh
printf 'encode\\n' >> "$CALL_LOG"
kill -{signal.SIGINT.value} 0
exit 255
""")

        result = subprocess.run(
            ["/bin/bash", str(ROOT / "compress.sh"), str(self.root)],
            env=self.env, capture_output=True, text=True, start_new_session=True, timeout=10,
        )

        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["encode"])
        self.assertIn("Before MiB", result.stdout)
        self.assertIn("interrupted", result.stdout)
        self.assertIn("Summary: 0 compressed, 0 skipped, 0 failed", result.stdout)
        self.assertTrue(self.source.exists())
        self.assertTrue(second.exists())

    def test_dry_run_estimates_without_encoding_or_changes(self):
        part = self.root / 'video_out.part.mp4'
        part.write_bytes(b'keep unfinished output')
        result, calls = self.run_compress('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [['-encoders']])
        self.assertIn('candidate', result.stdout)
        self.assertIn('Est. MiB', result.stdout)
        self.assertIn('98.6%', result.stdout)
        self.assertIn('Dry-run summary: 1 candidates, 0 skipped, 0 failed', result.stdout)
        self.assertEqual(self.source.stat().st_size, 50 * 1024 * 1024)
        self.assertEqual(part.read_bytes(), b'keep unfinished output')
        self.assertFalse((self.root / 'video_out.mp4').exists())

    def test_dry_run_skips_poor_estimated_savings(self):
        self.env['DURATION'] = '650'
        result, calls = self.run_compress('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('estimated savings below 20%', result.stdout)
        self.assertIn('Dry-run summary: 0 candidates, 1 skipped, 0 failed', result.stdout)
        self.assertEqual(calls, [['-encoders']])
        self.assertTrue(self.source.exists())

    def test_software_dry_run_reports_unknown_estimates(self):
        self.device.unlink()
        result, calls = self.run_compress('--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        self.assertIn('Video encoder: libx264', result.stdout)
        row = next(line for line in result.stdout.splitlines() if line.startswith('candidate'))
        self.assertEqual(row.split()[:4], ['candidate', '50.00', '-', '-'])
        self.assertTrue(self.source.exists())

    def test_dry_run_batch_recursion_and_unknown_estimate_reset(self):
        unknown = self.root / 'unknown.mp4'
        with unknown.open('wb') as file:
            file.truncate(50 * 1024 * 1024)
        nested = self.root / 'nested'
        nested.mkdir()
        small = nested / 'small.mp4'
        small.write_bytes(b'too small')
        result = subprocess.run(['/bin/bash', str(ROOT / 'compress.sh'), '--dry-run', '--recursive',
                                 '--verbose', str(self.root)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Dry-run summary: 2 candidates, 1 skipped, 0 failed', result.stdout)
        row = next(line for line in result.stdout.splitlines()
                   if line.startswith('candidate') and str(unknown) in line)
        self.assertEqual(row.split()[:4], ['candidate', '50.00', '-', '-'])
        self.assertEqual(small.read_bytes(), b'too small')
        self.assertTrue(unknown.exists())
        self.assertTrue(self.source.exists())
        self.assertFalse(list(self.root.rglob('*_out*')))


if __name__ == '__main__':
    unittest.main()
