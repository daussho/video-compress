_vcompress() {
  _arguments \
    '--recursive[Include subdirectories]' \
    '--update[Update the installed Git checkout]' \
    '--verbose[Show full FFmpeg logs and per-file details]' \
    '--dry-run[List compression candidates and estimated savings without encoding]' \
    '--check-gpu[Test hardware video decode, scaling, and encode]' \
    '1:video file or directory:_files'
}

compdef _vcompress vcompress
