defmodule HalC2.PreviewForward do
  @moduledoc """
  Dev servers on another MC, reached from this machine's browser
  (`preview.forward`), like `ssh -L`. A thread's browser tab names
  `http://localhost:<port>`, which means the machine the thread runs on; when
  that is another cluster MC, this MC listens on its own loopback at the same
  port (another free one when that is taken) and carries each connection's
  bytes to the thread's MC, which dials its own `localhost:<port>`. Being TCP,
  websockets, HMR and server-sent events pass as they are, and the page keeps
  its `localhost` origin.

  One process per forward on each MC, and one per connection on each:

    * `Listener`, on the client's MC: owns the loopback sockets, one per
      `{mc, thread, port}` (the registry dedups them).
    * `Grant`, on the thread's MC: the permission. It exists only while one of
      the thread's tabs names a loopback URL at the port, never for that MC's
      own web or cluster ports, and stops when the last such tab closes.
    * A `Pipe` pair per accepted connection, one on each MC, each owning one
      socket. Bytes ride distribution in chunks of at most 64 KiB, each acked,
      with a few unacked at a time, so one busy page cannot hog the cluster link.

  Each half monitors the other (listener and grant, pipe and pipe), so a
  closed tab, a closed socket, a crash or a lost MC closes both ends and every
  open connection.

  Listeners and grants have supervisors of their own: a listener starts by
  asking the other MC for its grant, and two MCs forwarding to each other at
  once must not each wait on a supervisor the other's ask holds.
  """

  alias HalC2.PreviewForward.{Grant, Listener}

  @registry HalC2.PreviewForward.Registry
  @listeners HalC2.PreviewForward.Listeners
  @grants HalC2.PreviewForward.Grants

  def child_spec(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @grants, strategy: :one_for_one},
      {DynamicSupervisor, name: @listeners, strategy: :one_for_one}
    ]

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one, name: __MODULE__]]}
    }
  end

  @messages %{
    invalid: "an environmentId, a threadId and a port are required",
    unknown_environment: "no MC in the cluster serves that environment",
    unavailable: "the thread's MC did not answer",
    reserved: "that port is the MC's own and is never forwarded",
    not_open: "none of the thread's browser tabs is open at that port",
    closed: "the forward closed while it was asked for"
  }

  @doc """
  `preview.forward`: the port this machine's `localhost` reaches a dev server
  of the thread's MC at. The same port for a thread of this MC, which nothing
  is forwarded for; else one this MC forwards to the thread's MC.
  """
  def request(%{"environmentId" => environment, "threadId" => thread, "port" => port})
      when is_binary(environment) and is_binary(thread) and is_integer(port) and
             port in 1..65_535 do
    reply =
      case HalC2.Shell.mc_for(environment) do
        nil -> {:error, :unknown_environment}
        mc when mc == node() -> {:ok, port}
        mc -> forward(mc, thread, port)
      end

    case reply do
      {:ok, local} -> {:ok, %{"port" => local}}
      {:error, reason} -> error(reason)
    end
  end

  def request(_input), do: error(:invalid)

  defp error(reason) do
    {:error,
     %{
       "_tag" => "PreviewForwardError",
       "reason" => if(is_map_key(@messages, reason), do: to_string(reason), else: "failed"),
       "message" => Map.get(@messages, reason, "the port could not be forwarded")
     }}
  end

  @doc """
  Forwards `port` of `mc` for `thread`'s tabs, and gives the port this MC
  listens on. A second ask for the same forward gets the same port.
  """
  @spec forward(node, String.t(), :inet.port_number()) ::
          {:ok, :inet.port_number()} | {:error, term}
  def forward(mc, thread, port, retries \\ 1) do
    key = {mc, thread, port}
    name = {:via, Registry, {@registry, key}}

    case DynamicSupervisor.start_child(@listeners, {Listener, {key, name}}) do
      {:ok, pid} ->
        Listener.port(pid)

      {:error, {:already_started, pid}} ->
        # One that is stopping right now answers nothing: ask for a fresh one.
        case Listener.port(pid) do
          {:error, :closed} when retries > 0 -> forward(mc, thread, port, retries - 1)
          reply -> reply
        end

      {:error, {:shutdown, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The forwards this MC listens for, as `{{mc, thread, port}, listening_port}`."
  @spec listening() :: [{{node, String.t(), :inet.port_number()}, :inet.port_number()}]
  def listening do
    for {key, pid} <- Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]),
        {:ok, port} <- [Listener.port(pid)],
        do: {key, port}
  end

  @doc false
  # Called on the thread's MC by a listener: the permission for `owner` to
  # reach `port` while one of `thread`'s tabs names it.
  def grant(thread, port, owner) do
    case DynamicSupervisor.start_child(@grants, {Grant, {thread, port, owner}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Called on the thread's MC by a connection's pipe: the pipe that dials the
  # dev server and carries its bytes back to `peer`.
  def dial(grant, peer) do
    GenServer.call(grant, {:dial, peer})
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Whether `url` names a loopback host at `port` (scheme default included)."
  @spec loopback?(String.t() | nil, :inet.port_number()) :: boolean
  def loopback?(url, port) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: ^port} when scheme in ["http", "https"] ->
        loopback_host?(host)

      _ ->
        false
    end
  end

  def loopback?(_url, _port), do: false

  defp loopback_host?("localhost"), do: true
  defp loopback_host?("::1"), do: true
  defp loopback_host?("127." <> _), do: true
  defp loopback_host?(_), do: false
end
