_vcompress() {
  _arguments \
    '--recursive[Include subdirectories]' \
    '--update[Update the installed Git checkout]' \
    '--verbose[Show full FFmpeg logs and per-file details]' \
    '1:video file or directory:_files'
}

compdef _vcompress vcompress
