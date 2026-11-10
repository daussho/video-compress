# video-compress

A Bash script for compressing videos with FFmpeg, one file at a time. Supports single files, directories, optional recursion, and a final per-file size report.

**Successful compression deletes the original file. Keep backups.** The output must pass metadata validation and save at least 20% before the original is deleted. Validation does not decode every frame or guarantee that the output is free of corruption.

## Requirements

Supports macOS and Ubuntu, including Kubuntu. Requires Bash, Git, FFmpeg, and ffprobe. macOS uses VideoToolbox when available; Linux automatically uses VA-API GPU encoding when a working device is found (including Intel Alder Lake-N graphics).

The installer installs missing Git and FFmpeg dependencies using Homebrew or apt. On macOS, install Homebrew from https://brew.sh first if dependencies are missing. Ubuntu installation may request your sudo password.

Linux GPU encoding requires FFmpeg with `h264_vaapi`, a working VA-API driver, and read/write access to a `/dev/dri/renderD*` device. On Ubuntu, Intel GPUs typically need `intel-media-va-driver` (install with `sudo apt install intel-media-va-driver` if missing). A one-frame GPU encoding/scaling check selects the first working device; otherwise the script uses software encoding. The selected encoder is printed at startup. To select a particular device, set `VCOMPRESS_VAAPI_DEVICE=/dev/dri/renderD128`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/daussho/video-compress/main/install.sh | bash
```

This executes code downloaded from GitHub. To inspect it first:

```bash
curl -fsSL https://raw.githubusercontent.com/daussho/video-compress/main/install.sh -o install.sh
less install.sh
bash < install.sh
```

The piped installer clones into `$HOME/.local/share/video-compress` and links `$HOME/.local/bin/vcompress` to it. Rerunning reuses that checkout without updating it. An existing checkout from a different repository or an unrelated `vcompress` command is not overwritten. Ubuntu systems without curl can install it with `sudo apt install curl` first.

Make sure `$HOME/.local/bin` is in your `PATH`. If needed, add this line to your shell configuration, such as `~/.zshrc` or `~/.bashrc`, and restart the shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

You can also clone anywhere and run `bash install.sh` there. It links `vcompress` to that checkout, so keep the checkout in place. You can also run `./compress.sh` directly.

## Usage

```bash
# Compress one file.
vcompress "/path/to/video.mp4"

# Process videos directly inside a directory.
vcompress "/path/to/videos"

# Include subdirectories.
vcompress --recursive "/path/to/videos"

# Show full FFmpeg logs and detailed per-file statistics.
vcompress --verbose "/path/to/video.mp4"

# Preview eligible videos and estimated savings, without encoding or deleting.
vcompress --dry-run --recursive "/path/to/videos"
```

Directory mode recognizes `.mp4`, `.mov`, `.mkv`, `.webm`, `.m4v`, `.avi`, `.mpg`, `.mpeg`, `.ts`, `.mts`, and `.m2ts`, case-insensitively. Files are processed sequentially in filesystem traversal order, without explicit sorting. Symlink files are not processed.

By default, output shows the current file, compact FFmpeg progress, skip/error messages, and the final size table. Use `--verbose` to include the FFmpeg banner, stream metadata, savings estimates, and detailed per-file statistics. Errors remain visible in both modes.

Failures do not stop the batch. The final table lists each video's status, original size, output size, and percentage saved. Table sizes are in MiB. The summary shows total space saved by successful compressions in MiB or GiB. The command exits nonzero if any file fails.

Press Ctrl+C to stop the batch and print the results so far. The active file is marked interrupted, and the command exits with status 130. An interrupted encode may leave a temporary output.

## Check GPU encoding

Run `vcompress --check-gpu` to test hardware H.264 encoding with a generated frame. It takes no video path and creates no output file. It reports VideoToolbox on macOS or VA-API and the selected device on Linux. Exit status is 0 when the test succeeds and 1 when hardware encoding is unavailable or FFmpeg is missing. On macOS, this tests encoding independently of input decoding and scaling.

## Dry run

`--dry-run` applies the same size, bitrate, existing-output, and estimated-savings checks without encoding videos or changing originals or outputs. The table shows candidates, skipped files, failures, original sizes, estimated output sizes, and estimated savings. It also works with single files, `--recursive`, and `--verbose`.

Hardware estimates use duration, 600 kb/s video, and copied audio bitrate, excluding container overhead. Missing duration/audio bitrate and software CRF encoding show `-` for unknown estimates; those files can remain candidates because only an actual encode establishes savings. Linux dry runs check encoder listings and readable/writable GPU devices but skip the test encode. GPU availability and final savings are not guaranteed. A normal run still enforces the actual 20% savings minimum before deleting originals.

The dry-run summary totals the original size, estimated output size, and estimated savings for candidates with estimates. Totals use MiB or GiB, and the summary counts candidates with unknown estimates separately.

## Tab completion

Complete `vcompress --rec` to `--recursive`, `--up` to `--update`, `--ver` to `--verbose`, or `--dry` to `--dry-run`, by pressing Tab. Normal file and directory completion is preserved.

For Zsh, run these lines now and add them to `~/.zshrc`, after any shell framework initialization:

```zsh
autoload -Uz compinit
(( $+functions[compdef] )) || compinit
source "$HOME/.local/share/video-compress/completions/vcompress.zsh"
```

For Bash, run this line now and add it to `~/.bashrc`:

```bash
source "$HOME/.local/share/video-compress/completions/vcompress.bash"
```

If your macOS Bash login shell does not load `~/.bashrc`, put the source line in `~/.bash_profile` instead. For custom checkouts, replace the repository path above. The installer prints the command for its actual checkout; it does not edit shell configuration files. After self-updating completion files, restart the shell or source them again.

## Compression rules

- Skip files smaller than 50 MiB. Exactly 50 MiB is eligible.
- Skip video bitrates at or below 600 kb/s, or unknown video bitrates.
- Skip generated `_out` and `.part` files, and files with an existing valid output.
- Downscale videos taller than 480 pixels to 480 pixels high. Smaller videos are not upscaled.
- Cap frame rate at 30 fps. Lower frame rates are preserved.
- Encode the first video stream as H.264 and copy the first audio stream, if present. Other streams are not included.
- Use Apple VideoToolbox hardware decoding, scaling, and encoding when its encoder is available, targeting 600 kb/s video. On Linux, use VA-API hardware scaling and H.264 encoding at 600 kb/s when the startup check succeeds; decoding remains on the CPU for input compatibility. Otherwise, use software `libx264` with `ultrafast` and CRF 28.

For hardware encoding, estimated output size uses duration, the 600 kb/s video target, and the copied audio bitrate. Estimated savings below 20% skip encoding. Missing estimation metadata and software CRF encoding use only the final-size check.

After encoding, actual savings must reach 20%. Otherwise, the temporary output is discarded and the original is kept. Accepted output is saved beside the original as `<name>_out.mp4`, then the original is deleted. Failed encodes may leave `<name>_out.part.mp4` for inspection.

Encoding is lossy. Frame-rate reduction, downscaling, and the low video bitrate can visibly reduce quality. Copied audio must be compatible with MP4 or encoding will fail. Hardware failures do not automatically retry in software.

## Update

```bash
vcompress --update
```

The command follows the installed symlink to its Git checkout and pulls from the configured upstream using `--ff-only`. It refuses staged, unstaged, or untracked local changes. Diverged history and network errors fail without discarding local work. The next invocation uses the updated script; FFmpeg is not required to update.

For older versions without `--update`, bootstrap once with:

```bash
git -C "$HOME/.local/share/video-compress" pull --ff-only
```

If you cloned elsewhere, run that pull in your checkout instead. Standalone copies cannot self-update and must be installed from a Git clone.
