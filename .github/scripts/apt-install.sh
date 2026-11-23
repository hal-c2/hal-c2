#!/usr/bin/env bash
# Installs apt packages for a CI step: `apt-install.sh <package>...`.
# A regional mirror sometimes stalls mid-update and apt-get waits on it forever, so each
# attempt is bounded, and a failed or timed-out attempt is retried once.
set -uo pipefail

apt=(sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# At most 90+120 per attempt, 465s in all (515s with every kill grace), so the steps'
# `timeout-minutes: 10` only fires if this script itself hangs.
# A failed or timed-out update still goes on to the install: apt keeps each source's
# lists as they arrive, so one stalled source (security.ubuntu.com, say) leaves the
# others fresh. The attempt fails only if the install does.
attempt() {
  timeout -k 10 90 "${apt[@]}" update
  timeout -k 10 120 "${apt[@]}" install -y "$@"
}

# A package the runner image already has needs no mirror at all.
missing=()
for package in "$@"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$package")
done
[ ${#missing[@]} -eq 0 ] && echo "Already installed: $*" && exit 0
set -- "${missing[@]}"

attempt "$@" && exit 0
echo "::warning::apt-get failed or timed out, retrying in 15s"
sleep 15
# A killed install can leave dpkg half-configured, which would fail the retry.
timeout -k 10 30 sudo dpkg --configure -a
# The retry goes straight to the Ubuntu archive: the runner's mirror list falls back to
# it only after the stalled regional mirror's (azure., us-east-2.ec2., ...) timeouts have
# used up the attempt. archive.ubuntu.com and security.ubuntu.com are left as they are.
# Only a whole hostname ending in .archive.ubuntu.com is rewritten, so a host such as
# foo.archive.ubuntu.com.example.org stays as it is.
sudo sed -i -E 's#(://|@|^|[[:space:]])[a-z0-9.-]*\.archive\.ubuntu\.com([/:[:space:]]|$)#\1archive.ubuntu.com\2#gI' \
  /etc/apt/apt-mirrors.txt /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
# The rewritten mirror now repeats the archive's own entry; keep the first of each,
# whatever its hostname case or priority. The path keeps its case, and an entry whose
# scheme or other metadata (type:, arch:, ...) differs is kept: apt may need that
# transport, or it serves different files.
if [ -f /etc/apt/apt-mirrors.txt ]; then
  awk '{ url = $1; i = index(url, "://"); scheme = i ? tolower(substr(url, 1, i + 2)) : ""
         if (i) url = substr(url, i + 3); i = index(url "/", "/")
         key = scheme tolower(substr(url, 1, i - 1)) substr(url, i)
         for (f = 2; f <= NF; f++) if ($f !~ /^priority:/) key = key " " $f } NF == 0 || !seen[key]++' /etc/apt/apt-mirrors.txt |
    sudo tee /etc/apt/apt-mirrors.txt.dedup >/dev/null &&
    sudo mv /etc/apt/apt-mirrors.txt.dedup /etc/apt/apt-mirrors.txt
fi
# Some runners come up with no Ubuntu source at all, only Microsoft's, so nothing above
# has an entry to fix and every package is "Unable to locate". Give such a runner the
# archive's own (ports for arm64), and list what it had so the log shows why.
# Only what apt reads: its .list and .sources files, without their comments.
sources=$(cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -v '^[[:space:]]*#' || true)
if ! grep -qiE 'ubuntu\.com|apt-mirrors' <<<"$sources"; then
  echo "::warning::No Ubuntu apt source on this runner; adding the archive's. It had: $(find /etc/apt/sources.list.d -mindepth 1 -printf '%f ' 2>&1)"
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  if [ "$(dpkg --print-architecture)" = amd64 ]; then
    archive=http://archive.ubuntu.com/ubuntu security=http://security.ubuntu.com/ubuntu
  else
    archive=http://ports.ubuntu.com/ubuntu-ports security=http://ports.ubuntu.com/ubuntu-ports
  fi
  printf 'Types: deb\nURIs: %s\nSuites: %s %s-updates %s-backports\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\nTypes: deb\nURIs: %s\nSuites: %s-security\nComponents: main restricted universe multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
    "$archive" "$codename" "$codename" "$codename" "$security" "$codename" |
    sudo tee /etc/apt/sources.list.d/hal-c2-ubuntu.sources >/dev/null
fi
attempt "$@"
