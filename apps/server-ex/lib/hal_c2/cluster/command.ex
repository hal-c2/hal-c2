defmodule HalC2.Cluster.Command do
  @moduledoc """
  `mix hal_c2.cluster` and `bin/hal-c2-service cluster`: this machine's cluster, asked of
  its running MC over HTTP with the MC's own access token.

      status                           this machine and the other members
      invite [BASE_URL] [--tailscale]  a link another machine joins with (5 minutes, once)
      join LINK                        join the cluster of the machine the link is from
      remove MEMBER                    stop admitting a member (its id or label) anywhere

  The joining machine must reach the inviting MC's address: its LAN or tailnet
  address (`HAL_C2_MC_HOST`), or with `--tailscale` its Tailscale Serve name.
  """

  @doc "Runs a subcommand and prints its outcome; exits 1 on failure."
  def main(args) do
    case command(args) do
      {:ok, text} ->
        IO.puts(text)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc "A subcommand's outcome as `{:ok, text}` or `{:error, message}`."
  def command([]), do: command(["status"])

  def command(["status"]) do
    with {:ok, status} <- request(:get, "/api/cluster"), do: {:ok, format(status)}
  end

  def command(["invite" | args]) do
    {opts, rest} = OptionParser.parse!(args, strict: [tailscale: :boolean])
    input = %{"baseUrl" => List.first(rest), "tailscale" => opts[:tailscale] == true}

    with {:ok, %{"link" => link} = invite} <- request(:post, "/api/cluster/invite", input) do
      hint =
        if invite["localOnly"],
          do:
            "\nThis MC only listens on this machine; start it with HAL_C2_MC_HOST set to its LAN or tailnet address, or use --tailscale.",
          else: ""

      {:ok,
       "On the other machine, within 5 minutes:\n  hal-c2-service cluster join #{link}#{hint}"}
    end
  end

  def command(["join", link]) do
    with {:ok, status} <- request(:post, "/api/cluster/join", %{"link" => link}),
         do: {:ok, format(status)}
  end

  def command(["remove", member]) do
    with {:ok, %{"members" => members}} <- request(:get, "/api/cluster"),
         {:ok, id} <- find_member(members, member),
         {:ok, _} <- request(:post, "/api/cluster/remove", %{"id" => id}) do
      {:ok, "Removed #{member}; no member admits it any more."}
    end
  end

  def command(_args),
    do:
      {:error,
       "usage: cluster [status | invite [BASE_URL] [--tailscale] | join LINK | remove MEMBER]"}

  defp find_member(members, member) do
    case Enum.filter(members, &(member in [&1["id"], &1["label"]])) do
      [%{"id" => id}] -> {:ok, id}
      [] -> {:error, "No member is #{member}"}
      _ -> {:error, "More than one member is #{member}; use its id"}
    end
  end

  defp format(%{"clustered" => false, "reason" => reason}),
    do: "Not clustering: #{HalC2.Cluster.describe(reason)}"

  defp format(status) do
    me =
      "This machine: #{status["label"]} (#{status["id"]}) at #{Enum.join(status["addresses"], ", ")}"

    members =
      case status["members"] do
        [] ->
          ["No other members yet: run `invite` here and `join` on another machine."]

        members ->
          for m <- members do
            state = if m["connected"], do: "connected", else: "not connected"
            "  #{m["label"]} (#{m["id"]}): #{state}"
          end
      end

    Enum.join([me | members], "\n")
  end

  # --- the running MC ----------------------------------------------------------

  @doc "Asks this machine's running MC over HTTP: `{:ok, answer}` or `{:error, message}`."
  def request(method, path, body \\ nil, timeout \\ 30_000) do
    {:ok, _} = Application.ensure_all_started(:inets)

    with {:ok, token} <- token() do
      headers = [{~c"authorization", ~c"Bearer #{token}"}]
      url = to_charlist(origin() <> path)

      request =
        if method == :get,
          do: {url, headers},
          else: {url, headers, ~c"application/json", JSON.encode!(body)}

      case :httpc.request(method, request, [timeout: timeout], body_format: :binary) do
        {:ok, {{_, 200, _}, _, answer}} ->
          {:ok, JSON.decode!(answer)}

        {:ok, {{_, 409, _}, _, answer}} ->
          {:error, JSON.decode!(answer)["message"]}

        {:ok, {{_, status, _}, _, answer}} ->
          {:error, "The MC answered #{status}: #{answer}"}

        {:error, _} ->
          {:error, "No MC answers at #{origin()}; is it running?"}
      end
    end
  end

  defp token do
    case File.read(HalC2.Web.token_path()) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> {:error, "No MC has run from #{HalC2.Paths.data_dir()}"}
    end
  end

  # The running MC's own record of where it listens, else where it would.
  defp origin do
    with {:ok, json} <- File.read(HalC2.RuntimeRecord.path()),
         {:ok, %{"origin" => origin}} <- JSON.decode(json) do
      origin
    else
      _ -> HalC2.Web.base_url()
    end
  end
end
