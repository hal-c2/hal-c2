defmodule HalC2.OpenShell do
  @moduledoc """
  NVIDIA OpenShell, the sandbox gateway review agents are to run in (#1411). Reviews
  start using it with #1412.

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
        pki/                  ca.crt and server/ (the gateway's identity), client/ and
                              client-ca.crt (the MC's, from a CA of its own), jwt/
        gateway.toml          the gateway's configuration (`HalC2.OpenShell.Config`)
        backups/<version>/    the matched state an update rolls back to

  The gateway trusts one client certificate: the MC's, issued by a CA that signed
  nothing else, so the gateway's own certificate does not authenticate as a client.
  Both CAs' private keys are deleted once the certificates are issued, so nothing can
  mint another identity; rotating them (`HalC2.OpenShell.Install.rotate/0`) issues new
  CAs and restarts the gateway, which closes every connection the old ones made.

  A gateway belongs to one HAL-C2 environment. OpenShell 0.1.7 does not scope
  workspaces by identity under mTLS, so two environments on one gateway would see
  each other's sandboxes; the MC refuses to use a gateway that holds another
  environment's (`HalC2.OpenShell.Client.other_environments/2`).

  Several HAL-C2 homes can run on one machine (the user's MC, a dev MC, a scratch
  `HAL_C2_MC_HOME`, a test run), each with a gateway of its own. Everything one
  home's gateway is known by outside its own directories, its service's name and
  the label its driver puts on runtime resources, carries `instance/0`, so no
  home's install, update, stop or uninstall reaches another's gateway. The paths
  here have every symlink resolved, so a home reached by two spellings (a linked
  home, or a linked parent) is one home with one gateway. installed.json records
  the instance it was installed under, and a home whose instance changed (it moved,
  or is reached through a bind mount) refuses to act while the service of the
  recorded one is still there (`HalC2.OpenShell.Service.moved/1`).
  """

  @doc "The workspace every MC request is scoped to."
  def workspace, do: "hal-c2"

  @doc "The label every sandbox this MC creates carries, and the only ones it deletes."
  def owner_label, do: "halc2.github.io/environment"

  @doc "This MC's value for `owner_label/0`."
  def owner, do: HalC2.Environment.id()

  def root, do: canonical(Path.join(HalC2.Paths.data_dir(), "openshell"))

  @doc """
  This home's gateway among the others on the machine: 12 hex digits of the hash
  of `root/0`, whose symlinks are resolved. The service's name
  (`HalC2.OpenShell.Service.name/1`) and the driver's resource label
  (`HalC2.OpenShell.Config.render/1`) carry it.
  """
  def instance do
    :crypto.hash(:sha256, root()) |> binary_part(0, 6) |> Base.encode16(case: :lower)
  end

  # The physical path, however the home was spelled. A directory that does not
  # exist yet resolves as far as its parents do.
  defp canonical(path), do: HalC2.Paths.canonical(path) || Path.expand(path)

  @doc """
  The lock one lifecycle command at a time holds (`HalC2.OpenShell.Install`). It
  sits beside `root/0`, so an uninstall that removes the root keeps it.
  """
  def lock_path, do: root() <> ".lock"

  def state_path, do: Path.join(root(), "installed.json")
  def release_dir(version), do: Path.join([root(), "releases", version])
  def gateway_bin(version), do: Path.join(release_dir(version), "openshell-gateway")
  def pki_dir, do: Path.join(root(), "pki")
  def client_ca_path, do: Path.join(pki_dir(), "client-ca.crt")
  def config_path, do: Path.join(root(), "gateway.toml")
  def backup_dir(version), do: Path.join([root(), "backups", version])
  def db_path, do: canonical(Path.join([HalC2.Paths.state_dir(), "openshell", "openshell.db"]))
  def log_path, do: canonical(Path.join([HalC2.Paths.state_dir(), "logs", "openshell.log"]))

  @doc """
  What is installed, or nil: `%{"mode" => "managed" | "external", "version", "port",
  "driver", "socket", "previous", "endpoint", "instance"}` (`instance/0` when it
  was installed). A managed gateway is one this MC
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

    :ok =
      HalC2.Paths.write_replace(state_path(), Jason.encode_to_iodata!(state, pretty: true), 0o600)
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
      %{"endpoint" => endpoint} = state ->
        {:ok, endpoint, credentials(state)}

      _ ->
        {:error, :not_installed}
    end
  end

  @doc """
  The MC's client certificate and key, and the CA it trusts the gateway by, for
  `state`: in `credentials_dir/1`.
  """
  def credentials(state \\ state()) do
    dir = credentials_dir(state)

    [
      ca: Path.join(dir, "ca.crt"),
      cert: Path.join([dir, "client", "tls.crt"]),
      key: Path.join([dir, "client", "tls.key"])
    ]
  end

  @doc """
  Where `state`'s client credentials are. A user's gateway names a directory of
  its own (`"pki"`, under `root/0`), so that recording another gateway, endpoint
  and credentials together, is the one rename `put_state/1` makes. Any other
  state's are in `pki_dir/0`.
  """
  def credentials_dir(%{"pki" => name}) when is_binary(name),
    do: Path.join(root(), Path.basename(name))

  def credentials_dir(_state), do: pki_dir()
end
