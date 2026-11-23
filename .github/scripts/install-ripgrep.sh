#!/usr/bin/env bash
# Installs a pinned ripgrep from its GitHub release onto the job's PATH. The runner image
# lacks it, and Ubuntu's archive is unreachable from the runners at times when GitHub is not.
set -euo pipefail

version=14.1.1
asset="ripgrep-$version-x86_64-unknown-linux-musl"
sha256=4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e

dir="$RUNNER_TEMP/ripgrep"
mkdir -p "$dir"
# --retry alone gives up at once on a 403, which the release host also sends for a blip.
# The retry window starts with the first attempt, so it outlasts --max-time (a stalled
# attempt still gets retried) and ends early enough that the last attempt fits the
# 10 minutes of the CI step that runs only this script: 360 s, plus one 120 s attempt.
curl -sSfL --retry 5 --retry-all-errors --retry-max-time 360 --max-time 120 -o "$dir/$asset.tar.gz" \
  "https://github.com/BurntSushi/ripgrep/releases/download/$version/$asset.tar.gz"
echo "$sha256  $dir/$asset.tar.gz" | sha256sum -c -
tar -xzf "$dir/$asset.tar.gz" -C "$dir" --strip-components=1 "$asset/rg"
echo "$dir" >> "$GITHUB_PATH"
"$dir/rg" --version | head -1
