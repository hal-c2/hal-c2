defmodule HalC2.AttachmentsPropTest do
  @moduledoc """
  A state machine over a thread's attachment claims (`HalC2.Attachments`): clients
  upload and discard files, messages claim the uploads they name into the thread
  (`claim/2`), and the MC then accepts each message or refuses it and gives its uploads
  back (`release/2`), in any order, with claims of other messages in between.

  The promise: a claim takes every upload a message names or none of them; a message
  holds copies of its own, so two messages naming one upload never share a file; a
  refused message's copies are gone and its uploads can be sent again; and the copies an
  accepted or undecided message names are never lost, overwritten or left over.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Attachments

  @moduletag timeout: :infinity

  @thread "t"
  @uploads 1..3
  # An id no client was ever given an upload for.
  @never "pending-00000000-0000-0000-0000-000000000000"

  property "claims take all or nothing, and a release gives back only its own copies",
    numtests: HalC2.Prop.numtests(200),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      HalC2.Prop.scratch_home("attachments")
      :persistent_term.erase({Attachments, :secret})
      Process.put(:attachments, %{})
      {history, state, result} = run_commands(__MODULE__, cmds)

      (result == :ok)
      |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
      |> aggregate(command_names(cmds))
    end
  end

  # Which uploads are pending, and each message by number: what it named and where it is.
  def initial_state, do: %{pending: MapSet.new(), messages: %{}, next: 1}

  def command(state) do
    sent = for {m, %{phase: :sent}} <- state.messages, do: m
    undecided = for {m, %{phase: :claimed}} <- state.messages, do: m

    name =
      if sent == [],
        do: {:upload, oneof(Enum.to_list(@uploads))},
        else: oneof([{:upload, oneof(Enum.to_list(@uploads))}, {:copy, oneof(sent)}])

    frequency(
      [
        {3, {:call, __MODULE__, :upload, [oneof(Enum.to_list(@uploads))]}},
        {1, {:call, __MODULE__, :discard, [oneof(Enum.to_list(@uploads))]}},
        {5, {:call, __MODULE__, :claim, [state.next, resize(3, non_empty(list(name)))]}}
      ] ++
        if(undecided == [],
          do: [],
          else: [{5, {:call, __MODULE__, :decide, [oneof(undecided), oneof([:accept, :refuse])]}}]
        )
    )
  end

  def precondition(state, {:call, _, :claim, [m, names]}) do
    m == state.next and
      Enum.all?(names, fn
        {:upload, _} -> true
        {:copy, from} -> match?(%{phase: :sent}, state.messages[from])
      end)
  end

  def precondition(state, {:call, _, :upload, [u]}), do: not MapSet.member?(state.pending, u)

  def precondition(state, {:call, _, :decide, [m, _]}),
    do: match?(%{phase: :claimed}, state.messages[m])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :upload, [u]}),
    do: %{state | pending: MapSet.put(state.pending, u)}

  def next_state(state, _result, {:call, _, :discard, [u]}),
    do: %{state | pending: MapSet.delete(state.pending, u)}

  def next_state(state, _result, {:call, _, :claim, [m, names]}) do
    phase = if claimable?(state, names), do: :claimed, else: :failed
    %{state | messages: Map.put(state.messages, m, %{phase: phase}), next: m + 1}
  end

  def next_state(state, _result, {:call, _, :decide, [m, outcome]}) do
    phase = if outcome == :accept, do: :sent, else: :refused
    %{state | messages: Map.put(state.messages, m, %{phase: phase})}
  end

  def postcondition(state, {:call, _, :claim, [_, names]} = call, result) do
    result == if(claimable?(state, names), do: :ok, else: :error) and
      holds(next_state(state, result, call))
  end

  def postcondition(state, call, result),
    do: result == :ok and holds(next_state(state, result, call))

  defp claimable?(state, names) do
    Enum.all?(names, fn
      {:upload, u} -> MapSet.member?(state.pending, u)
      {:copy, _} -> true
    end)
  end

  # --- the real calls ---------------------------------------------------------------

  def upload(u) do
    bytes = :crypto.strong_rand_bytes(16 + u)

    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      Attachments.create_upload_url(%{
        "name" => "#{u}.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(bytes)
      })

    :ok = Attachments.store(token, bytes)
    attachment = %{"type" => "image", "id" => id, "name" => "#{u}.png", "sizeBytes" => 16 + u}
    update(&(&1 |> Map.put({:upload, u}, attachment) |> Map.put({:bytes, id}, bytes)))
  end

  def discard(u) do
    case get({:upload, u}) do
      nil -> :ok
      %{"id" => id} -> {:ok, nil} = Attachments.delete(%{"attachmentId" => id})
    end

    update(&Map.delete(&1, {:upload, u}))
  end

  def claim(m, names) do
    attachments = Enum.map(names, &attachment/1)

    case Attachments.claim(@thread, attachments) do
      {:ok, claimed} ->
        update(&Map.put(&1, {:message, m}, {attachments, claimed}))

      {:error, _} ->
        :error
    end
  end

  def decide(m, :accept) when is_integer(m), do: :ok

  def decide(m, :refuse) do
    {attachments, claimed} = get({:message, m})
    Attachments.release(attachments, claimed)
  end

  defp attachment({:upload, u}),
    do: get({:upload, u}) || %{"type" => "image", "id" => @never, "name" => "#{u}.png"}

  defp attachment({:copy, m}) do
    {_, [first | _]} = get({:message, m})
    first
  end

  defp get(key), do: Map.get(Process.get(:attachments), key)

  defp update(fun) do
    Process.put(:attachments, fun.(Process.get(:attachments)))
    :ok
  end

  # --- what must hold after every step ------------------------------------------------

  defp holds(state) do
    held =
      for {m, %{phase: phase}} <- state.messages, phase in [:claimed, :sent, :refused] do
        {attachments, claimed} = get({:message, m})

        # What this claim made: copies under a new id, of the bytes their upload had.
        copies =
          for {%{"id" => from}, %{"id" => id}} <- Enum.zip(attachments, claimed),
              from != id,
              do: {id, get({:bytes, from})}

        {phase, copies, claimed}
      end

    kept = for {phase, copies, _} <- held, phase != :refused, copy <- copies, do: copy
    given_back = for {:refused, copies, _} <- held, {id, _} <- copies, do: id
    named = for {phase, _, claimed} <- held, phase != :refused, a <- claimed, do: a

    pending =
      for u <- state.pending,
          do: {get({:upload, u})["id"], get({:bytes, get({:upload, u})["id"]})}

    files = Path.wildcard(Path.join(Attachments.dir(), "*"))
    ids = Enum.map(kept, &elem(&1, 0))

    # Every copy an accepted or undecided message made, and every pending upload, is on
    # disk as it was stored; every file a message names exists; a refused message's
    # copies are gone; no two messages share a copy; and nothing else is left.
    Enum.all?(kept ++ pending, fn {id, bytes} ->
      File.read(Attachments.path(%{"id" => id}) || "") == {:ok, bytes}
    end) and
      Enum.all?(named, &Attachments.path/1) and
      Enum.all?(given_back, &(Attachments.path(%{"id" => &1}) == nil)) and
      length(Enum.uniq(ids)) == length(ids) and
      length(files) == length(kept) + length(pending)
  end
end
