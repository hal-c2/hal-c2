defmodule HalC2.OpenShell.Manifest do
  @moduledoc """
  The OpenShell release this MC runs, pinned: every artifact by its SHA-256 or
  image digest, taken from here and never from the release itself or the network.
  `docs/operations/openshell.md` says how to move the pin, which includes checking
  the release's build provenance and recording what it named.

  The release publishes no SBOM; its archives carry GitHub build provenance
  (SLSA v1), whose signer and source commit are recorded in `provenance/0`.
  """

  @version "0.1.7"

  @gateway %{
    "x86_64-unknown-linux-gnu" =>
      "e1714dcfd85c949e2f53260bcfbf04b203f6f5cbd3a61e61c11c38cbc91cb102",
    "aarch64-unknown-linux-gnu" =>
      "eb0ba91efebbcc61e4cfae5fb18934c5fe308ece1a09ba16c999d00c452109dc",
    "aarch64-apple-darwin" => "fe47a385c16c10cde8905bf1bf627e4a9fbf4a81bcf44b388dec4d22618fbb48"
  }

  # The drivers pull these into the runtime; a digest makes the pull exact.
  @images %{
    sandbox_runtime:
      "ghcr.io/nvidia/openshell/sandbox:0.1.7@sha256:89819c03f291d9b909c3fc2962360e24af4516627422d18f3e681829f003f347",
    supervisor:
      "ghcr.io/nvidia/openshell/supervisor:0.1.7@sha256:a07864bd0c546716039c2000a919f50ce8f7f1f67ba37dda350cf64d3a7cfb06",
    # A sandbox created without an image of its own; reviews name theirs (#1412).
    default_workload:
      "nvcr.io/nvidia/base/ubuntu:24.04@sha256:d9461f428eea54e553add3a5158a0f245c6e1ea73efc59fff8e98e3d4a38e378",
    # Code reviews (#1412): OpenShell Community's base image, with git, Claude Code at
    # /usr/local/bin/claude and Codex at /usr/bin/codex, which the review policy names.
    review_workload:
      "ghcr.io/nvidia/openshell-community/sandboxes/base@sha256:aeef1c63f00e2913ea002ccb3aaf925f338b5c5d70e63576f0d95c16a138044e"
  }

  @provenance %{
    "signer" =>
      "https://github.com/NVIDIA/OpenShell/.github/workflows/release-publish.yml@refs/heads/main",
    "sourceCommit" => "32dcc4a67f4939b71d72b0efb392c2c0998e48ac",
    "tagCommit" => "5d25211b25a8fc887e8d5c606d57d6ab22f1d76c"
  }

  def version, do: @version

  @doc "The gateway targets this release has an archive for."
  def targets, do: Map.keys(@gateway)

  @doc "`%{name, url, sha256}` of the gateway archive for `target`, or nil."
  def gateway(target) do
    with sha256 when is_binary(sha256) <- @gateway[target] do
      name = "openshell-gateway-#{target}.tar.gz"

      %{
        name: name,
        url: "https://github.com/NVIDIA/OpenShell/releases/download/v#{@version}/#{name}",
        sha256: sha256
      }
    end
  end

  @doc "The pinned image references, by role."
  def images, do: @images

  def provenance, do: @provenance
end
