_vcompress_complete() {
  local current="${COMP_WORDS[COMP_CWORD]}" option
  COMPREPLY=()
  if [[ "$current" == -* ]]; then
    for option in --recursive --update; do
      [[ "$option" != "$current"* ]] || COMPREPLY+=("$option")
    done
  fi
  return 0
}

complete -o bashdefault -o default -F _vcompress_complete vcompress
