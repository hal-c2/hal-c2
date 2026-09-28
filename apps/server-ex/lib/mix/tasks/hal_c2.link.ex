defmodule Mix.Tasks.HalC2.Link do
  @shortdoc "Links the running node to an environment outside its cluster"
  @moduledoc """
  Pairs the running node with another node it is not clustered with, so clients
  of this node reach that environment's threads and terminals through it
  (`HalC2.Links`):

      mix hal_c2.link PAIRING_URL            # pair and keep the link
      mix hal_c2.link                        # list the links
      mix hal_c2.link --remove ENVIRONMENT   # forget a link

  `PAIRING_URL` is a one-time pairing link from the other node, such as
  `mix hal_c2.pair` prints there. The node must be running; the task talks to it
  over its own socket with the node's access token.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, rest} = OptionParser.parse!(args, strict: [remove: :string])

    case {opts[:remove], rest} do
      {nil, []} ->
        case call("hal-c2.environmentLinks", %{}) do
          [] -> Mix.shell().info("No links.")
          links -> Enum.each(links, &Mix.shell().info(describe(&1)))
        end

      {nil, [url]} ->
        descriptor = call("hal-c2.linkEnvironment", %{"pairingUrl" => url})
        Mix.shell().info("Linked #{descriptor["label"]} (#{descriptor["environmentId"]})")

      {id, []} ->
        call("hal-c2.unlinkEnvironment", %{"environmentId" => id})
        Mix.shell().info("Removed the link to #{id}")

      _ ->
        Mix.raise("see `mix help hal_c2.link`")
    end
  end

  defp describe(link) do
    env = link["environment"]
    state = if link["online"], do: "online", else: "offline"
    "#{env["label"]}  #{env["environmentId"]}  #{link["origin"]}  #{state}"
  end

  # One RPC to the running node, as its own client.
  defp call(method, payload) do
    record =
      case File.read(HalC2.RuntimeRecord.path()) do
        {:ok, json} -> JSON.decode!(json)
        {:error, _} -> Mix.raise("no node is running here; start it with `mix hal_c2.server`")
      end

    token = File.read!(Path.join(HalC2.Paths.data_dir(), "access-token")) |> String.trim()
    uri = URI.parse(record["origin"])
    {:ok, conn} = Mint.HTTP.connect(:http, uri.host, uri.port, mode: :passive)
    path = "/ws?" <> URI.encode_query(%{"token" => token, "protocol" => 3})
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])
    {conn, responses} = recv_upgrade(conn, ref, [])
    status = Enum.find_value(responses, fn r -> match?({:status, _, _}, r) && elem(r, 2) end)

    headers =
      Enum.find_value(responses, [], fn r -> match?({:headers, _, _}, r) && elem(r, 2) end)

    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)

    frame = %{
      "t" => "rpc",
      "id" => 1,
      "environment" => HalC2.Environment.id(),
      "method" => method,
      "payload" => payload
    }

    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, JSON.encode!(frame)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    early = for {:data, ^ref, data} <- responses, into: "", do: data

    case recv_reply(conn, ref, ws, early) do
      %{"t" => "rpc.result", "result" => result} -> result
      %{"t" => "rpc.error", "error" => error} -> Mix.raise(error)
    end
  end

  defp recv_upgrade(conn, ref, acc) do
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 10_000)
    acc = acc ++ responses

    if Enum.any?(acc, &match?({:done, ^ref}, &1)),
      do: {conn, acc},
      else: recv_upgrade(conn, ref, acc)
  end

  # Linking waits on the other node, so the reply may take a while.
  defp recv_reply(conn, ref, ws, data) do
    {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)

    reply =
      Enum.find_value(frames, fn
        {:text, text} -> with(%{"id" => 1} = f <- JSON.decode!(text), do: f, else: (_ -> nil))
        _ -> nil
      end)

    if reply do
      reply
    else
      {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 60_000)
      recv_reply(conn, ref, ws, for({:data, ^ref, d} <- responses, into: "", do: d))
    end
  end
end
