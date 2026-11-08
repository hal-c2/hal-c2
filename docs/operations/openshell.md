# The OpenShell pin

> For maintainers. Using HAL-C2? See [Sandboxes for code reviews](../user/openshell.md).

An MC installs exactly one OpenShell release, named in
[`HalC2.OpenShell.Manifest`](../../apps/server-ex/lib/hal_c2/open_shell/manifest.ex) with the
SHA-256 of each gateway archive and the digest of each image. The hashes come from that file,
never from the release page or a checksum file next to the archive, so whoever can change a
GitHub release cannot change what an MC runs. Moving the pin is a reviewed code change.

## Moving the pin

1. Read the release notes from the pinned version to the new one. Look for changes to
   `openshell.v1` and to the gateway's configuration (`[openshell.gateway]`, `mtls_auth`,
   the drivers' sections), which
   [`HalC2.OpenShell.Config`](../../apps/server-ex/lib/hal_c2/open_shell/config.ex) writes.
2. Download the three gateway archives (`x86_64-unknown-linux-gnu`,
   `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin`) into an empty scratch directory, and
   check each one's build provenance:

   ```sh
   gh attestation verify openshell-gateway-<target>.tar.gz --repo NVIDIA/OpenShell
   ```

   It must be signed by NVIDIA/OpenShell's release workflow. Record the signer and source
   commit in `@provenance`, and the tag's commit beside them.

3. Put each archive's `sha256sum` in `@gateway`, and each image's digest in `@images` (the
   sandbox runtime, the supervisor, and the default workload image), read from the registry
   with `skopeo inspect` or `docker buildx imagetools inspect`. Reference images by digest,
   not by tag alone.
4. If the protos changed, regenerate the stubs as
   [`proto/NOTICE`](../../apps/server-ex/lib/hal_c2/open_shell/proto/NOTICE) describes, and
   update the release and commit it names.
5. Run the gateway once against the scratch archive with a scratch MC home
   (`mise run openshell --home <dir> --archive <file>`) and run
   `HAL_C2_MC_HOME=<dir> mise exec -- mix hal_c2.openshell check` against it. Do not point it at a root Docker
   daemon; the check needs rootless Podman (or a rootless Docker daemon) to create its probe
   sandbox.

An MC that runs an older pin reports `update-available`, and `hal-c2-service openshell install`
updates it: the previous gateway, its certificates, its configuration and its database are
backed up, and put back if the new gateway fails its check.

## Traps

- The gateway accepts any client certificate its CA signed, and in 0.1.7 any authenticated
  identity sees every workspace. The MC keeps the CA's key off disk after issuing the
  certificates for that reason; `rotate` is the only way to issue new ones.
- OTP's `ssl` caches PEM files by path. The client hands certificates to `ssl` as DER, so a
  rotation that replaces the files in place takes effect on the next connection.
- The service unit and launch agent are the gateway's own (`hal-c2-openshell.service`,
  `io.github.halc2.openshell`), apart from the MC's, so the MC restarting does not restart
  the gateway or its sandboxes.
