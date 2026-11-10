_vcompress() {
  _arguments \
    '--recursive[Include subdirectories]' \
    '--update[Update the installed Git checkout]' \
    '1:video file or directory:_files'
}

compdef _vcompress vcompress
