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
dry_run=false
check_gpu=false
target=
for arg in "$@"; do
  case "$arg" in
    --recursive) recursive=true ;;
    --verbose) verbose=true ;;
    --dry-run) dry_run=true ;;
    --check-gpu) check_gpu=true ;;
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
gpu_stage() {
  local stage="$1"
  shift
  printf 'Testing %s...\n' "$stage"
  if ffmpeg -hide_banner -loglevel error -nostdin -xerror "$@"; then
    printf 'PASS: %s\n' "$stage"
  else
    printf 'FAIL: %s\n' "$stage" >&2
    return 1
  fi
}

check_gpu_pipeline() {
  local gpu_encoder scale device sample
  local device_args=() upload_args=() decode_args=() encoder_args=()
  case "$platform" in
    Darwin)
      gpu_encoder=h264_videotoolbox
      scale=scale_vt=320:240
      decode_args=(-hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld)
      encoder_args=(-allow_sw 0)
      ;;
    Linux)
      gpu_encoder=h264_vaapi
      scale=scale_vaapi=w=320:h=240:format=nv12
      upload_args=(-vf 'format=nv12,hwupload')
      decode_args=(-hwaccel vaapi -hwaccel_output_format vaapi)
      ;;
    *) echo "GPU diagnostics unavailable on $platform." >&2; return 1 ;;
  esac

  gpu_check_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$gpu_check_dir"' EXIT
  sample="$gpu_check_dir/sample.mp4"
  if [[ "$platform" == Linux ]]; then
    for device in "${devices[@]}"; do
      if [[ ! -r "$device" || ! -w "$device" ]]; then
        printf 'VA-API device missing or inaccessible: %s\n' "$device" >&2
        continue
      fi
      printf 'VA-API device: %s\n' "$device"
      device_args=(-vaapi_device "$device")
      if gpu_stage "H.264 hardware encoding ($gpu_encoder)" "${device_args[@]}" \
        -y -f lavfi -i color=size=640x480:rate=30 "${upload_args[@]}" \
        -frames:v 3 -c:v "$gpu_encoder" -b:v 600k "$sample"; then
        break
      fi
      rm -f -- "$sample"
    done
    if [[ ! -s "$sample" ]]; then
      echo "Hardware H.264 encoding unavailable on $platform." >&2
      return 1
    fi
  else
    gpu_stage "H.264 hardware encoding ($gpu_encoder)" -f lavfi -i color=size=640x480:rate=30 \
      -frames:v 3 -c:v "$gpu_encoder" "${encoder_args[@]}" -b:v 600k "$sample" || return 1
  fi

  local input_args=("${device_args[@]}" "${decode_args[@]}" -i "$sample" -an -frames:v 3)
  gpu_stage "H.264 hardware decoding" "${input_args[@]}" -f null - || return 1
  gpu_stage "hardware scaling" "${input_args[@]}" -vf "$scale" -f null - || return 1
  gpu_stage "hardware decode, scale, and encode together" "${input_args[@]}" \
    -vf "$scale" -c:v "$gpu_encoder" "${encoder_args[@]}" -b:v 600k -f null - || return 1
  printf 'Hardware H.264 pipeline available: %s\n' "$gpu_encoder"
}

if [[ "$platform" == Linux ]]; then
  devices=(/dev/dri/renderD*)
  [[ -z "${VCOMPRESS_VAAPI_DEVICE:-}" ]] || devices=("$VCOMPRESS_VAAPI_DEVICE")
fi
if "$check_gpu"; then
  if (( $# != 1 )); then
    echo "Usage: $0 --check-gpu" >&2
    exit 1
  fi
  command -v ffmpeg >/dev/null || { echo "Missing command: ffmpeg" >&2; exit 1; }
  check_gpu_pipeline
  exit $?
fi

if [[ -z "$target" || ! -e "$target" ]]; then
  echo "Usage: $0 [--recursive] [--verbose] [--dry-run] <video-file-or-directory> | --update | --check-gpu" >&2
  exit 1
fi
# Keep relative filenames from being interpreted as command options.
[[ "$target" == /* ]] || target="./$target"
for tool in ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 1; }
done
hardware=false
encoder=libx264
if [[ "$platform" == Darwin ]] && ffmpeg -encoders 2>/dev/null | grep -q h264_videotoolbox; then
  hardware=true
  encoder=h264_videotoolbox
elif [[ "$platform" == Linux ]]; then
  # Probe an actual encode: an advertised encoder alone does not prove that
  # the driver, device permissions, and GPU support are usable.
  for device in "${devices[@]}"; do
    [[ -r "$device" && -w "$device" ]] || continue
    if "$dry_run"; then
      if ffmpeg -encoders 2>/dev/null | grep -q h264_vaapi; then
        hardware=true
        encoder=h264_vaapi
      fi
      break
    fi
    if ffmpeg -hide_banner -loglevel error -nostdin -vaapi_device "$device" \
      -f lavfi -i color=size=640x480:rate=30 \
      -vf 'format=nv12,hwupload,scale_vaapi=w=320:h=240:format=nv12' \
      -frames:v 1 -c:v h264_vaapi -b:v 600k -f null - >/dev/null 2>&1; then
      hardware=true
      encoder=h264_vaapi
      vaapi_device="$device"
      break
    fi
  done
fi
ffmpeg_log=(-hide_banner -loglevel error -stats)
if "$verbose"; then ffmpeg_log=(); fi
encode_video() {
  local duration="$1" terminal=0
  shift
  if "$verbose" || ! [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    ! awk -v d="$duration" 'BEGIN {exit !(d > 0)}'; then
    ffmpeg "${ffmpeg_log[@]}" "$@"
    return $?
  fi

  [[ ! -t 2 ]] || terminal=1
  ffmpeg -hide_banner -loglevel error -nostats -progress pipe:1 "$@" |
    awk -F= -v duration="$duration" -v terminal="$terminal" '
      $1 == "out_time_us" && $2 ~ /^-?[0-9]+$/ { elapsed = $2 / 1000000 }
      $1 == "speed" { speed = $2 + 0 }
      $1 == "progress" {
        if (elapsed < 0) elapsed = 0
        if (elapsed > duration || $2 == "end") elapsed = duration
        eta = "--:--:--"
        if (speed > 0 || $2 == "end") {
          seconds = speed > 0 ? (duration - elapsed) / speed : 0
          eta = sprintf("%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        if (terminal) printf "\r"
        printf "Progress: %5.1f%% | Speed: %.1fx | ETA: %s", elapsed / duration * 100, speed, eta
        shown = 1
        if (!terminal) printf "\n"
        fflush()
      }
      END { if (terminal && shown) printf "\n" }' >&2
  return "${PIPESTATUS[0]}"
}
detail() {
  if "$verbose"; then printf '%s\n' "$*"; fi
}
echo "Video encoder: $encoder"
if "$dry_run"; then
  echo "Dry run: no videos encoded or changed. GPU availability is not verified."
  echo "Estimates exclude container overhead; unknown estimates are shown as -."
fi

valid_video() {
  local codec
  [[ -s "$1" ]] && codec=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of csv=p=0 "$1") && [[ -n "$codec" ]]
}

# Return 2 for skips and 3 for dry-run candidates.
compress_video() {
  local f="$1" out part start source_size video_info width height pixel_format bitrate
  local duration audio_info audio_bitrate audio_type filters output_size output_info
  local output_width output_height output_bitrate elapsed encode_status
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
    -show_entries stream=width,height,pix_fmt,bit_rate -of csv=p=0 "$f"); then
    echo "Error: cannot read video metadata: $f" >&2
    return 1
  fi
  IFS=, read -r width height pixel_format bitrate <<< "$video_info"
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
        estimated_size=$(awk -v d="$duration" -v a="$audio_bitrate" \
          'BEGIN {printf "%.0f", d * (600000 + a) / 8}')
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

  if "$dry_run"; then return 3; fi

  if ! "$verbose" && [[ -z "$duration" ]]; then
    duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f") || duration=
  fi
  filters=()
  printf 'Compressing: %s\n' "$f"
  if [[ "$encoder" == h264_videotoolbox ]]; then
    (( height <= 480 )) || filters=(-vf "scale_vt=-2:480")
    if ! encode_video "$duration" -nostdin -y -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld -i "$f" \
      -map 0:v:0 -map '0:a:0?' -c:v h264_videotoolbox -b:v 600k -fpsmax 30 -tag:v avc1 "${filters[@]}" -c:a copy "$part"; then
      echo "Error: compression failed: $f" >&2
      return 1
    fi
  elif [[ "$encoder" == h264_vaapi ]]; then
    # VA-API decoders use NV12 surfaces for ordinary 8-bit 4:2:0 video.
    # Other formats still need conversion before H.264 encoding.
    if (( height > 480 )); then
      filters=(-vf 'scale_vaapi=w=-2:h=480:format=nv12')
    elif [[ "$pixel_format" != yuv420p && "$pixel_format" != nv12 ]]; then
      filters=(-vf 'scale_vaapi=format=nv12')
    fi
    detail "Trying VA-API decoding and H.264 encoding on $vaapi_device"
    if encode_video "$duration" -nostdin -xerror -y -vaapi_device "$vaapi_device" \
      -hwaccel vaapi -hwaccel_output_format vaapi -i "$f" \
      -map 0:v:0 -map '0:a:0?' -c:v h264_vaapi -b:v 600k -fpsmax 30 -tag:v avc1 "${filters[@]}" -c:a copy "$part"; then
      :
    else
      encode_status=$?
      # FFmpeg can return 255 on Ctrl+C, including when only it gets SIGINT.
      case "$encode_status" in 130|255) interrupt_batch ;; esac
      echo "VA-API hardware decoding/filtering failed; retrying with CPU decoding: $f" >&2
      filters=(-vf 'format=nv12,hwupload')
      (( height <= 480 )) || filters=(-vf 'format=nv12,hwupload,scale_vaapi=w=-2:h=480')
      if encode_video "$duration" -nostdin -y -vaapi_device "$vaapi_device" -i "$f" \
        -map 0:v:0 -map '0:a:0?' -c:v h264_vaapi -b:v 600k -fpsmax 30 -tag:v avc1 "${filters[@]}" -c:a copy "$part"; then
        :
      else
        encode_status=$?
        case "$encode_status" in 130|255) interrupt_batch ;; esac
        echo "Error: compression failed: $f" >&2
        return 1
      fi
    fi
  else
    (( height <= 480 )) || filters=(-vf "scale=-2:480")
    if ! encode_video "$duration" -nostdin -y -i "$f" -map 0:v:0 -map '0:a:0?' -c:v libx264 -preset ultrafast -crf 28 -fpsmax 30 \
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
}

compressed=0
saved_bytes=0
skipped=0
failed=0
candidates=0
estimated_count=0
estimated_input_bytes=0
estimated_output_bytes=0
rows=()
active_file=
inspect_file() {
  local file="$1"
  estimated_size=
  estimated_savings=
  before=$(file_size "$file" 2>/dev/null) || before=
  if compress_video "$file"; then
    status=0
  else
    status=$?
  fi
  after=
  if "$dry_run"; then
    after="$estimated_size"
  elif [[ "$status" != 1 && -f "${file%.*}_out.mp4" ]]; then
    after=$(file_size "${file%.*}_out.mp4" 2>/dev/null) || after=
  fi
}

record_file() {
  local display="$1" status="$2" before="$3" after="$4" label saved
  case "$status" in
    0) label=compressed; compressed=$((compressed + 1)) ;;
    2) label=skipped; skipped=$((skipped + 1)) ;;
    3)
      label=candidate
      candidates=$((candidates + 1))
      if [[ -n "$before" && -n "$after" ]]; then
        estimated_count=$((estimated_count + 1))
        estimated_input_bytes=$((estimated_input_bytes + before))
        estimated_output_bytes=$((estimated_output_bytes + after))
      fi
      ;;
    *) label=failed; failed=$((failed + 1)) ;;
  esac
  display="${display//$'\n'/\\n}"
  display="${display//$'\r'/\\r}"
  display="${display//$'\t'/\\t}"
  saved=-
  if [[ -n "$before" && -n "$after" ]] && (( before > 0 )); then
    if [[ "$status" == 0 ]]; then
      saved_bytes=$((saved_bytes + before - after))
    fi
    saved=$(awk -v old="$before" -v new="$after" 'BEGIN {printf "%.1f%%", (1 - new / old) * 100}')
  fi
  [[ -z "$before" ]] || before=$(awk -v b="$before" 'BEGIN {printf "%.2f", b / 1048576}')
  [[ -z "$after" ]] || after=$(awk -v b="$after" 'BEGIN {printf "%.2f", b / 1048576}')
  rows+=("$(printf '%-11s %12s %12s %9s  %s' "$label" "${before:--}" "${after:--}" "$saved" "$display")")
}

process_file() {
  local before after status
  active_file="$1"
  inspect_file "$1"
  active_file=
  record_file "$1" "$status" "$before" "$after"
}

format_size() {
  awk -v bytes="$1" 'BEGIN {
    if (bytes >= 1073741824) printf "%.2f GiB", bytes / 1073741824
    else printf "%.2f MiB", bytes / 1048576
  }'
}

print_report() {
  if "$dry_run"; then
    printf '\n%-11s %12s %12s %9s  %s\n' 'Status' 'Before MiB' 'Est. MiB' 'Est.saved' 'File'
  else
    printf '\n%-11s %12s %12s %9s  %s\n' 'Status' 'Before MiB' 'After MiB' 'Saved' 'File'
  fi
  if (( ${#rows[@]} > 0 )); then printf '%s\n' "${rows[@]}"; fi
  if "$dry_run"; then
    echo "Dry-run summary: $candidates candidates, $skipped skipped, $failed failed"
    if (( estimated_count > 0 )); then
      printf 'Estimated totals for %d of %d candidates: %s before, %s after, %s saved\n' \
        "$estimated_count" "$candidates" "$(format_size "$estimated_input_bytes")" \
        "$(format_size "$estimated_output_bytes")" \
        "$(format_size "$((estimated_input_bytes - estimated_output_bytes))")"
    fi
    if (( estimated_count < candidates )); then
      echo "Candidates without estimates: $((candidates - estimated_count))"
    fi
  else
    echo "Summary: $compressed compressed, $skipped skipped, $failed failed"
    printf 'Total saved: %s\n' "$(format_size "$saved_bytes")"
  fi
}

interrupt_batch() {
  trap '' INT
  if [[ -n "$active_file" ]]; then
    active_file="${active_file//$'\n'/\\n}"
    active_file="${active_file//$'\r'/\\r}"
    active_file="${active_file//$'\t'/\\t}"
    rows+=("$(printf '%-11s %12s %12s %9s  %s' interrupted - - - "$active_file")")
  fi
  printf '\nInterrupted by Ctrl+C.\n' >&2
  print_report
  exit 130
}
trap interrupt_batch INT

if [[ ! -d "$target" ]]; then
  process_file "$target"
  print_report
  [[ "$failed" == 0 ]]
  exit $?
fi

# Snapshot paths before encoding creates new files in the same directory.
scan_dir=$(mktemp -d) || exit 1
files="$scan_dir/files"
scan_pids=()
scan_paths=()

cleanup_scan() {
  if (( ${#scan_pids[@]} )); then
    kill "${scan_pids[@]}" 2>/dev/null || :
    wait 2>/dev/null || :
  fi
  rm -rf -- "$scan_dir"
}
trap cleanup_scan EXIT

collect_scans() {
  local index status before after
  for index in "${!scan_pids[@]}"; do
    if wait "${scan_pids[index]}" &&
      IFS=: read -r status before after < "$scan_dir/$index"; then
      record_file "${scan_paths[index]}" "$status" "$before" "$after"
    else
      echo "Error: dry-run scan failed: ${scan_paths[index]}" >&2
      record_file "${scan_paths[index]}" 1 "" ""
    fi
    unset 'scan_pids[index]'
  done
  scan_paths=()
}

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
  if "$dry_run"; then
    index=${#scan_pids[@]}
    scan_paths[index]="$file"
    (
      inspect_file "$file"
      printf '%s:%s:%s\n' "$status" "$before" "$after" > "$scan_dir/$index"
    ) </dev/null &
    scan_pids[index]=$!
    if (( ${#scan_pids[@]} == 4 )); then collect_scans; fi
  else
    process_file "$file"
  fi
done < "$files"
if "$dry_run"; then collect_scans; fi
print_report
[[ "$failed" == 0 ]]
