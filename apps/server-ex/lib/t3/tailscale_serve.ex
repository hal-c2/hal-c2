defmodule T3.TailscaleServe do
  @moduledoc """
  Publishes this node over Tailscale Serve HTTPS for `mix t3.pair --tailscale`, as
  the Node server's `t3 pair --tailscale` does: the machine's MagicDNS name fronts
  the local listener, and tailscaled keeps the mapping across node restarts.

  A mapping already on the HTTPS port is reused when it reaches this environment
  and never replaced otherwise. The Node server probes the HTTPS URL; this probes
  the mapping's local target, which answers without waiting for a certificate.

  The `tailscale` executable comes from `config :t3, tailscale_command: [...]`.
  """

  @default_port 443

  def default_port, do: @default_port

  @doc "Maps HTTPS `serve_port` on the tailnet to `local_port`; `{:ok, base_url}` or `{:error, message}`."
  @spec publish(pos_integer, pos_integer) :: {:ok, String.t()} | {:error, String.t()}
  def publish(local_port, serve_port \\ @default_port) do
    with {:ok, name} <- magic_dns_name(),
         :ok <- claim(name, serve_port, "http://127.0.0.1:#{local_port}") do
      {:ok, base_url(name, serve_port)}
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

  defp claim(name, port, target) do
    case mapping(name, port) do
      nil -> serve(port, target)
      ^target -> :ok
      other -> check_existing(other, port)
    end
  end

  # Another target on the port: fine only if it is this environment.
  defp check_existing(target, port) do
    request = {String.to_charlist(target <> "/.well-known/t3/environment"), []}

    case :httpc.request(:get, request, [timeout: 2_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case JSON.decode(body) do
          {:ok, %{"environmentId" => id}} ->
            if id == T3.Environment.id(),
              do: :ok,
              else:
                {:error,
                 "Tailscale Serve on HTTPS port #{port} already fronts a different T3 Code server. Pass --tailscale-serve-port to publish this one on another port."}

          _ ->
            occupied(port)
        end

      _ ->
        occupied(port)
    end
  end

  defp occupied(port),
    do:
      {:error,
       "HTTPS port #{port} on the tailnet already serves something that is not a T3 Code server. Pass --tailscale-serve-port to publish this one on another port."}

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
    [exe | pre] = Application.get_env(:t3, :tailscale_command, ["tailscale"])
    System.cmd(exe, pre ++ args, stderr_to_stdout: stderr?)
  rescue
    e in ErlangError -> {Exception.message(e), 127}
  end
end
