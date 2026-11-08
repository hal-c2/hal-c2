defmodule HalC2.Preview do
  @moduledoc """
  The desktop's in-app browser tabs, per thread (`preview.*`). The desktop owns
  the actual webview and reports navigation here; the MC keeps each tab's
  snapshot so it survives reconnects and reaches every window. Tabs live in
  memory: `serverEpoch` changes on restart and `revision` orders every change.
  Clients normalize URLs (`normalizePreviewUrl`) before sending them.

  Watchers (client sockets) get `{:hal_c2_preview, mc, PreviewEvent}`.
  """

  use GenServer

  @fill %{"_tag" => "fill"}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def open(input) do
    with :ok <- validate_url(input["url"]),
         :ok <- validate_viewport(input["viewport"]),
         do: GenServer.call(__MODULE__, {:open, input})
  end

  def navigate(input) do
    with :ok <- validate_url(input["url"]),
         :ok <- validate_title(input["resolvedTitle"]),
         do: GenServer.call(__MODULE__, {:navigate, input})
  end

  def report_status(input), do: GenServer.call(__MODULE__, {:report_status, input})

  def resize(input) do
    with :ok <- validate_viewport(input["viewport"]),
         do: GenServer.call(__MODULE__, {:resize, input})
  end

  def refresh(input), do: GenServer.call(__MODULE__, {:refresh, input})
  def close(input), do: GenServer.call(__MODULE__, {:close, input})

  @doc "Closes the tabs of a deleted thread; nothing when the service is not running."
  def close_thread(thread_id) do
    if Process.whereis(__MODULE__), do: close(%{"threadId" => thread_id})
    :ok
  end

  def list(input), do: GenServer.call(__MODULE__, {:list, input})
  def subscribe(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:subscribe, pid, ref})
  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

  @impl true
  def init(nil),
    do:
      {:ok,
       %{epoch: HalC2.Environment.uuid4(), revision: 0, sessions: %{}, watchers: %{}, left: %{}}}

  @impl true
  def handle_call({:open, input}, _from, state) do
    tab = "tab-" <> HalC2.Environment.uuid4()
    at = now()

    snapshot =
      %{
        "threadId" => input["threadId"],
        "tabId" => tab,
        "navStatus" =>
          if(input["url"],
            do: %{"_tag" => "Loading", "url" => input["url"], "title" => ""},
            else: %{"_tag" => "Idle"}
          ),
        "canGoBack" => false,
        "canGoForward" => false,
        "viewport" => input["viewport"] || @fill,
        "updatedAt" => at
      }
      |> then(&if(input["profileId"], do: Map.put(&1, "profileId", input["profileId"]), else: &1))

    state = put(state, snapshot) |> emit(snapshot, "opened", %{"snapshot" => snapshot})
    {:reply, {:ok, snapshot}, state}
  end

  def handle_call({:navigate, input}, _from, state) do
    with_session(state, input, fn snapshot ->
      title =
        input["resolvedTitle"] ||
          if(snapshot["navStatus"]["_tag"] == "Idle",
            do: "",
            else: snapshot["navStatus"]["title"]
          )

      next =
        Map.merge(snapshot, %{
          "navStatus" => %{"_tag" => "Success", "url" => input["url"], "title" => title},
          "updatedAt" => now()
        })

      # The MC's own navigation starts afresh: nothing it left is late any more.
      {next, {"navigated", %{"snapshot" => next}}, next, nil}
    end)
  end

  # A report for the page a failed navigation left is late: it must not turn the
  # failure back into a success (upstream #27537).
  def handle_call({:report_status, input}, _from, state) do
    key = {input["threadId"], input["tabId"]}

    with_session(state, input, fn snapshot ->
      current = snapshot["navStatus"]
      incoming = input["navStatus"]

      if late?(current, incoming, state.left[key]) do
        {snapshot, nil, nil}
      else
        next =
          snapshot
          |> Map.merge(Map.take(input, ~w(navStatus canGoBack canGoForward)))
          |> Map.put("updatedAt", now())

        event =
          case incoming do
            %{"_tag" => "LoadFailed"} = failed ->
              {"failed", Map.take(failed, ~w(url title code description))}

            _ ->
              {"navigated", %{"snapshot" => next}}
          end

        {next, event, nil, left(current, incoming, state.left[key])}
      end
    end)
  end

  def handle_call({:resize, input}, _from, state) do
    with_session(state, input, fn snapshot ->
      next = Map.merge(snapshot, %{"viewport" => input["viewport"], "updatedAt" => now()})
      {next, {"resized", %{"snapshot" => next}}, next}
    end)
  end

  # The desktop reloads the page and reports how it went.
  def handle_call({:refresh, input}, _from, state),
    do: with_session(state, input, fn snapshot -> {snapshot, nil, nil} end)

  def handle_call({:close, %{"threadId" => thread} = input}, _from, state) do
    closing =
      for {{^thread, tab}, snapshot} <- state.sessions,
          input["tabId"] in [nil, tab],
          do: snapshot

    state =
      Enum.reduce(closing, state, fn snapshot, state ->
        %{
          state
          | sessions: Map.delete(state.sessions, {thread, snapshot["tabId"]}),
            left: Map.delete(state.left, {thread, snapshot["tabId"]})
        }
        |> emit(snapshot, "closed", %{})
      end)

    {:reply, {:ok, nil}, state}
  end

  def handle_call({:list, %{"threadId" => thread}}, _from, state) do
    sessions =
      for({{^thread, _}, snapshot} <- state.sessions, do: snapshot)
      |> Enum.sort_by(& &1["updatedAt"])

    {:reply,
     {:ok, %{"sessions" => sessions, "serverEpoch" => state.epoch, "revision" => state.revision}},
     state}
  end

  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, :ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  # The limits of `packages/contracts/src/preview.ts`. Errors describe the input
  # (its length, what was wrong) and never repeat it: an address can carry credentials.
  @url_max 2_048
  @title_max 512
  @dimension_min 240
  @dimension_max 3_840
  @area_max 3_840 * 2_160

  # Lengths count UTF-16 code units, as the contract's `isMaxLength` and Qt's
  # `QString::length` do, so every client and the MC agree on what is too long.
  defp units(string), do: div(byte_size(:unicode.characters_to_binary(string, :utf8, :utf16)), 2)

  defp validate_url(nil), do: :ok

  defp validate_url(url) when is_binary(url) do
    cond do
      String.trim(url) == "" -> invalid_url(url, "empty")
      units(url) > @url_max -> invalid_url(url, "too-long")
      true -> validate_scheme(url)
    end
  end

  defp validate_scheme(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme not in ["http", "https"] ->
        invalid_url(url, "unsupported-protocol", scheme <> ":")

      _ ->
        invalid_url(url, "parse")
    end
  end

  defp invalid_url(url, reason, protocol \\ nil) do
    error = %{
      "_tag" => "PreviewInvalidUrlError",
      "inputLength" => units(url),
      "reason" => reason,
      "cause" => nil
    }

    {:error, if(protocol, do: Map.put(error, "protocol", protocol), else: error)}
  end

  defp validate_title(title) when is_binary(title) and byte_size(title) > 0 do
    if units(title) > @title_max,
      do: {:error, invalid_input("title", "longer than #{@title_max} characters")},
      else: :ok
  end

  defp validate_title(_), do: :ok

  defp validate_viewport(%{"width" => w, "height" => h}) when is_integer(w) and is_integer(h) do
    cond do
      Enum.any?([w, h], &(&1 < @dimension_min or &1 > @dimension_max)) ->
        {:error,
         invalid_input("viewport", "each side must be #{@dimension_min} to #{@dimension_max}")}

      w * h > @area_max ->
        {:error, invalid_input("viewport", "area must not exceed #{@area_max} pixels")}

      true ->
        :ok
    end
  end

  defp validate_viewport(_), do: :ok

  defp invalid_input(field, reason),
    do: %{"_tag" => "PreviewInvalidInputError", "field" => field, "reason" => reason}

  # Applies `fun` to the tab's snapshot: `{next, event | nil, reply}`.
  defp with_session(state, %{"threadId" => thread, "tabId" => tab}, fun) do
    case state.sessions[{thread, tab}] do
      nil ->
        {:reply,
         {:error, %{"_tag" => "PreviewSessionLookupError", "threadId" => thread, "tabId" => tab}},
         state}

      snapshot ->
        {next, event, reply, left} =
          case fun.(snapshot) do
            {next, event, reply} -> {next, event, reply, :keep}
            {_, _, _, _} = result -> result
          end

        state = put(state, next)

        state =
          case left do
            :keep -> state
            nil -> %{state | left: Map.delete(state.left, {thread, tab})}
            left -> %{state | left: Map.put(state.left, {thread, tab}, left)}
          end

        state =
          case event do
            nil -> state
            {type, fields} -> emit(state, next, type, fields)
          end

        {:reply, {:ok, reply}, state}
    end
  end

  # Late while the failure stands, or while its page is retried (`Loading`). Plain
  # `Loading` only counts when a failure armed the guard: a page that redirects back
  # to the one it left (`/logout` to `/`) reports that page for real.
  defp late?(%{"_tag" => "LoadFailed"}, %{"_tag" => "Success", "url" => url}, {url, _}),
    do: true

  defp late?(%{"_tag" => "Loading"}, %{"_tag" => "Success", "url" => url}, {url, true}),
    do: true

  defp late?(_, _, _), do: false

  # The page a navigation left, with whether a failure armed the guard: a late report
  # for it must not undo that failure. Unchanged while reports stay on the same page.
  # A new navigation starting after a failure ends the lateness: going back to the page
  # it left reports that page as new.
  # A retry of the failed page itself keeps the guard.
  defp left(%{"_tag" => "LoadFailed", "url" => failed}, %{"_tag" => "Loading", "url" => to}, _)
       when failed != to,
       do: nil

  defp left(%{"url" => from}, %{"_tag" => "LoadFailed", "url" => to}, _) when from != to,
    do: {from, true}

  defp left(_, %{"_tag" => "LoadFailed"}, {from, _}), do: {from, true}
  defp left(%{"url" => from}, %{"url" => to}, _) when from != to, do: {from, false}
  defp left(_, _, _), do: :keep

  defp put(state, snapshot),
    do: %{
      state
      | sessions: Map.put(state.sessions, {snapshot["threadId"], snapshot["tabId"]}, snapshot)
    }

  defp emit(state, snapshot, type, fields) do
    revision = state.revision + 1

    event =
      Map.merge(fields, %{
        "type" => type,
        "threadId" => snapshot["threadId"],
        "tabId" => snapshot["tabId"],
        "createdAt" => now(),
        "serverEpoch" => state.epoch,
        "revision" => revision
      })

    HalC2.Watchers.notify(state.watchers, {:hal_c2_preview, node(), event})
    %{state | revision: revision}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
