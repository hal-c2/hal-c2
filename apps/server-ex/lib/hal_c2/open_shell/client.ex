defmodule HalC2.OpenShell.Client do
  @moduledoc """
  The MC's side of OpenShell's `openshell.v1.OpenShell` gRPC API, over HTTP/2 with
  mutual TLS. This is the whole surface the MC uses; it holds no API for provider
  policy approvals or operator work, never reads a provider's credentials back
  (`create_provider/4` only writes them), and refuses a plaintext endpoint.

      {:ok, conn} = Client.connect()
      {:ok, %{version: "0.1.7"}} = Client.health(conn)
      {:ok, sandbox} = Client.create_sandbox(conn, "review-42", labels: %{"halc2.github.io/review" => "42"},
        image: image, policy: policy, limits: %{cpu: "2", memory: "4Gi"})
      :ok = Client.upload(conn, "review-42", "/sandbox/src", tar)
      {:ok, exec} = Client.exec(conn, "review-42", ["claude", "--print"])
      # {:openshell_exec, ^exec, {:stdout, data}} ... {:openshell_exec, ^exec, {:exit, 0}}
      {:ok, sandboxes} = Client.list_sandboxes(conn, %{"halc2.github.io/review" => "42"})
      :ok = Client.delete_sandbox(conn, "review-42")
      Client.disconnect(conn)

  Every request is scoped to the `hal-c2` workspace (`HalC2.OpenShell.workspace/0`).
  On OpenShell 0.1.7 that scope is advisory: without an OIDC provider the gateway
  treats every certificate it accepts as a platform admin, so the MC enforces
  ownership itself. Every sandbox it creates carries this MC's owner label
  (`HalC2.OpenShell.owner_label/0`), listing returns only those, and deleting one
  that lacks it is refused.

  A gateway belongs to one environment. `connect/0` refuses one that holds another
  environment's sandboxes (`other_environments/2`), since under that same lack of
  scoping the two would see each other's; it never touches theirs.

  Each call is bounded (10 s by default, `:timeout` to change it); an exec runs
  until it exits or is cancelled (`HalC2.OpenShell.Exec`).
  """

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Exec
  alias HalC2.OpenShell.Proto.Openshell.Datamodel.V1, as: Datamodel
  alias HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector
  alias HalC2.OpenShell.Proto.Openshell.V1, as: Pb
  alias Pb.OpenShell.Stub

  @enforce_keys [:channel]
  defstruct [:channel]

  @type t :: %__MODULE__{channel: GRPC.Channel.t()}
  @timeout 10_000
  # A label value the gateway accepts: what Kubernetes allows.
  @label_key ~r/\A([a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?\z/
  @label_value ~r/\A([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?\z/

  @doc """
  Connects to the installed gateway (`HalC2.OpenShell.endpoint/0`) to use it:
  `{:error, {:shared_gateway, environments}}` when another HAL-C2 environment has
  sandboxes on it, so no new sandbox is made there. Checked on every connect, since
  a gateway can become shared after it was set up. Managing a gateway that is
  shared (status, draining, uninstalling) uses `connect_unchecked/0`.
  """
  def connect do
    with {:ok, conn} <- connect_unchecked() do
      case other_environments(conn) do
        {:ok, []} ->
          {:ok, conn}

        {:ok, others} ->
          disconnect(conn)
          {:error, {:shared_gateway, others}}

        error ->
          disconnect(conn)
          error
      end
    end
  end

  @doc "Connects to the installed gateway without checking who else uses it."
  def connect_unchecked do
    with {:ok, endpoint, credentials} <- OpenShell.endpoint(), do: connect(endpoint, credentials)
  end

  @doc """
  Connects to `endpoint` (`https://host:port`) with `ca:`, `cert:` and `key:` file
  paths.
  """

  def connect(endpoint, credentials) do
    with {:ok, host, port} <- parse_endpoint(endpoint),
         {:ok, ssl} <- ssl_options(host, credentials) do
      target = "#{address_family(host)}:#{host}:#{port}"

      case GRPC.Stub.connect(target,
             cred: GRPC.Credential.new(ssl: ssl),
             adapter: GRPC.Client.Adapters.Mint
           ) do
        {:ok, channel} -> {:ok, %__MODULE__{channel: channel}}
        {:error, reason} -> {:error, {:connect, reason}}
      end
    end
  end

  @doc false
  def parse_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, port: port, path: path}
      when is_binary(host) and host != "" and is_integer(port) and path in [nil, "", "/"] ->
        {:ok, host, port}

      %URI{scheme: scheme} when scheme in ["http", "h2c", "grpc"] ->
        {:error, :plaintext_refused}

      _ ->
        {:error, :bad_endpoint}
    end
  end

  defp address_family(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> "ipv6"
      _ -> "ipv4"
    end
  end

  # `anonymous: true` presents no certificate: how `HalC2.OpenShell.Install.smoke/2`
  # checks that the gateway refuses a caller that has none.
  #
  # The files are read here and handed to ssl as DER, not as paths: ssl caches a
  # PEM file by its path, so after `rotate` replaced the certificates in place a
  # path would keep verifying with the old CA for minutes.
  defp ssl_options(host, credentials) do
    keys = if credentials[:anonymous], do: [:ca], else: [:ca, :cert, :key]

    with {:ok, pems} <- read_pems(credentials, keys),
         [_ | _] = cas <- for({:Certificate, der, _} <- pems[:ca], do: der),
         {:ok, identity} <- identity(pems) do
      {:ok,
       [
         verify: :verify_peer,
         cacerts: cas,
         versions: [:"tlsv1.3", :"tlsv1.2"],
         server_name_indication:
           if(match?({:ok, _}, :inet.parse_address(to_charlist(host))),
             do: :disable,
             else: to_charlist(host)
           )
       ] ++ identity}
    else
      _ -> {:error, :credentials_missing}
    end
  end

  # The MC's own pki directory, or the files the local user passed to `reuse`.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_pems(credentials, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      with path when is_binary(path) <- Keyword.get(credentials, key),
           {:ok, text} <- File.read(path),
           [_ | _] = entries <- :public_key.pem_decode(text) do
        {:cont, {:ok, Map.put(acc, key, entries)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp identity(%{cert: certs, key: keys}) do
    chain = for {:Certificate, der, :not_encrypted} <- certs, do: der

    key =
      Enum.find_value(keys, fn
        {type, der, :not_encrypted}
        when type in [:ECPrivateKey, :RSAPrivateKey, :PrivateKeyInfo] ->
          {type, der}

        _ ->
          nil
      end)

    if chain != [] and key, do: {:ok, [cert: chain, key: key]}, else: :error
  end

  defp identity(_anonymous), do: {:ok, []}

  @doc "Closes the connection, and every exec stream on it with it."
  def disconnect(%__MODULE__{channel: channel}) do
    GRPC.Stub.disconnect(channel)
    :ok
  end

  @doc """
  `{:ok, %{status: :healthy | :degraded | :unhealthy | :unspecified, version}}`.
  The one call the gateway answers without authenticating the caller.
  """
  def health(%__MODULE__{} = conn, opts \\ []) do
    with {:ok, %Pb.HealthResponse{status: status, version: version}} <-
           call(conn, :health, %Pb.HealthRequest{}, opts) do
      {:ok, %{status: service_status(status), version: version}}
    end
  end

  @doc "Who the gateway takes this MC's certificate for: `%{subject, roles, identity_provider}`."
  def current_user(%__MODULE__{} = conn, opts \\ []) do
    with {:ok, %Pb.GetCurrentUserResponse{} = user} <-
           call(conn, :get_current_user, %Pb.GetCurrentUserRequest{}, opts) do
      {:ok,
       %{subject: user.subject, roles: user.roles, identity_provider: user.identity_provider}}
    end
  end

  @doc "`{:ok, %{version, drivers}}`: the gateway's version and its compute drivers."
  def gateway_info(%__MODULE__{} = conn, opts \\ []) do
    with {:ok, %Pb.GetGatewayInfoResponse{} = info} <-
           call(conn, :get_gateway_info, %Pb.GetGatewayInfoRequest{}, opts) do
      {:ok,
       %{
         version: info.gateway_version,
         drivers: Enum.map(info.compute_drivers, &Map.get(&1, :name))
       }}
    end
  end

  @doc "Creates the `hal-c2` workspace unless it exists."
  def ensure_workspace(%__MODULE__{} = conn, opts \\ []) do
    name = OpenShell.workspace()

    case call(conn, :get_workspace, %Pb.GetWorkspaceRequest{name: name}, opts) do
      {:ok, _} ->
        :ok

      {:error, %{status: :not_found}} ->
        case call(conn, :create_workspace, %Pb.CreateWorkspaceRequest{name: name}, opts) do
          {:ok, _} -> :ok
          {:error, %{status: :already_exists}} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Creates sandbox `name` and returns it (`sandbox/1`). Options:

    * `:labels` - a map; this MC's owner label is added and cannot be replaced
    * `:image` - the workload image, by digest (the manifest's default otherwise)
    * `:policy` - an `openshell.sandbox.v1.SandboxPolicy` struct
    * `:limits` - `%{cpu: "2", memory: "4Gi"}`; the PID ceiling is the gateway's
      (`HalC2.OpenShell.Config.pids_limit/0`)
    * `:environment` - a map of variables
    * `:command` - the main process, a list (the image's otherwise)
    * `:providers` - provider names to attach
  """
  def create_sandbox(%__MODULE__{} = conn, name, opts \\ []) do
    with {:ok, labels} <- owned_labels(Keyword.get(opts, :labels, %{})) do
      template = %Pb.SandboxTemplate{
        image: Keyword.get(opts, :image, ""),
        resources: resources(Keyword.get(opts, :limits))
      }

      spec = %Pb.SandboxSpec{
        template: template,
        policy: Keyword.get(opts, :policy),
        environment: Map.new(Keyword.get(opts, :environment, %{})),
        command: Keyword.get(opts, :command, []),
        providers: Keyword.get(opts, :providers, []),
        restart_policy: :SANDBOX_RESTART_POLICY_NEVER
      }

      request = %Pb.CreateSandboxRequest{
        workspace_scope: scope(),
        name: name,
        labels: labels,
        spec: spec,
        request_id: request_id()
      }

      with {:ok, %Pb.SandboxResponse{sandbox: sandbox}} <-
             call(conn, :create_sandbox, request, opts) do
        {:ok, sandbox(sandbox)}
      end
    end
  end

  defp resources(nil), do: nil

  defp resources(limits) do
    limits = for {k, v} when k in [:cpu, :memory] <- limits, into: %{}, do: {to_string(k), v}
    Google.Protobuf.from_map(%{"limits" => limits, "requests" => limits})
  end

  @doc "`{:ok, sandbox}` (`sandbox/1`), `{:error, :not_owned}` or the gateway's error."
  def get_sandbox(%__MODULE__{} = conn, name, opts \\ []) do
    request = %Pb.GetSandboxRequest{workspace_scope: scope(), name: name}

    with {:ok, %Pb.SandboxResponse{sandbox: sandbox}} <- call(conn, :get_sandbox, request, opts) do
      sandbox = sandbox(sandbox)
      if owned?(sandbox), do: {:ok, sandbox}, else: {:error, :not_owned}
    end
  end

  @doc "This MC's sandboxes that carry every label in `labels`, all pages of them."
  def list_sandboxes(%__MODULE__{} = conn, labels \\ %{}, opts \\ []) do
    with {:ok, labels} <- owned_labels(labels) do
      selector = labels |> Enum.sort() |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)
      list_pages(conn, selector, "", [], opts)
    end
  end

  @doc """
  The other HAL-C2 environments that have sandboxes on the gateway, in any
  workspace: the distinct values of the owner label that are not this MC's, sorted.
  Sandboxes without the label are not HAL-C2's and do not count. Read-only.
  """
  def other_environments(%__MODULE__{} = conn, opts \\ []) do
    all = %WorkspaceSelector{selection: {:all_workspaces, %Datamodel.AllWorkspaces{}}}

    with {:ok, sandboxes} <- list_pages(conn, all, "", "", [], opts, fn _ -> true end) do
      others =
        for %{labels: labels} <- sandboxes,
            owner = labels[OpenShell.owner_label()],
            owner not in [nil, "", OpenShell.owner()],
            uniq: true,
            do: owner

      {:ok, Enum.sort(others)}
    end
  end

  defp list_pages(conn, selector, token, acc, opts) do
    list_pages(conn, scope(), selector, token, acc, opts, &owned?/1)
  end

  defp list_pages(conn, scope, selector, token, acc, opts, keep) do
    request = %Pb.ListSandboxesRequest{
      workspace_scope: scope,
      label_selector: selector,
      page_size: 500,
      page_token: token
    }

    with {:ok, %Pb.ListSandboxesResponse{sandboxes: page, next_page_token: next}} <-
           call(conn, :list_sandboxes, request, opts) do
      # For this MC's sandboxes the selector already asks for the owner label; `keep`
      # is the MC's own check.
      acc = acc ++ (page |> Enum.map(&sandbox/1) |> Enum.filter(keep))

      if next in [nil, ""],
        do: {:ok, acc},
        else: list_pages(conn, scope, selector, next, acc, opts, keep)
    end
  end

  @doc """
  Deletes sandbox `name` if this MC owns it. `:ok` once the gateway took it, or when
  it is already gone; `{:error, :not_owned}` for one this MC did not create.
  """
  def delete_sandbox(%__MODULE__{} = conn, name, opts \\ []) do
    case get_sandbox(conn, name, opts) do
      {:ok, _} ->
        request = %Pb.DeleteSandboxRequest{
          workspace_scope: scope(),
          name: name,
          allow_missing: true,
          request_id: request_id()
        }

        with {:ok, %Pb.DeleteSandboxResponse{}} <- call(conn, :delete_sandbox, request, opts),
             do: :ok

      {:error, %{status: :not_found}} ->
        :ok

      error ->
        error
    end
  end

  @doc """
  Creates provider `name` of `type` (`"claude"`, `"codex"`, ...) holding
  `credentials` (`%{"ANTHROPIC_API_KEY" => key}`), with this MC's owner label. A
  sandbox created with it in `:providers` gets the credentials as OpenShell injects
  them, never as an environment value the MC set. Nothing here reads them back.
  """
  def create_provider(%__MODULE__{} = conn, name, type, credentials, opts \\ []) do
    with {:ok, labels} <- owned_labels(Keyword.get(opts, :labels, %{})) do
      request = %Pb.CreateProviderRequest{
        workspace_scope: scope(),
        provider: %HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider{
          metadata: %HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta{
            name: name,
            labels: labels
          },
          type: type,
          credentials: Map.new(credentials)
        },
        request_id: request_id()
      }

      with {:ok, %Pb.ProviderResponse{}} <- call(conn, :create_provider, request, opts), do: :ok
    end
  end

  @doc "The names of this MC's providers that carry every label in `labels`."
  def list_providers(%__MODULE__{} = conn, labels \\ %{}, opts \\ []) do
    with {:ok, labels} <- owned_labels(labels) do
      selector = labels |> Enum.sort() |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)
      provider_pages(conn, selector, "", [], opts)
    end
  end

  defp provider_pages(conn, selector, token, acc, opts) do
    request = %Pb.ListProvidersRequest{
      workspace_scope: scope(),
      label_selector: selector,
      page_size: 500,
      page_token: token
    }

    with {:ok, %Pb.ListProvidersResponse{providers: page, next_page_token: next}} <-
           call(conn, :list_providers, request, opts) do
      owner = OpenShell.owner()

      names =
        for %{metadata: %{name: name, labels: labels}} <- page,
            labels[OpenShell.owner_label()] == owner,
            do: name

      acc = acc ++ names
      if next in [nil, ""], do: {:ok, acc}, else: provider_pages(conn, selector, next, acc, opts)
    end
  end

  @doc "Deletes provider `name`; `:ok` when it is gone, already or now."
  def delete_provider(%__MODULE__{} = conn, name, opts \\ []) do
    request = %Pb.DeleteProviderRequest{
      workspace_scope: scope(),
      name: name,
      allow_missing: true,
      request_id: request_id()
    }

    case call(conn, :delete_provider, request, opts) do
      {:ok, _} -> :ok
      {:error, %{status: :not_found}} -> :ok
      error -> error
    end
  end

  @doc """
  The policy sandbox `name` runs under as the gateway composed it, a gateway-wide
  policy included: `{:ok, %SandboxPolicy{}}` for a sandbox this MC owns.
  """
  def sandbox_policy(%__MODULE__{} = conn, name, opts \\ []) do
    request = %HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigRequest{
      workspace_scope: scope(),
      name: name
    }

    with {:ok, _} <- get_sandbox(conn, name, opts),
         {:ok, %{policy: policy}} <- call(conn, :get_sandbox_config, request, opts) do
      {:ok, policy}
    end
  end

  @doc """
  Starts `command` in sandbox `name` on a full-duplex stream owned by the caller,
  and returns its `HalC2.OpenShell.Exec`. Options: `:workdir`, `:environment`,
  `:tty` (false), `:timeout_seconds` (none). See `HalC2.OpenShell.Exec` for the
  messages it sends and how to write to it.
  """
  def exec(%__MODULE__{channel: channel}, name, command, opts \\ []) do
    start = %Pb.ExecSandboxRequest{
      workspace_scope: scope(),
      sandbox: name,
      command: command,
      workdir: Keyword.get(opts, :workdir, ""),
      environment: Map.new(Keyword.get(opts, :environment, %{})),
      tty: Keyword.get(opts, :tty, false),
      execution_timeout:
        case Keyword.get(opts, :timeout_seconds) do
          nil -> nil
          seconds -> %Google.Protobuf.Duration{seconds: seconds}
        end,
      request_id: request_id()
    }

    Exec.start(channel, start, Keyword.get(opts, :owner, self()))
  end

  @doc """
  Unpacks the tar archive `tar` (an iodata or a file path as `{:file, path}`) into
  directory `dest` in sandbox `name`, over the same exec stream: `tar -x -C dest`
  with the archive on its stdin. `:ok` once tar exits 0.
  """
  def upload(%__MODULE__{} = conn, name, dest, tar, opts \\ []) do
    with {:ok, exec} <-
           exec(conn, name, ["tar", "-x", "--no-same-owner", "-C", dest, "-f", "-"], opts) do
      result =
        with :ok <- write_tar(exec, tar), :ok <- Exec.close_stdin(exec) do
          await_exit(exec, [], Keyword.get(opts, :upload_timeout, 600_000))
        end

      Exec.cancel(exec)
      result
    end
  end

  # A local file the MC itself chose to upload.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_tar(exec, {:file, path}) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Exec.send_stdin(exec, chunk) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write_tar(exec, iodata), do: Exec.send_stdin(exec, iodata)

  defp await_exit(exec, stderr, timeout) do
    receive do
      {:openshell_exec, ^exec, {:stdout, _}} ->
        await_exit(exec, stderr, timeout)

      {:openshell_exec, ^exec, {:stderr, data}} ->
        await_exit(
          exec,
          [stderr, data] |> IO.iodata_to_binary() |> binary_part_tail(4096),
          timeout
        )

      {:openshell_exec, ^exec, {:exit, 0}} ->
        :ok

      {:openshell_exec, ^exec, {:exit, code}} ->
        {:error, {:upload_failed, code, IO.iodata_to_binary(stderr)}}

      {:openshell_exec, ^exec, {:error, reason}} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp binary_part_tail(bin, max) when byte_size(bin) <= max, do: bin
  defp binary_part_tail(bin, max), do: binary_part(bin, byte_size(bin) - max, max)

  @doc """
  The parts of an `openshell.v1.Sandbox` the MC uses:
  `%{id, name, labels, phase, exit_code, workspace}`; `phase` is an atom such as
  `:ready`, `:provisioning`, `:error` or `:deleting`.
  """
  def sandbox(%Pb.Sandbox{metadata: meta, status: status}) do
    meta = meta || %HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta{}

    %{
      id: meta.id,
      name: meta.name,
      labels: meta.labels || %{},
      workspace: meta.workspace,
      phase: phase(status && status.phase),
      exit_code: status && status.exit_code
    }
  end

  @phases %{
    SANDBOX_PHASE_PROVISIONING: :provisioning,
    SANDBOX_PHASE_READY: :ready,
    SANDBOX_PHASE_ERROR: :error,
    SANDBOX_PHASE_DELETING: :deleting,
    SANDBOX_PHASE_STOPPING: :stopping,
    SANDBOX_PHASE_STOPPED: :stopped,
    SANDBOX_PHASE_STARTING: :starting,
    SANDBOX_PHASE_COMPLETED: :completed,
    SANDBOX_PHASE_SUSPENDING: :suspending,
    SANDBOX_PHASE_SUSPENDED: :suspended
  }

  defp phase(phase), do: Map.get(@phases, phase, :unknown)

  defp service_status(:SERVICE_STATUS_HEALTHY), do: :healthy
  defp service_status(:SERVICE_STATUS_DEGRADED), do: :degraded
  defp service_status(:SERVICE_STATUS_UNHEALTHY), do: :unhealthy
  defp service_status(_), do: :unspecified

  defp owned?(%{labels: labels}), do: labels[OpenShell.owner_label()] == OpenShell.owner()

  # The caller's labels with this MC's owner label, checked against what the
  # gateway would accept so a bad one fails here with its name.
  defp owned_labels(labels) do
    labels = Map.new(labels, fn {k, v} -> {to_string(k), to_string(v)} end)

    case Enum.find(labels, fn {k, v} -> not valid_label?(k, v) end) do
      nil ->
        if Map.has_key?(labels, OpenShell.owner_label()) and
             labels[OpenShell.owner_label()] != OpenShell.owner(),
           do: {:error, :owner_label_reserved},
           else: {:ok, Map.put(labels, OpenShell.owner_label(), OpenShell.owner())}

      {k, _} ->
        {:error, {:bad_label, k}}
    end
  end

  defp valid_label?(key, value) do
    name = key |> String.split("/") |> List.last()

    byte_size(key) <= 316 and byte_size(name) <= 63 and Regex.match?(@label_key, key) and
      Regex.match?(@label_value, value)
  end

  defp scope, do: %WorkspaceSelector{selection: {:workspace, OpenShell.workspace()}}

  # The gateway wants a hyphenated UUID; a random (v4) one.
  defp request_id do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.pad_leading(32, "0") |> String.downcase()
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  # One unary call: `{:ok, response}` or `{:error, %{status, message}}`, where
  # `status` is the gRPC status as an atom (`:not_found`, `:permission_denied`, ...).
  defp call(%__MODULE__{channel: channel}, rpc, request, opts) do
    case apply(Stub, rpc, [channel, request, [timeout: Keyword.get(opts, :timeout, @timeout)]]) do
      {:ok, response} -> {:ok, response}
      {:error, %GRPC.RPCError{} = error} -> {:error, rpc_error(error)}
      {:error, reason} -> {:error, %{status: :unavailable, message: inspect(reason)}}
    end
  catch
    :exit, reason -> {:error, %{status: :unavailable, message: inspect(reason)}}
  end

  @doc false
  def rpc_error(%GRPC.RPCError{status: status, message: message}),
    do: %{status: status_name(status), message: message}

  @statuses %{
    0 => :ok,
    1 => :cancelled,
    2 => :unknown,
    3 => :invalid_argument,
    4 => :deadline_exceeded,
    5 => :not_found,
    6 => :already_exists,
    7 => :permission_denied,
    8 => :resource_exhausted,
    9 => :failed_precondition,
    10 => :aborted,
    11 => :out_of_range,
    12 => :unimplemented,
    13 => :internal,
    14 => :unavailable,
    15 => :data_loss,
    16 => :unauthenticated
  }

  defp status_name(status), do: Map.get(@statuses, status, :unknown)
end
