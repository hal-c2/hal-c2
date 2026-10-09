#!/usr/bin/env bash
# Prepare $UX_AUDIT_DIR (default /tmp/hal-c2-ux-audit-<date>) with the audit helpers.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
# Resolved, so a relative path, a `..` or a symlink cannot put the artifacts in the checkout.
out="$(realpath -m "${UX_AUDIT_DIR:-/tmp/hal-c2-ux-audit-$(date +%F)}")"
root="$(realpath "$root")"

missing=()
for bin in sway Xwayland dbus-run-session cua-driver python3 mise; do
  command -v "$bin" > /dev/null || missing+=("$bin")
done
compgen -G "/usr/lib*/at-spi2-registryd" > /dev/null || compgen -G "/usr/lib*/*/at-spi2-registryd" > /dev/null ||
  compgen -G "/usr/libexec/at-spi2-registryd" > /dev/null || missing+=("at-spi2-core")
if ((${#missing[@]})); then
  echo "bootstrap: missing ${missing[*]}; see docs/operations/development.md (Driving the desktop with cua-driver)" >&2
  exit 1
fi
# Severities are argued against ui-ux-pro-max; an audit without it would claim a basis it never had.
# Looked up in every place Claude Code, Codex and the Agent Skills installer put skills.
guide=
for skills in "$root/.agents/skills" "$root/.claude/skills" "$HOME/.agents/skills" "$HOME/.claude/skills" "${CODEX_HOME:-$HOME/.codex}/skills"; do
  if [[ -f $skills/ui-ux-pro-max/scripts/search.py ]]; then
    guide="$skills/ui-ux-pro-max/scripts/search.py"
    break
  fi
done
if [[ -z $guide ]]; then
  echo "bootstrap: the ui-ux-pro-max skill is missing from .agents/skills, .claude/skills and ~/.codex/skills; install it, then re-run:" >&2
  echo "  npx skills add https://github.com/nextlevelbuilder/ui-ux-pro-max-skill --skill ui-ux-pro-max" >&2
  exit 1
fi

case "$out/" in "$root"/*)
  echo "bootstrap: $out is inside the checkout; audit artifacts stay out of the repository" >&2
  exit 1
  ;;
esac
mkdir -p "$out/shots" "$out/scratch"
# Rows from an earlier audit would pass as this one's findings or as areas it visited.
for log in findings coverage; do
  if [[ -s $out/$log.jsonl && ${UX_AUDIT_RESUME:-} != 1 ]]; then
    echo "bootstrap: $out/$log.jsonl already has $(wc -l < "$out/$log.jsonl") rows from an earlier audit." >&2
    echo "           Set UX_AUDIT_DIR to a fresh directory, or UX_AUDIT_RESUME=1 to continue it." >&2
    exit 1
  fi
done
touch "$out/findings.jsonl" "$out/coverage.jsonl"
cp "$here/build_report.py" "$here/github_issues.py" "$here/census.py" "$here/ledger.py" "$out/"
# Shell-quoted and substituted without sed, so any legal path survives.
while IFS= read -r line; do
  if [[ $line == @ROOT@ ]]; then printf 'root=%q\nguide=%q\n' "$root" "$guide"; else printf '%s\n' "$line"; fi
done < "$here/ux" > "$out/ux"
chmod +x "$out/ux"
command -v montage > /dev/null || echo "bootstrap: ImageMagick's montage is missing; ux sheet will not work" >&2

cat << MSG
audit dir : $out
checkout  : $root ($(git -C "$root" rev-parse --short HEAD))
sandbox   : ${HAL_C2_CUA_HOME:-$root/.hal-c2/cua}

next:
  export UX_AUDIT_DIR=$out
  mise run desktop:cua --seed ~/.local/share/hal-c2-dev/elixir/hal-c2.sqlite
  export PATH=\$UX_AUDIT_DIR:\$PATH
  ux census
  ux shot home-1600-dark
MSG
