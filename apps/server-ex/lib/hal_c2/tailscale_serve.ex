defmodule HalC2.TailscaleServe do
  @moduledoc """
  Publishes this MC over Tailscale Serve HTTPS for `pair --tailscale` (`HalC2.Pair`): the
  machine's MagicDNS name fronts the local listener, and tailscaled keeps the mapping
  across MC restarts.

  A mapping already on the HTTPS port is reused only when it is a loopback
  alias of the very listener being published (same port, another loopback
  host) answering with this environment's id, and never replaced otherwise.
  The id is public at the well-known endpoint, so it is a sanity check, not
  proof; the loopback-same-port shape is what the reuse trusts.

  The `tailscale` executable comes from `config :hal_c2, tailscale_command: [...]`.
  """

  @default_port 443

  def default_port, do: @default_port

  @doc """
  Maps HTTPS `serve_port` on the tailnet to `local_port`; `{:ok, base_url}` or
  `{:error, message}`. `expected_id` is the environment id of the MC being
  published, which an existing mapping to another address must answer with to
  be reused; nil means this process's own MC (`HalC2.Environment.id/0`). A
  caller publishing *another* MC (a cross-profile `pair`) must pass that MC's
  id: this process's identity is its own home's, not the published one's.
  `command_name` is the caller's CLI when it has one, named in the hint for a
  taken port; nil (an RPC caller) gets the hint without a CLI flag.
  """
  @spec publish(pos_integer, pos_integer, String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def publish(local_port, serve_port \\ @default_port, expected_id \\ nil, command_name \\ nil) do
    with {:ok, name} <- magic_dns_name(),
         :ok <-
           claim(name, serve_port, "http://127.0.0.1:#{local_port}", expected_id, command_name) do
      {:ok, base_url(name, serve_port)}
    else
      {:taken, message} -> {:error, message}
      error -> error
    end
  end

  @doc """
  As `publish/2` on the default port, or on HTTPS `local_port` when something else
  holds the default: for a caller with no port to ask its user for, so that two MCs
  on one machine are both reachable.
  """
  @spec publish_free(pos_integer) :: {:ok, String.t()} | {:error, String.t()}
  def publish_free(local_port) do
    target = "http://127.0.0.1:#{local_port}"

    with {:ok, name} <- magic_dns_name(),
         {:taken, _} <- claim(name, @default_port, target, nil, nil) do
      publish(local_port, local_port)
    else
      :ok -> publish(local_port)
      error -> error
    end
  end

  @doc "`https://<name>`, with the port unless it is 443."
  def base_url(name, @default_port), do: "https://#{name}"
  def base_url(name, port), do: "https://#{name}:#{port}"

  defp magic_dns_name do
    case run(["status", "--json"]) do
      {:ok, %{"Self" => %{"DNSName" => dns}}} when is_binary(dns) and dns not in ["", "."] ->
        {:ok, String.trim_trailing(dns, ".")}

      {:ok, _} ->
        {:error, "This machine has no MagicDNS name. Run `tailscale up` and enable MagicDNS."}

      :error ->
        {:error, "Could not talk to Tailscale. Is tailscaled running? Try `tailscale status`."}
    end
  end

  defp claim(name, port, target, expected_id, command_name) do
    case mapping(name, port) do
      nil -> serve(port, target)
      ^target -> :ok
      other -> check_existing(other, target, port, expected_id, command_name)
    end
  end

  @doc """
  The environment id an MC at `url` answers with at its well-known identity
  endpoint: a non-empty id, or nil when it answers with none (or not at all).
  The one probe behind every check of whose token a mapping or a link is
  minted for (`check_existing/5`, `HalC2.Pair`'s located id).
  """
  @spec environment_id_at(String.t() | nil) :: String.t() | nil
  def environment_id_at(url) when is_binary(url) do
    request = {String.to_charlist(url <> "/.well-known/hal-c2/environment"), []}

    with {:ok, {{_, 200, _}, _, body}} <-
           :httpc.request(:get, request, [timeout: 2_000], body_format: :binary),
         {:ok, %{"environmentId" => id}} when is_binary(id) and id != "" <- JSON.decode(body) do
      id
    else
      _ -> nil
    end
  end

  def environment_id_at(_url), do: nil

  # Another target on the port: fine only if it is this very listener reached
  # under another loopback host, answering with the published environment's
  # id. Anything else — a non-loopback target, another port, a forwarder — is
  # refused without trusting its self-reported id: that id is served
  # unauthenticated, so a match is a sanity check, not proof of whose mapping
  # it is. An expected id of "" (a located MC whose id could be neither read
  # nor asked for) matches nothing — notably not a target in the same degraded
  # state answering "": the mapping is refused, not blessed.
  defp check_existing(other, target, port, expected_id, command_name) do
    expected = expected_id || HalC2.Environment.id()

    cond do
      not loopback_alias?(other, target) ->
        {:taken,
         "Tailscale Serve on HTTPS port #{port} already fronts a different HAL-C2 server. #{port_hint(command_name)}"}

      expected == "" ->
        {:taken,
         "Tailscale Serve on HTTPS port #{port} already fronts a HAL-C2 server whose identity could not be verified as this one. #{port_hint(command_name)}"}

      true ->
        case environment_id_at(other) do
          ^expected ->
            :ok

          nil ->
            occupied(port, command_name)

          _ ->
            {:taken,
             "Tailscale Serve on HTTPS port #{port} already fronts a different HAL-C2 server. #{port_hint(command_name)}"}
        end
    end
  end

  defp loopback_alias?(other, target) do
    with %URI{host: host, port: port} when is_binary(host) <- URI.parse(other),
         %URI{port: ^port} <- URI.parse(target) do
      loopback_host?(host)
    else
      _ -> false
    end
  end

  defp loopback_host?("localhost"), do: true

  defp loopback_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  defp occupied(port, command_name),
    do:
      {:taken,
       "HTTPS port #{port} on the tailnet already serves something that is not a HAL-C2 server. #{port_hint(command_name)}"}

  defp port_hint(nil), do: "Publish this one on another Tailscale Serve port."

  defp port_hint(command_name),
    do: "Pass --tailscale-serve-port to `#{command_name}` to publish this one on another port."

  defp mapping(name, port) do
    case run(["serve", "status", "--json"]) do
      {:ok, %{"Web" => %{} = web}} -> get_in(web, ["#{name}:#{port}", "Handlers", "/", "Proxy"])
      _ -> nil
    end
  end

  defp serve(port, target) do
    case cmd(["serve", "--bg", "--https=#{port}", target]) do
      {_, 0} ->
        :ok

      {out, _} ->
        {:error,
         "tailscale serve failed for HTTPS port #{port}. Run `tailscale serve --https=#{port} --bg <local-url>` by hand to see why.\n" <>
           out}
    end
  end

  defp run(args) do
    case cmd(args, false) do
      {json, 0} ->
        case JSON.decode(json) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp cmd(args, stderr? \\ true) do
    [exe | pre] = Application.get_env(:hal_c2, :tailscale_command, ["tailscale"])
    System.cmd(exe, pre ++ args, stderr_to_stdout: stderr?)
  rescue
    e in ErlangError -> {Exception.message(e), 127}
  end
end
