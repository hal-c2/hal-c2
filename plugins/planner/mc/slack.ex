defmodule HalC2Plugins.Planner.Slack do
  @moduledoc """
  What the planner says in Slack and what a slash command asks of it, as plain
  functions: a status update's message, the announcement of a proposal waiting for
  the user, the plan's standing for `/planner status`, and which action a command
  names. Posting is the planner's, through `HalC2.Plugins.Host.slack/3`.
  """

  @health %{
    "on-track" => {":large_green_circle:", "On track"},
    "at-risk" => {":large_yellow_circle:", "At risk"},
    "off-track" => {":red_circle:", "Off track"}
  }

  @doc "An update's message: its health as a mark and a word, then its text."
  def update(%{"health" => health, "text" => text}) do
    {mark, word} = @health[health] || {"", "Update"}
    String.trim("#{mark} *#{word}*: #{text}")
  end

  @doc "The announcement of `run`'s proposal; `titles` are the tasks its changes touch."
  def announce(run, titles) do
    count = Enum.count(run["changes"] || [], &(not &1["dismissed"]))
    noun = if count == 1, do: "change", else: "changes"
    about = if titles == [], do: "", else: ": #{Enum.join(titles, ", ")}"
    "#{run["label"]} has #{count} #{noun} waiting in HAL-C2#{about}"
  end

  @doc """
  How the plan stands, for the slash command: the late tasks, those in progress and
  the latest update. `items` are derived (`Plan.derive/2`), `updates` newest first.
  """
  def status(items, updates) do
    late = Enum.filter(items, & &1["late"])
    doing = Enum.filter(items, &(&1["status"] == "doing" and not &1["late"]))

    [
      if(late == [],
        do: "Late: nothing.",
        else: "Late: " <> Enum.map_join(late, ", ", &"#{&1["title"]} (due #{&1["due"]})")
      ),
      if(doing == [],
        do: "In progress: nothing.",
        else:
          "In progress: " <>
            Enum.map_join(doing, ", ", &"#{&1["title"]} (#{&1["derivedProgress"]}% done)")
      ),
      case updates do
        [latest | _] -> "Health: " <> update(latest)
        [] -> "Health: no status update yet."
      end
    ]
    |> Enum.join("\n")
  end

  @doc """
  What the text after the slash command asks for: `:status` (nothing, or "status"),
  `{:run, action, rest}` when its first word is an action's id or the first word of
  its label, or `{:unknown, word}`. `actions` are `%{"id", "label", ...}`.
  """
  def command(text, actions) do
    case String.split(String.trim(text || ""), ~r/\s+/, parts: 2) do
      [word | _] when word in ["", "status"] ->
        :status

      [word | rest] ->
        word = String.downcase(word)

        named =
          Enum.find(actions, &(String.downcase(&1["id"]) == word)) ||
            Enum.find(actions, &(first_word(&1["label"]) == word))

        if named, do: {:run, named, String.trim(Enum.join(rest, " "))}, else: {:unknown, word}
    end
  end

  @doc "The answer to a command naming no action: what can be run."
  def actions(word, actions, command) do
    listed = Enum.map_join(actions, "\n", &"#{command} #{&1["id"]} — #{&1["label"]}")

    "There is no action #{word}. #{command} status shows how the plan stands; the actions are:\n#{listed}"
  end

  defp first_word(label),
    do: label |> String.split(~r/\s+/, parts: 2) |> hd() |> String.downcase()
end
