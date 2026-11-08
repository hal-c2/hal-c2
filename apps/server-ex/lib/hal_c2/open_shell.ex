defmodule HalC2.OpenShell do
  @moduledoc """
  NVIDIA OpenShell, the sandbox gateway review agents run in (#1411, #1412).

  The MC installs the gateway as a program of its own, under its own systemd user
  service or LaunchAgent (`HalC2.OpenShell.Service`), from the release this MC pins
  (`HalC2.OpenShell.Manifest`), on the platforms it supports
  (`HalC2.OpenShell.Platform`). It talks to it only over gRPC with mTLS
  (`HalC2.OpenShell.Client`), as an identity that is not an operator. The gateway
  belongs to the user, not to the MC: the MC owns only the sandboxes it labels.

  Everything lives under `<data dir>/openshell`, the gateway's database and log under
  the state dir:

      openshell/
        installed.json        what is installed (`state/0`)
        releases/<version>/   the verified gateway binary
        pki/                  ca.crt, server/, client/ (the MC's identity), jwt/
        gateway.toml          the gateway's configuration (`HalC2.OpenShell.Config`)
        backups/<version>/    the matched state an update rolls back to

  The CA's private key is deleted once the certificates are issued, so nothing can
  mint another identity; rotating them (`HalC2.OpenShell.Install.rotate/0`) issues a
  new CA and restarts the gateway, which closes every connection the old ones made.
  """

  @doc "The workspace every MC request is scoped to."
  def workspace, do: "hal-c2"

  @doc "The label every sandbox this MC creates carries, and the only ones it deletes."
  def owner_label, do: "halc2.github.io/environment"

  @doc "This MC's value for `owner_label/0`."
  def owner, do: HalC2.Environment.id()

  def root, do: Path.join(HalC2.Paths.data_dir(), "openshell")
  def state_path, do: Path.join(root(), "installed.json")
  def release_dir(version), do: Path.join([root(), "releases", version])
  def gateway_bin(version), do: Path.join(release_dir(version), "openshell-gateway")
  def pki_dir, do: Path.join(root(), "pki")
  def config_path, do: Path.join(root(), "gateway.toml")
  def backup_dir(version), do: Path.join([root(), "backups", version])
  def db_path, do: Path.join([HalC2.Paths.state_dir(), "openshell", "openshell.db"])
  def log_path, do: Path.join([HalC2.Paths.state_dir(), "logs", "openshell.log"])

  @doc """
  What is installed, or nil: `%{"mode" => "managed" | "external", "version", "port",
  "driver", "socket", "previous", "endpoint"}`. A managed gateway is one this MC
  installed and runs; an external one is one the user pointed it at
  (`HalC2.OpenShell.Install.reuse/1`), which it only talks to.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def state do
    with {:ok, text} <- File.read(state_path()),
         {:ok, %{} = state} <- Jason.decode(text) do
      state
    else
      _ -> nil
    end
  end

  @doc false
  # Only installed.json in the MC's own OpenShell directory.
  # sobelow_skip ["Traversal.FileModule"]
  def put_state(state) do
    HalC2.Paths.mkdir_private!(root())
    tmp = state_path() <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(state, pretty: true))
    File.rename!(tmp, state_path())
  end

  @doc false
  # Only installed.json in the MC's own OpenShell directory.
  # sobelow_skip ["Traversal.FileModule"]
  def delete_state, do: File.rm(state_path())

  @doc """
  How the MC reaches the installed gateway: `{:ok, endpoint, credentials}` for
  `HalC2.OpenShell.Client.connect/2`, or `{:error, :not_installed}`.
  """
  def endpoint do
    case state() do
      %{"endpoint" => endpoint} ->
        {:ok, endpoint, credentials()}

      _ ->
        {:error, :not_installed}
    end
  end

  @doc "The MC's client certificate and key, and the CA it trusts the gateway by."
  def credentials do
    [
      ca: Path.join(pki_dir(), "ca.crt"),
      cert: Path.join([pki_dir(), "client", "tls.crt"]),
      key: Path.join([pki_dir(), "client", "tls.key"])
    ]
  end
end
