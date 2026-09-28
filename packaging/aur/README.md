# AUR packaging

This directory maintains the [`hal-c2-bin`](https://aur.archlinux.org/packages/hal-c2-bin) and
[`hal-c2-nightly-bin`](https://aur.archlinux.org/packages/hal-c2-nightly-bin) packages. Both
repackage the official x86_64 AppImage from GitHub Releases.

## Publishing

Nothing publishes these automatically since the Electron release workflow was removed.
`packaging/aur/scripts/release.sh` selects the stable or nightly package for a release tag, then
updates its version and checksums, builds it, regenerates `.SRCINFO`, and pushes it to the AUR.

To validate a release on Arch Linux:

```bash
sudo pacman -Syu --needed base-devel github-cli jq namcap
GH_TOKEN=$(gh auth token) RELEASE_TAG=v0.0.33 \
  packaging/aur/scripts/release.sh
```
