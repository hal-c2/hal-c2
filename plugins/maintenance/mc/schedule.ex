defmodule HalC2Plugins.Maintenance.Schedule do
  @moduledoc """
  When maintenance runs on its own: every day, or one day a week, at a time of day in
  the MC's local time. Times are `NaiveDateTime`s in that local time, so a run keeps
  its hour across daylight saving changes.

  A slot is one moment a run is due. The server keeps, per repository, the last slot
  it handled; a later `last_slot/2` than that is a run due. That is also how a slot
  missed while the MC was down runs once when it starts again, and only once.
  """

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)
  @schedules ~w(manual daily weekly)

  def weekdays, do: @weekdays
  def schedules, do: @schedules

  @doc "Whether `text` is a time of day as `HH:MM`."
  def time?(text) when is_binary(text), do: match?({:ok, _}, parse_time(text))
  def time?(_text), do: false

  @doc """
  The latest slot at or before `now`, or nil when runs start only when asked for (or
  the settings name no valid time).
  """
  def last_slot(settings, %NaiveDateTime{} = now) do
    with {:ok, time} <- parse_time(settings["time"]),
         {:ok, days} <- period(settings) do
      today = NaiveDateTime.to_date(now)

      first =
        case days do
          1 ->
            today

          7 ->
            target = Enum.find_index(@weekdays, &(&1 == settings["weekday"])) + 1
            Date.add(today, -Integer.mod(Date.day_of_week(today) - target, 7))
        end

      candidate = NaiveDateTime.new!(first, time)

      if NaiveDateTime.compare(candidate, now) == :gt,
        do: NaiveDateTime.add(candidate, -days * 86_400),
        else: candidate
    else
      _ -> nil
    end
  end

  @doc "The first slot after `now`, or nil when runs start only when asked for."
  def next_slot(settings, %NaiveDateTime{} = now) do
    with %NaiveDateTime{} = last <- last_slot(settings, now),
         {:ok, days} <- period(settings),
         do: NaiveDateTime.add(last, days * 86_400)
  end

  @doc """
  Whether a run is due at `now` for a repository whose last handled slot is `handled`
  (an ISO 8601 local time, or nil for one the server has not seen yet, which waits
  for its first slot rather than running at once).
  """
  def due?(settings, handled, now) do
    case {last_slot(settings, now), handled} do
      {nil, _} -> false
      {_slot, nil} -> false
      {slot, handled} -> NaiveDateTime.compare(slot, NaiveDateTime.from_iso8601!(handled)) == :gt
    end
  end

  @doc """
  Which of `repositories` start at `now`, and the slots handled after: a repository
  seen for the first time takes the latest slot as handled, so adding one or
  changing the schedule does not start a run at once. A due repository that `held?`
  lets its slot pass; beyond `room` (the runs at once not yet going or starting), a
  due one keeps its slot due and starts on a later plan.
  """
  def plan(settings, repositories, slots, now, held?, room) do
    slot = last_slot(settings, now)
    stamp = slot && NaiveDateTime.to_iso8601(slot)

    {due, planned} =
      Enum.reduce(repositories, {[], Map.take(slots, repositories)}, fn repository,
                                                                        {due, planned} ->
        cond do
          slot == nil ->
            {due, planned}

          not Map.has_key?(planned, repository) ->
            {due, Map.put(planned, repository, stamp)}

          due?(settings, planned[repository], now) ->
            {[repository | due], Map.put(planned, repository, stamp)}

          true ->
            {due, planned}
        end
      end)

    {starting, waiting} = due |> Enum.reverse() |> Enum.reject(held?) |> Enum.split(max(room, 0))
    {starting, Enum.reduce(waiting, planned, &Map.put(&2, &1, slots[&1]))}
  end

  defp period(%{"schedule" => "daily"}), do: {:ok, 1}

  defp period(%{"schedule" => "weekly", "weekday" => weekday}) when weekday in @weekdays,
    do: {:ok, 7}

  defp period(_settings), do: :manual

  defp parse_time(text) when is_binary(text) do
    with [_, hours, minutes] <- Regex.run(~r/^\s*(\d{1,2}):(\d{2})\s*$/, text),
         {:ok, time} <- Time.new(String.to_integer(hours), String.to_integer(minutes), 0),
         do: {:ok, time},
         else: (_ -> :error)
  end

  defp parse_time(_text), do: :error
end
