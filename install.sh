#!/bin/bash
set -e

# Newer Bash reports its executable as BASH_SOURCE inside stdin-defined functions.
installer_source=${BASH_SOURCE[0]:-}

# Define the full installer before running commands that might read stdin.
install_vcompress() {
if [[ -n "$installer_source" ]]; then
  source_dir=$(cd "$(dirname "$installer_source")" && pwd -P)
  if [[ ! -x "$source_dir/compress.sh" ]]; then
    echo "Run install.sh from a checkout, or pipe it into bash" >&2
    return 1
  fi
  bootstrap=false
else
  source_dir="$HOME/.local/share/video-compress"
  bootstrap=true
fi
bin_dir="$HOME/.local/bin"
link="$bin_dir/vcompress"
if [[ -e "$link" || -L "$link" ]]; then
  if [[ ! -L "$link" ]] || { [[ "$(readlink "$link")" != "$source_dir/compress.sh" ]] && [[ ! "$link" -ef "$source_dir/compress.sh" ]]; }; then
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
    brew install "${packages[@]}" </dev/null
  else
    elevate=()
    if [[ "$(id -u)" != 0 ]]; then
      command -v sudo >/dev/null || {
        echo "Install dependencies as root, or install sudo and rerun install.sh" >&2
        exit 1
      }
      elevate=(sudo)
    fi
    "${elevate[@]}" apt-get update </dev/null
    "${elevate[@]}" apt-get install -y "${packages[@]}" </dev/null
  fi
fi
for tool in git ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Missing command after installation: $tool" >&2; exit 1; }
done

if "$bootstrap"; then
  if [[ -e "$source_dir" || -L "$source_dir" ]]; then
    if ! remote=$(git -C "$source_dir" remote get-url origin); then
      echo "Refusing to use existing directory without a Git origin: $source_dir" >&2
      return 1
    fi
    case "$remote" in
      https://github.com/daussho/video-compress|https://github.com/daussho/video-compress.git|git@github.com:daussho/video-compress.git) ;;
      *) echo "Refusing to use checkout from a different repository: $source_dir" >&2; return 1 ;;
    esac
  else
    mkdir -p "$HOME/.local/share"
    git clone https://github.com/daussho/video-compress.git "$source_dir" </dev/null
  fi
  if [[ ! -x "$source_dir/compress.sh" ]]; then
    echo "Missing executable compress.sh in $source_dir" >&2
    return 1
  fi
fi

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
}

install_vcompress "$@"
