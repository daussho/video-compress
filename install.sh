#!/bin/bash
set -e

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -x "$source_dir/compress.sh" ]]; then
  echo "Run install.sh from a checkout containing executable compress.sh" >&2
  exit 1
fi
bin_dir="$HOME/.local/bin"
link="$bin_dir/vcompress"
if [[ -e "$link" || -L "$link" ]]; then
  if [[ ! -L "$link" || "$(readlink "$link")" != "$source_dir/compress.sh" ]]; then
    echo "Refusing to replace existing command: $link" >&2
    exit 1
  fi
fi

platform=$(uname -s)
case "$platform" in
  Darwin) ;;
  Linux)
    command -v apt-get >/dev/null || {
      echo "Linux installation requires apt-get, as provided by Ubuntu" >&2
      exit 1
    }
    ;;
  *) echo "Supported systems: macOS and Ubuntu" >&2; exit 1 ;;
esac

packages=()
command -v git >/dev/null || packages+=(git)
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  packages+=(ffmpeg)
fi
if (( ${#packages[@]} > 0 )); then
  if [[ "$platform" == Darwin ]]; then
    command -v brew >/dev/null || {
      echo "Install Homebrew from https://brew.sh, then rerun install.sh" >&2
      exit 1
    }
    brew install "${packages[@]}"
  else
    elevate=()
    if [[ "$(id -u)" != 0 ]]; then
      command -v sudo >/dev/null || {
        echo "Install dependencies as root, or install sudo and rerun install.sh" >&2
        exit 1
      }
      elevate=(sudo)
    fi
    "${elevate[@]}" apt-get update
    "${elevate[@]}" apt-get install -y "${packages[@]}"
  fi
fi
for tool in git ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Missing command after installation: $tool" >&2; exit 1; }
done

mkdir -p "$bin_dir"
if [[ ! -L "$link" ]]; then ln -s "$source_dir/compress.sh" "$link"; fi
echo "Installed: $link"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    echo 'Add this line to ~/.zshrc or ~/.bashrc, then restart your shell:'
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac
echo 'Usage: vcompress --recursive "/path/to/videos"'
