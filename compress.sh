#!/bin/bash
set -e

if [[ "${1:-}" == --update ]]; then
  if (( $# != 1 )); then
    echo "Usage: $0 --update" >&2
    exit 1
  fi
  command -v git >/dev/null || { echo "Missing command: git" >&2; exit 1; }
  script=${BASH_SOURCE[0]}
  while [[ -L "$script" ]]; do
    script_dir=$(cd -P "$(dirname "$script")" && pwd)
    script=$(readlink "$script")
    [[ "$script" == /* ]] || script="$script_dir/$script"
  done
  script_dir=$(cd -P "$(dirname "$script")" && pwd)
  if ! repo=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || \
    [[ "$repo" != "$script_dir" ]] || \
    ! git -C "$repo" ls-files --error-unmatch -- "${script##*/}" >/dev/null 2>&1; then
    echo "Self-update requires a Git checkout. Reinstall using install.sh" >&2
    exit 1
  fi
  changes=$(git -C "$repo" status --porcelain)
  if [[ -n "$changes" ]]; then
    echo "Update refused: checkout has local changes. Commit or move them first" >&2
    exit 1
  fi
  echo "Updating: $repo"
  # Replace this process so Bash never continues reading a script changed by Git.
  exec git -C "$repo" pull --ff-only
fi

min_savings=20
platform=$(uname -s)
file_size() {
  case "$platform" in
    Darwin) stat -f%z "$1" ;;
    Linux) stat -c%s -- "$1" ;;
    *) echo "Unsupported operating system: $platform" >&2; return 1 ;;
  esac
}
recursive=false
verbose=false
target=
for arg in "$@"; do
  case "$arg" in
    --recursive) recursive=true ;;
    --verbose) verbose=true ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *)
      if [[ -n "$target" ]]; then
        echo "Pass one file or directory" >&2
        exit 1
      fi
      target="$arg"
      ;;
  esac
done
if [[ -z "$target" || ! -e "$target" ]]; then
  echo "Usage: $0 [--recursive] [--verbose] <video-file-or-directory> | --update" >&2
  exit 1
fi
# Keep relative filenames from being interpreted as command options.
[[ "$target" == /* ]] || target="./$target"
for tool in ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 1; }
done
hardware=false
if [[ "$platform" == Darwin ]] && ffmpeg -encoders 2>/dev/null | grep -q h264_videotoolbox; then
  hardware=true
fi
ffmpeg_log=(-hide_banner -loglevel error -stats)
if "$verbose"; then ffmpeg_log=(); fi
detail() {
  if "$verbose"; then printf '%s\n' "$*"; fi
}

valid_video() {
  local codec
  [[ -s "$1" ]] && codec=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of csv=p=0 "$1") && [[ -n "$codec" ]]
}

# Return 2 for skips so batch mode can count them separately from failures.
compress_video() (
  f="$1"
  case "${f##*/}" in
    *_out.*|*.part.*) echo "Skipped generated file: $f"; return 2 ;;
  esac
  if [[ ! -f "$f" || -L "$f" ]]; then
    echo "Error: not a regular, non-symlink file: $f" >&2
    return 1
  fi
  out="${f%.*}_out.mp4"
  part="${out%.mp4}.part.mp4"
  if valid_video "$out"; then
    echo "Skipped: valid output already exists: $out"
    return 2
  fi
  if [[ -L "$out" || -L "$part" ]]; then
    echo "Error: refusing symlink output: $out or $part" >&2
    return 1
  fi

  start=$(date +%s)
  source_size=$(file_size "$f") || return 1
  if (( source_size == 0 )); then
    echo "Error: empty input: $f" >&2
    return 1
  fi
  if (( source_size < 50 * 1024 * 1024 )); then
    echo "Skipped: file smaller than 50 MiB: $f"
    return 2
  fi
  if ! video_info=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,bit_rate -of csv=p=0 "$f"); then
    echo "Error: cannot read video metadata: $f" >&2
    return 1
  fi
  IFS=, read -r width height bitrate <<< "$video_info"
  if ! [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || (( width == 0 || height == 0 )); then
    echo "Error: invalid video metadata: $f" >&2
    return 1
  fi
  if ! [[ "$bitrate" =~ ^[0-9]+$ ]]; then
    echo "Skipped: unknown video bitrate: $f"
    return 2
  fi
  if (( bitrate <= 600000 )); then
    echo "Skipped: video bitrate ${bitrate} bps: $f"
    return 2
  fi

  # CRF software encoding has no fixed bitrate, so only predict hardware output.
  if "$hardware"; then
    if duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f") && \
      audio_info=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_type,bit_rate -of csv=p=0 "$f"); then
      audio_bitrate=0
      if [[ -n "$audio_info" ]]; then
        IFS=, read -r audio_type audio_bitrate <<< "$audio_info"
      fi
      if [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ && "$audio_bitrate" =~ ^[0-9]+$ ]] && \
        awk -v d="$duration" 'BEGIN {exit !(d > 0)}'; then
        estimated_savings=$(awk -v d="$duration" -v a="$audio_bitrate" -v size="$source_size" \
          'BEGIN {printf "%.1f", (1 - d * (600000 + a) / 8 / size) * 100}')
        detail "Estimated savings: ${estimated_savings}%: $f"
        if awk -v d="$duration" -v a="$audio_bitrate" -v size="$source_size" -v min="$min_savings" \
          'BEGIN {exit !(d * (600000 + a) / 8 > size * (100 - min) / 100)}'; then
          echo "Skipped: estimated savings below ${min_savings}%: $f"
          return 2
        fi
      else
        detail "Estimate unavailable, will check actual savings: $f"
      fi
    else
      detail "Estimate unavailable, will check actual savings: $f"
    fi
  fi

  filters=()
  printf 'Compressing: %s\n' "$f"
  if "$hardware"; then
    (( height <= 480 )) || filters=(-vf "scale_vt=-2:480")
    if ! ffmpeg "${ffmpeg_log[@]}" -nostdin -y -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld -i "$f" \
      -map 0:v:0 -map '0:a:0?' -c:v h264_videotoolbox -b:v 600k -fpsmax 30 -tag:v avc1 "${filters[@]}" -c:a copy "$part"; then
      echo "Error: compression failed: $f" >&2
      return 1
    fi
  else
    (( height <= 480 )) || filters=(-vf "scale=-2:480")
    if ! ffmpeg "${ffmpeg_log[@]}" -nostdin -y -i "$f" -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset ultrafast -crf 28 -fpsmax 30 \
      "${filters[@]}" -c:a copy "$part"; then
      echo "Error: compression failed: $f" >&2
      return 1
    fi
  fi

  if ! valid_video "$part"; then
    echo "Error: incomplete output retained at $part" >&2
    return 1
  fi
  output_size=$(file_size "$part") || return 1
  if (( output_size * 100 > source_size * (100 - min_savings) )); then
    rm -- "$part" || return 1
    echo "Skipped: actual savings below ${min_savings}%, original kept: $f"
    return 2
  fi
  output_info=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,bit_rate -of csv=p=0 "$part") || return 1
  IFS=, read -r output_width output_height output_bitrate <<< "$output_info"
  mv -- "$part" "$out" || return 1
  rm -- "$f" || return 1
  elapsed=$(( $(date +%s) - start ))
  if "$verbose"; then
    echo "→ $out"
    echo "Source: ${width}x${height}, $(awk -v b="$source_size" 'BEGIN {printf "%.1f MB", b / 1048576}')"
    echo "Output: ${output_width}x${output_height}, $(awk -v b="$output_size" 'BEGIN {printf "%.1f MB", b / 1048576}')"
    echo "Video bitrate: ${output_bitrate:-unknown} bps"
    echo "Size change: $(awk -v old="$source_size" -v new="$output_size" 'BEGIN {printf "%.1f%%", (new / old - 1) * 100}')"
    echo "Elapsed: ${elapsed}s"
    echo "Deleted original: $f"
  fi
)

compressed=0
skipped=0
failed=0
rows=()
process_file() {
  local file="$1" before after status label saved display
  before=$(file_size "$file" 2>/dev/null) || before=
  if compress_video "$file"; then
    status=0
    label=compressed
    compressed=$((compressed + 1))
  else
    status=$?
    if [[ "$status" == 2 ]]; then
      label=skipped
      skipped=$((skipped + 1))
    else
      label=failed
      failed=$((failed + 1))
    fi
  fi
  after=
  if [[ "$status" != 1 && -f "${file%.*}_out.mp4" ]]; then
    after=$(file_size "${file%.*}_out.mp4" 2>/dev/null) || after=
  fi
  saved=-
  if [[ -n "$before" && -n "$after" ]] && (( before > 0 )); then
    saved=$(awk -v old="$before" -v new="$after" 'BEGIN {printf "%.1f%%", (1 - new / old) * 100}')
  fi
  [[ -z "$before" ]] || before=$(awk -v b="$before" 'BEGIN {printf "%.2f", b / 1048576}')
  [[ -z "$after" ]] || after=$(awk -v b="$after" 'BEGIN {printf "%.2f", b / 1048576}')
  display="${file//$'\n'/\\n}"
  display="${display//$'\r'/\\r}"
  display="${display//$'\t'/\\t}"
  rows+=("$(printf '%-10s %12s %12s %9s  %s' "$label" "${before:--}" "${after:--}" "$saved" "$display")")
}

print_report() {
  printf '\n%-10s %12s %12s %9s  %s\n' 'Status' 'Before MiB' 'After MiB' 'Saved' 'File'
  if (( ${#rows[@]} > 0 )); then printf '%s\n' "${rows[@]}"; fi
  echo "Summary: $compressed compressed, $skipped skipped, $failed failed"
}

if [[ ! -d "$target" ]]; then
  process_file "$target"
  print_report
  [[ "$failed" == 0 ]]
  exit $?
fi

# Snapshot paths before encoding creates new files in the same directory.
files=$(mktemp) || exit 1
trap 'rm -f -- "$files"' EXIT
if "$recursive"; then
  find "$target" -type f -print0 > "$files" || exit 1
else
  find "$target" -type d ! -path "$target" -prune -o -type f -print0 > "$files" || exit 1
fi
while IFS= read -r -d '' file; do
  extension="${file##*.}"
  case "$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')" in
    mp4|mov|mkv|webm|m4v|avi|mpg|mpeg|ts|mts|m2ts) ;;
    *) continue ;;
  esac
  process_file "$file"
done < "$files"
print_report
[[ "$failed" == 0 ]]
