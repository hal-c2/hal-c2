# shellcheck shell=bash
# For the release:install tasks that replace a directory. Source it, then:
#   staged_install <installed path>   sets $staging, a directory beside that path to build in
#   swap_install <path in $staging>   puts that in the installed one's place
# Until the swap is done, a failure, HUP, INT or TERM leaves what was installed in its place.

staged_install() {
  installed=$1
  staging="$(mktemp -d "$(dirname "$installed")/.hal-c2-install.XXXXXX")"
  trap end_install EXIT
  # Trapped, so bash waits for the mv it is running before it cleans up. They clean up
  # themselves: an exit alone would cut short a cleanup that has just started.
  trap 'end_install; exit 129' HUP
  trap 'end_install; exit 130' INT
  trap 'end_install; exit 143' TERM
}

swap_install() {
  if [[ -e $installed || -L $installed ]]; then mv "$installed" "$staging/previous"; fi
  mv "$1" "$installed"
}

end_install() {
  trap '' HUP INT TERM # and so for the mv and rm below
  trap - EXIT
  if [[ ! -e $installed && ! -L $installed ]] && [[ -e $staging/previous || -L $staging/previous ]]; then
    if ! mv "$staging/previous" "$installed"; then
      echo "release:install: could not put $installed back, it is kept at $staging/previous" >&2
      return
    fi
  fi
  rm -rf "$staging"
}
