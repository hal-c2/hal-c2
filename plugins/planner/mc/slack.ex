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
  only one action's label, `{:ambiguous, word, actions}` when it begins several labels,
  or `{:unknown, word}`. `actions` are `%{"id", "label", ...}`.

  "status" and "run" are the command's own words, so an action whose id or label
  begins with one is reached by `run <id>`, which takes only an id. The answers below
  name actions that way.
  """
  def command(text, actions) do
    case words(text) do
      [word, _] when word in ["", "status"] ->
        :status

      ["run", rest] ->
        [id, rest] = words(rest)

        case by_id(actions, id) do
          nil -> {:unknown, id}
          named -> {:run, named, rest}
        end

      [word, rest] ->
        labelled = Enum.filter(actions, &(first_word(&1["label"]) == word))

        case {by_id(actions, word), labelled} do
          {%{} = named, _} -> {:run, named, rest}
          {nil, [named]} -> {:run, named, rest}
          {nil, []} -> {:unknown, word}
          {nil, several} -> {:ambiguous, word, several}
        end
    end
  end

  # The first word of `text`, lowercased, and the rest.
  defp words(text) do
    case String.split(String.trim(text || ""), ~r/\s+/, parts: 2) do
      [word, rest] -> [String.downcase(word), rest]
      [word] -> [String.downcase(word), ""]
    end
  end

  defp by_id(actions, id), do: Enum.find(actions, &(String.downcase(&1["id"]) == id))

  @doc "The answer to a command naming no action: what can be run."
  def actions(word, actions, command) do
    missing = if word == "", do: "Name the action to run.", else: "There is no action #{word}."

    "#{missing} #{command} status shows how the plan stands; the actions are:\n#{listed(actions, command)}"
  end

  @doc "The answer to a command whose word begins more than one action's label."
  def ambiguous(word, actions, command) do
    "#{word} could be more than one action; run one by its id:\n#{listed(actions, command)}"
  end

  @doc "The answer to a command naming a title more than one task has."
  def tasks(title, action, items, command) do
    ~s(More than one task is called "#{title}"; run #{action["label"]} on one by its id:\n) <>
      Enum.map_join(items, "\n", fn item ->
        due = if item["due"], do: ", due #{item["due"]}", else: ""

        "#{command} run #{action["id"]} #{item["id"]} — #{item["title"]} (#{item["status"]}#{due})"
      end)
  end

  defp listed(actions, command),
    do: Enum.map_join(actions, "\n", &"#{command} run #{&1["id"]} — #{&1["label"]}")

  defp first_word(label),
    do: label |> String.split(~r/\s+/, parts: 2) |> hd() |> String.downcase()
end
