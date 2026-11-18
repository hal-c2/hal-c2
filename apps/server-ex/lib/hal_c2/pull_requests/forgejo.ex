defmodule HalC2.PullRequests.Forgejo do
  @moduledoc """
  Pull request summaries on Forgejo (and Gitea) hosts, in the shape
  `HalC2.PullRequests.GitHub.summaries/2` answers, so `HalC2.PullRequests.Sync`
  keeps a Forgejo link's snapshot and `HalC2.PullRequests.Wakes` wakes its thread
  as it would for GitHub.

  Each pull request is read over Forgejo's REST API (`HalC2.SourceControl.Forgejo`,
  with fj's or tea's sign-in): the pull request itself, its reviews, the inline
  comments of its latest reviews (where replies to a review land), its conversation
  comments, and the combined commit status of its head, which Forgejo Actions and
  any other CI write to.

  Activity counts as `activity` only from someone the repository trusts: its owner,
  a collaborator, an official reviewer or a requested one. The signed-in account's
  own newest is `ownActivity`.
  """

  require Logger

  alias HalC2.SourceControl.Forgejo

  @page 50
  @max_pages 10
  # Inline comments are read for this many of the newest reviews that have any.
  @review_comment_reads 10

  @doc """
  Summaries of `refs` (`[{repository, number}]`) on the Forgejo server the checkout at
  `cwd` (whose remote is `remote_url`) signs in to, keyed `{downcased repository,
  number}`. A pull request the server did not answer for is absent.
  """
  def summaries(cwd, remote_url, refs) do
    target = [remote_url: remote_url]
    viewer = viewer(cwd, target)

    refs
    |> Enum.group_by(fn {repository, _} -> repository end, fn {_, number} -> number end)
    |> Enum.flat_map(fn {repository, numbers} ->
      target = Keyword.put(target, :repository, repository)
      trusted = collaborators(cwd, target, repository)

      for number <- Enum.uniq(numbers),
          is_integer(number) and number > 0,
          summary = summary(cwd, target, repository, number, viewer, trusted),
          do: {{String.downcase(repository), number}, summary}
    end)
    |> Map.new()
  end

  defp summary(cwd, target, repository, number, viewer, trusted) do
    base = "repos/#{Forgejo.encode_repository(repository)}"

    with {:ok, %{"number" => ^number, "title" => title} = pull} <-
           get(cwd, target, "#{base}/pulls/#{number}"),
         head when is_binary(head) <- get_in(pull, ["head", "ref"]),
         base_branch when is_binary(base_branch) <- get_in(pull, ["base", "ref"]) do
      reviews = pages(cwd, target, "#{base}/pulls/#{number}/reviews")
      comments = list(cwd, target, "#{base}/issues/#{number}/comments")
      review_comments = review_comments(cwd, target, base, number, reviews)
      requested = for user <- pull["requested_reviewers"] || [], login = login(user), do: login

      trusted =
        trusted
        |> MapSet.union(MapSet.new(requested, &String.downcase/1))
        |> MapSet.union(
          MapSet.new(for r <- reviews, r["official"] == true, l = login(r["user"]), do: down(l))
        )
        |> then(fn set ->
          case login(get_in(pull, ["base", "repo", "owner"])) do
            nil -> set
            owner -> MapSet.put(set, down(owner))
          end
        end)

      %{
        "number" => number,
        "title" => title,
        "url" => pull["html_url"],
        "headBranch" => head,
        "baseBranch" => base_branch,
        "state" => state(pull),
        "isDraft" => draft?(pull),
        "closedAt" => utc(pull["closed_at"]),
        "mergedAt" => utc(pull["merged_at"]),
        "updatedAt" => utc(pull["updated_at"]),
        "author" => actor(pull["user"]),
        "additions" => pull["additions"] || 0,
        "deletions" => pull["deletions"] || 0,
        "changedFiles" => pull["changed_files"] || 0,
        "reviewDecision" => review_decision(reviews, requested),
        "checksState" => checks(cwd, target, base, get_in(pull, ["head", "sha"])),
        "mergeability" =>
          case pull["mergeable"] do
            true -> "mergeable"
            false -> "conflicting"
            _ -> "unknown"
          end,
        "mergeQueue" => nil,
        "mergeQueueRemoval" => nil
      }
      |> Map.merge(activity(reviews, comments ++ review_comments, viewer, trusted))
    else
      {:error, reason} ->
        Logger.debug("Forgejo pull request #{repository}##{number}: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  defp state(%{"merged" => true}), do: "merged"
  defp state(%{"state" => "closed"}), do: "closed"
  defp state(_pull), do: "open"

  defp draft?(%{"draft" => draft}) when is_boolean(draft), do: draft
  defp draft?(pull), do: String.match?(pull["title"] || "", ~r/^(?:\[WIP\]|WIP:)/i)

  # The newest verdict of each reviewer decides, as on GitHub; a dismissed one does
  # not count, and a pull request waiting on someone asked to review needs review.
  defp review_decision(reviews, requested) do
    states =
      reviews
      |> Enum.filter(&(&1["state"] in ~w(APPROVED REQUEST_CHANGES) and &1["dismissed"] != true))
      |> Enum.sort_by(&(epoch(&1["submitted_at"]) || 0))
      |> Enum.reduce(%{}, fn review, acc ->
        Map.put(acc, down(login(review["user"]) || ""), review["state"])
      end)
      |> Map.values()

    cond do
      "REQUEST_CHANGES" in states -> "changes-requested"
      "APPROVED" in states -> "approved"
      requested != [] -> "review-required"
      true -> nil
    end
  end

  # The head's statuses, one per context: a failure (or error) fails it, anything
  # still pending keeps it pending, and otherwise it passes. Nil when there are none.
  defp checks(_cwd, _target, _base, sha) when not is_binary(sha), do: nil

  defp checks(cwd, target, base, sha) do
    case get(cwd, target, "#{base}/commits/#{URI.encode_www_form(sha)}/status?limit=#{@page}") do
      {:ok, %{} = combined} ->
        states =
          for status <- combined["statuses"] || [],
              state = status["status"] || status["state"],
              is_binary(state),
              do: state

        states = if states == [], do: List.wrap(combined["state"]), else: states

        cond do
          (combined["total_count"] || length(states)) == 0 -> nil
          Enum.any?(states, &(&1 in ~w(failure error))) -> "failing"
          Enum.any?(states, &(&1 == "pending")) -> "pending"
          Enum.any?(states, &(&1 in ~w(success warning))) -> "passing"
          true -> nil
        end

      _ ->
        nil
    end
  end

  # Replies to a review's thread are its comments, not reviews of their own.
  defp review_comments(cwd, target, base, number, reviews) do
    reviews
    |> Enum.filter(&((&1["comments_count"] || 0) > 0 and is_integer(&1["id"])))
    |> Enum.sort_by(&(epoch(&1["submitted_at"]) || 0), :desc)
    |> Enum.take(@review_comment_reads)
    |> Enum.flat_map(&list(cwd, target, "#{base}/pulls/#{number}/reviews/#{&1["id"]}/comments"))
  end

  # The newest published review or comment by someone trusted (`activity`) and the
  # newest by the signed-in account (`ownActivity`), as `%{"at", "author", "kind",
  # "state"}` or nil.
  defp activity(reviews, comments, viewer, trusted) do
    viewer = down(viewer || "")

    reviews =
      for review <- reviews,
          review["state"] in ~w(APPROVED REQUEST_CHANGES COMMENT),
          at = utc(review["submitted_at"]),
          author = login(review["user"]),
          do: {author, at, "review", review_state(review["state"])}

    comments =
      for comment <- comments,
          at = utc(comment["created_at"]),
          author = login(comment["user"]),
          do: {author, at, "comment", nil}

    {own, others} =
      Enum.split_with(reviews ++ comments, fn {author, _, _, _} -> down(author) == viewer end)

    %{
      "activity" =>
        others |> Enum.filter(fn {author, _, _, _} -> down(author) in trusted end) |> newest(),
      "ownActivity" => newest(own)
    }
  end

  defp review_state("APPROVED"), do: "approved"
  defp review_state("REQUEST_CHANGES"), do: "changes_requested"
  defp review_state(_), do: "commented"

  defp newest(activities) do
    case Enum.max_by(activities, fn {_, at, _, _} -> epoch(at) || 0 end, fn -> nil end) do
      nil ->
        nil

      {author, at, kind, state} ->
        %{"at" => at, "author" => author, "kind" => kind, "state" => state}
    end
  end

  # Who the repository lists as collaborators; nothing when the account may not see.
  defp collaborators(cwd, target, repository) do
    cwd
    |> pages(target, "repos/#{Forgejo.encode_repository(repository)}/collaborators")
    |> MapSet.new(&down(login(&1) || ""))
    |> MapSet.delete("")
  end

  defp viewer(cwd, target) do
    case get(cwd, target, "user") do
      {:ok, %{"login" => login}} when is_binary(login) -> login
      _ -> nil
    end
  end

  # --- reading ------------------------------------------------------------------------

  defp get(cwd, target, path) do
    with {:ok, body, _} <- Forgejo.api(cwd, target, path) do
      case JSON.decode(body) do
        {:ok, data} -> {:ok, data}
        _ -> {:error, {:failed, "Forgejo answered in an unexpected shape."}}
      end
    end
  end

  defp list(cwd, target, path) do
    case get(cwd, target, path) do
      {:ok, rows} when is_list(rows) -> Enum.filter(rows, &is_map/1)
      _ -> []
    end
  end

  # Every page of a paginated list, up to `@max_pages` of them.
  defp pages(cwd, target, path, page \\ 1) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    rows = list(cwd, target, "#{path}#{separator}limit=#{@page}&page=#{page}")

    if length(rows) >= @page and page < @max_pages,
      do: rows ++ pages(cwd, target, path, page + 1),
      else: rows
  end

  defp actor(%{} = user) do
    case login(user) do
      nil ->
        nil

      login ->
        %{
          "login" => login,
          "name" => trimmed(user["full_name"]),
          "avatarUrl" => trimmed(user["avatar_url"])
        }
    end
  end

  defp actor(_), do: nil

  defp login(%{"login" => login}), do: trimmed(login)
  defp login(_), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_), do: nil

  defp down(text), do: String.downcase(text)

  # Forgejo writes times in the server's zone; snapshots hold them in UTC. Forgejo's
  # zero time (`0001-01-01…`) is no time.
  defp utc(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, %DateTime{year: year} = at, _offset} when year > 1970 ->
        at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  defp utc(_), do: nil

  defp epoch(at), do: HalC2.Projection.JS.epoch_ms(at)
end
