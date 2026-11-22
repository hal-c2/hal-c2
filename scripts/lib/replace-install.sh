# shellcheck shell=bash
# For the release:install tasks that replace a directory. Source it, then:
#   staged_install <installed path>   sets $staging, a directory beside that path to build in
#   swap_install <path in $staging>   puts that in the installed one's place
# Until the swap is done, any exit but a kill -9 leaves what was installed in its place.

staged_install() {
  installed=$1
  staging="$(mktemp -d "$(dirname "$installed")/.hal-c2-install.XXXXXX")"
  trap end_install EXIT
}

swap_install() {
  if [[ -e $installed || -L $installed ]]; then mv "$installed" "$staging/previous"; fi
  mv "$1" "$installed"
}

end_install() {
  if [[ ! -e $installed && ! -L $installed ]] && [[ -e $staging/previous || -L $staging/previous ]]; then
    if ! mv "$staging/previous" "$installed"; then
      echo "release:install: could not put $installed back, it is kept at $staging/previous" >&2
      return
    fi
  fi
  rm -rf "$staging"
}
