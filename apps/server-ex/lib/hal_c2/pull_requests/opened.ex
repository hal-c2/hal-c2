defmodule HalC2.PullRequests.Opened do
  @moduledoc """
  Links the pull requests a thread opened itself, with `source: "created"`: the ones its
  agent's command printed as it created them (`urls/2`, from
  `HalC2.Orchestration.TurnWriter`). A pull request the thread already carries,
  as a tombstone too, is left as it is, so one the user unlinked stays unlinked.
  """

  require Logger

  alias HalC2.Projection.PullRequests, as: Links
  alias HalC2.StreamState

  # `gh pr create` (or `gh pr new`), and the same in GitLab's, Forgejo's and hub's CLIs.
  @creates ~r/(?:^|[\s;&|(`'"])(?:gh\s+pr\s+(?:create|new)|glab\s+mr\s+(?:create|new)|tea\s+(?:pulls?|pr)\s+create|hub\s+pull-request)\b/

  @doc """
  The pull request URLs a command printed as it created them: `input` runs a create
  command, and a line of its `output` is a pull request URL alone, as `gh pr create`
  prints the one it opened (or the one already open for the branch). A command that only
  reads pull requests, such as `gh pr view`, gives none.
  """
  def urls(input, output) when is_binary(input) and is_binary(output) do
    if Regex.match?(@creates, input) do
      output
      |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
      |> String.split(~r/\R/)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&Links.parse_change_request_url/1)
      |> Enum.uniq()
    else
      []
    end
  end

  def urls(_input, _output), do: []

  @doc "Links each of `urls` that thread `thread_id` does not carry yet."
  def link(thread_id, urls) do
    known =
      case StreamState.get(HalC2.Streams.state(thread_id), "thread")[thread_id] do
        nil -> nil
        thread -> MapSet.new(Links.of(thread), &Links.key/1)
      end

    for target <- Enum.flat_map(urls, &target/1) |> Enum.uniq_by(&Links.key/1),
        known != nil and not MapSet.member?(known, Links.key(target)) do
      command =
        Map.merge(target, %{
          "type" => "thread.pull-request.link",
          "commandId" => "server:pr-opened-link:#{HalC2.Environment.uuid4()}",
          "threadId" => thread_id,
          "source" => "created"
        })

      with {:error, reason} <- HalC2.Orchestration.dispatch(command),
           do:
             Logger.warning("could not link #{target["url"]} to #{thread_id}: #{inspect(reason)}")
    end

    :ok
  end

  defp target(url) do
    case Links.parse_change_request_url(url) do
      nil ->
        []

      parsed ->
        [
          %{
            "host" => Map.get(parsed, :authority, parsed.host),
            "repository" => parsed.repository,
            "number" => parsed.number,
            "url" => url
          }
        ]
    end
  end
end
