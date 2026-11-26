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
  own newest is `ownActivity`. Until the server says who is signed in, a summary holds
  no activity at all: the account's own comment must not pass for someone else's.

  A list is read to its end, however small a page the server's administrator allows.
  A pull request whose reviews, comments or check statuses cannot all be read has no
  summary (or, for checks, no `checksState`), rather than one that misses some.
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

      case collaborators(cwd, target, repository) do
        {:ok, trusted} ->
          for number <- Enum.uniq(numbers),
              is_integer(number) and number > 0,
              summary = summary(cwd, target, repository, number, viewer, trusted),
              do: {{String.downcase(repository), number}, summary}

        {:error, reason} ->
          Logger.debug("Forgejo collaborators of #{repository}: #{inspect(reason)}")
          []
      end
    end)
    |> Map.new()
  end

  defp summary(cwd, target, repository, number, viewer, trusted) do
    base = "repos/#{Forgejo.encode_repository(repository)}"

    with {:ok, %{"number" => ^number, "title" => title} = pull} <-
           get(cwd, target, "#{base}/pulls/#{number}"),
         head when is_binary(head) <- get_in(pull, ["head", "ref"]),
         base_branch when is_binary(base_branch) <- get_in(pull, ["base", "ref"]),
         {:ok, reviews} <- pages(cwd, target, "#{base}/pulls/#{number}/reviews"),
         {:ok, comments} <- issue_comments(cwd, target, base, number),
         {:ok, review_comments} <- review_comments(cwd, target, base, number, reviews) do
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
      |> Map.merge(
        if(viewer, do: activity(reviews, comments ++ review_comments, viewer, trusted), else: %{})
      )
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
  # still pending keeps it pending, and otherwise it passes. Nil when there are none,
  # or when they cannot all be read: a page of successes says nothing of the next.
  defp checks(cwd, target, base, sha) do
    with {:ok, statuses} <- commit_statuses(cwd, target, base, sha) do
      states =
        for status <- statuses,
            state = status["status"] || status["state"],
            is_binary(state),
            do: state

      cond do
        Enum.any?(states, &(&1 in ~w(failure error))) -> "failing"
        Enum.any?(states, &(&1 == "pending")) -> "pending"
        Enum.any?(states, &(&1 in ~w(success warning))) -> "passing"
        true -> nil
      end
    else
      _ -> nil
    end
  end

  # Every status of the head's combined status, which Forgejo pages like a list.
  defp commit_statuses(_cwd, _target, _base, sha) when not is_binary(sha), do: {:ok, []}

  # The body's `total_count` is the page's own count; the overall one is in the
  # `X-Total-Count` header, and without it a full page says more may follow.
  defp commit_statuses(cwd, target, base, sha, page \\ 1, acc \\ []) do
    path = "#{base}/commits/#{URI.encode_www_form(sha)}/status?limit=#{@page}&page=#{page}"

    with {:ok, body, meta} <- Forgejo.api(cwd, target, path) do
      case JSON.decode(body) do
        {:ok, %{} = combined} ->
          rows = Enum.filter(combined["statuses"] || [], &is_map/1)
          acc = acc ++ rows

          more? =
            case Map.get(meta, :total) do
              total when is_integer(total) -> rows != [] and length(acc) < total
              _ -> length(rows) >= @page
            end

          cond do
            not more? -> {:ok, acc}
            page >= @max_pages -> {:error, {:failed, "Too many commit statuses to read."}}
            true -> commit_statuses(cwd, target, base, sha, page + 1, acc)
          end

        _ ->
          {:error, {:failed, "Forgejo answered in an unexpected shape."}}
      end
    end
  end

  # Replies to a review's thread are its comments, not reviews of their own. A pending
  # review's drafts are readable by its author but not yet said.
  defp review_comments(cwd, target, base, number, reviews) do
    reviews
    |> Enum.reject(&(&1["state"] == "PENDING"))
    |> Enum.filter(&((&1["comments_count"] || 0) > 0 and is_integer(&1["id"])))
    |> Enum.sort_by(&(epoch(&1["submitted_at"]) || 0), :desc)
    |> Enum.take(@review_comment_reads)
    |> Enum.reduce_while({:ok, []}, fn review, {:ok, acc} ->
      case list(cwd, target, "#{base}/pulls/#{number}/reviews/#{review["id"]}/comments") do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        error -> {:halt, error}
      end
    end)
  end

  # The newest published review or comment by someone trusted (`activity`) and the
  # newest by the signed-in account (`ownActivity`), as `%{"at", "author", "kind",
  # "state"}` or nil; and the newest review and newest comment of each (`activities`,
  # `ownActivities`), which `HalC2.PullRequests.Wakes` tells apart.
  defp activity(reviews, comments, viewer, trusted) do
    viewer = down(viewer || "")

    reviews =
      for review <- reviews,
          review["state"] in ~w(APPROVED REQUEST_CHANGES COMMENT),
          at = utc(review["submitted_at"]),
          author = login(review["user"]),
          do: {author, at, "review", review_state(review["state"])}

    # A comment's news is when it last changed: an edit is news once, as a new
    # comment is (upstream #18120).
    comments =
      for comment <- comments,
          at =
            Enum.max_by(
              [utc(comment["created_at"]), utc(comment["updated_at"])] |> Enum.reject(&is_nil/1),
              &(epoch(&1) || 0),
              fn -> nil end
            ),
          author = login(comment["user"]),
          do: {author, at, "comment", nil}

    {own, others} =
      Enum.split_with(reviews ++ comments, fn {author, _, _, _} -> down(author) == viewer end)

    trusted = Enum.filter(others, fn {author, _, _, _} -> down(author) in trusted end)

    %{
      "activity" => newest(trusted),
      "ownActivity" => newest(own),
      "activities" => newest_of_each_kind(trusted),
      "ownActivities" => newest_of_each_kind(own),
      # Comment times here are edit times; a snapshot without this was synced
      # under the creation-time stamp (`Wakes.advance_activity/3`).
      "commentStamp" => "edited"
    }
  end

  defp newest_of_each_kind(activities) do
    activities
    |> Enum.group_by(fn {_, _, kind, _} -> kind end)
    |> Enum.map(fn {_, of_kind} -> newest(of_kind) end)
    |> Enum.sort_by(&(epoch(&1["at"]) || 0))
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

  # Who the repository lists as collaborators, `{:ok, logins}`; none when the account
  # may not see them. Another failure is an error: a missing collaborator would read
  # as a stranger.
  defp collaborators(cwd, target, repository) do
    case pages(cwd, target, "repos/#{Forgejo.encode_repository(repository)}/collaborators") do
      {:ok, rows} ->
        {:ok, rows |> MapSet.new(&down(login(&1) || "")) |> MapSet.delete("")}

      {:error, {reason, _}} when reason in [:forbidden, :not_found, :unauthenticated] ->
        {:ok, MapSet.new()}

      error ->
        error
    end
  end

  defp viewer(cwd, target) do
    case get(cwd, target, "user") do
      {:ok, %{"login" => login}} when is_binary(login) -> login
      _ -> nil
    end
  end

  # --- what a reviewer reads and posts ----------------------------------------------

  # `ctx` is `%{cwd, remote_url, repository, number}`: the checkout read through, its
  # remote, and the pull request.

  @doc """
  The pull request as a reviewer needs it, in the fields `GitHub.detail/1` names them:
  its title, body, author, branches, head, labels, size, the commit statuses of its
  head as `checks` (`%{"name", "status"}`), the reviewers asked for, who is signed in
  (`viewer`) and the verdicts they may give (`viewerPermissions.verdicts`): Forgejo
  refuses an approval or change request on one's own pull request.
  """
  def detail(ctx) do
    target = target(ctx)
    base = base(ctx)

    with {:ok, %{"number" => _} = pull} <- get(ctx.cwd, target, "#{base}/pulls/#{ctx.number}") do
      viewer = viewer(ctx.cwd, target)
      author = actor(pull["user"])
      own? = viewer != nil and author != nil and down(author["login"]) == down(viewer)

      {:ok,
       %{
         "number" => ctx.number,
         "title" => pull["title"],
         "body" => pull["body"] || "",
         "url" => pull["html_url"],
         "state" => state(pull),
         "isDraft" => draft?(pull),
         "author" => author,
         "headBranch" => get_in(pull, ["head", "ref"]),
         "baseBranch" => get_in(pull, ["base", "ref"]),
         "headSha" => trimmed(get_in(pull, ["head", "sha"])),
         "baseSha" => trimmed(get_in(pull, ["base", "sha"])),
         "labels" => for(l <- pull["labels"] || [], n = trimmed(l["name"]), do: %{"name" => n}),
         "additions" => pull["additions"] || 0,
         "deletions" => pull["deletions"] || 0,
         "updatedAt" => utc(pull["updated_at"]),
         "checks" => statuses(ctx.cwd, target, base, get_in(pull, ["head", "sha"])),
         "reviewers" =>
           for(u <- pull["requested_reviewers"] || [], l = login(u), do: %{"login" => l}),
         "viewer" => viewer,
         "viewerPermissions" => %{
           "verdicts" =>
             if(own?, do: ["comment"], else: ["approve", "request-changes", "comment"])
         }
       }}
    end
  end

  @doc """
  What has been said on the pull request, in the fields `GitHub.activity/1` names
  them: `comments` holds its conversation comments (`kind` `"comment"`) and its
  reviews (`"review"`), each with `author.login`, `body` and `createdAt` (and the
  author's `association`, as `trust/2` judges it); each inline
  review comment is a `reviewThreads` entry of its own (`path`, `line`, `isResolved`,
  `comments`), as Forgejo's API does not group replies. An error when any of them
  cannot be read in full.
  """
  def activity(ctx) do
    target = target(ctx)
    base = base(ctx)

    # A review that cannot be read must not pass for one never posted: the code review
    # plugin reposts only when its own is absent.
    with {:ok, pull} <- get(ctx.cwd, target, "#{base}/pulls/#{ctx.number}"),
         {:ok, reviews} <- pages(ctx.cwd, target, "#{base}/pulls/#{ctx.number}/reviews"),
         {:ok, comments} <- issue_comments(ctx.cwd, target, base, ctx.number),
         {:ok, review_comments} <- review_comments(ctx.cwd, target, base, ctx.number, reviews) do
      # Collaborators that cannot be read count as none: their comments then pass
      # for a stranger's, which only keeps them from a review on this machine.
      collaborators =
        case collaborators(ctx.cwd, target, ctx.repository) do
          {:ok, collaborators} -> collaborators
          _ -> MapSet.new()
        end

      remark = fn kind, user, body, at ->
        remark(kind, user, association(user, owner(pull), collaborators), body, at)
      end

      remarks =
        for c <- comments,
            do: remark.("comment", c["user"], c["body"], c["created_at"])

      verdicts =
        for r <- reviews,
            r["state"] in ~w(APPROVED REQUEST_CHANGES COMMENT),
            do: remark.("review", r["user"], r["body"], r["submitted_at"])

      threads =
        for c <- review_comments do
          %{
            "path" => c["path"],
            "line" =>
              Enum.find([c["position"], c["original_position"]], &(is_integer(&1) and &1 > 0)),
            "isResolved" => c["resolver"] != nil,
            "comments" => [remark.("review", c["user"], c["body"], c["created_at"])]
          }
        end

      {:ok, %{"comments" => remarks ++ verdicts, "reviewThreads" => threads}}
    end
  end

  # Forgejo has no bots or mannequins: every author is a user.
  defp remark(kind, user, association, body, at),
    do: %{
      "kind" => kind,
      "author" => %{"login" => login(user), "isUser" => true, "association" => association},
      "body" => body || "",
      "createdAt" => utc(at)
    }

  defp owner(pull), do: down(login(get_in(pull, ["base", "repo", "owner"])) || "")

  # A user's standing in the repository, as GitHub's `authorAssociation` names it.
  defp association(user, owner, collaborators) do
    name = down(login(user) || "")

    cond do
      name == "" -> "NONE"
      name == owner -> "OWNER"
      MapSet.member?(collaborators, name) -> "COLLABORATOR"
      true -> "NONE"
    end
  end

  @doc "Who is signed in to the pull request's server, as `{:ok, login}`."
  def signed_in(ctx) do
    case get(ctx.cwd, target(ctx), "user") do
      {:ok, %{"login" => login}} when is_binary(login) -> {:ok, login}
      {:ok, _} -> {:error, {:failed, "Forgejo did not say who is signed in."}}
      error -> error
    end
  end

  @doc """
  Who stands behind the pull request, in the shape `GitHub.trust/2` answers. An
  actor's `association` is `OWNER` for the repository's owner, `COLLABORATOR` for one
  of its collaborators and `NONE` otherwise; Forgejo has no bots or mannequins, so
  every actor is a user. `labeled` is whoever last added `label` and `requested`
  whoever last asked the signed-in account for a review, from the pull request's
  timeline, with `tied` naming anyone else who did the same within that second.
  """
  def trust(ctx, label \\ nil) do
    target = target(ctx)
    base = base(ctx)

    with {:ok, %{"number" => _} = pull} <- get(ctx.cwd, target, "#{base}/pulls/#{ctx.number}"),
         {:ok, collaborators} <- collaborators(ctx.cwd, target, ctx.repository),
         {:ok, events} <- timeline(ctx.cwd, target, base, ctx.number),
         {:ok, comments} <- issue_comments(ctx.cwd, target, base, ctx.number) do
      viewer = viewer(ctx.cwd, target)
      association = &association(&1, owner(pull), collaborators)

      as_actor = fn user ->
        case login(user) do
          nil ->
            nil

          name ->
            %{
              "login" => name,
              "isBot" => false,
              "isUser" => true,
              "association" => association.(user),
              "role" => nil
            }
        end
      end

      label = label && trimmed(label)

      labeled =
        label &&
          last_event(
            events,
            &(&1["type"] == "label" and &1["body"] == "1" and
                down(trimmed(get_in(&1, ["label", "name"])) || "") == down(label)),
            as_actor
          )

      requested =
        viewer &&
          last_event(
            events,
            &(&1["type"] == "review_request" and &1["removed_assignee"] != true and
                down(login(&1["assignee"]) || "") == down(viewer)),
            as_actor
          )

      head_repo = get_in(pull, ["head", "repo"])
      base_repo = get_in(pull, ["base", "repo"])

      {:ok,
       %{
         "viewer" => viewer,
         "author" => as_actor.(pull["user"]),
         "isCrossRepository" =>
           is_map(head_repo) and is_map(base_repo) and head_repo["id"] != base_repo["id"],
         "headOwner" => login(get_in(pull, ["head", "repo", "owner"])),
         "headSha" => trimmed(get_in(pull, ["head", "sha"])),
         "comments" =>
           for(
             c <- comments,
             actor = as_actor.(c["user"]),
             do:
               Map.merge(actor, %{"body" => c["body"] || "", "createdAt" => utc(c["created_at"])})
           ),
         "labeled" => labeled,
         "requested" => requested
       }}
    end
  end

  # The newest matching timeline event's actor with its `createdAt`; the others at
  # that second by someone else are `tied`, as GitHub's are. Nil when none matches.
  defp last_event(events, match?, as_actor) do
    matching = Enum.filter(events, &(is_map(&1) and match?.(&1)))

    case matching do
      [] ->
        nil

      _ ->
        at = fn e -> epoch(utc(e["created_at"])) || 0 end
        latest = matching |> Enum.map(at) |> Enum.max()
        [last | tied] = matching |> Enum.filter(&(at.(&1) == latest)) |> Enum.reverse()

        with %{} = actor <- as_actor.(last["user"]) do
          actor = Map.put(actor, "createdAt", utc(last["created_at"]))

          others =
            tied
            |> Enum.map(&(as_actor.(&1["user"]) || %{"login" => nil}))
            |> Enum.reject(&(&1["login"] != nil and down(&1["login"]) == down(actor["login"])))
            |> Enum.uniq_by(& &1["login"])

          if others == [], do: actor, else: Map.put(actor, "tied", others)
        end
    end
  end

  @doc "The pull request's `{additions, deletions}`, or nil when it cannot be read."
  def stats(ctx) do
    case get(ctx.cwd, target(ctx), "#{base(ctx)}/pulls/#{ctx.number}") do
      {:ok, %{"additions" => a, "deletions" => d}} when is_integer(a) and is_integer(d) -> {a, d}
      _ -> nil
    end
  end

  @doc """
  Posts a review (`verdict` `approve`, `request-changes` or `comment`) with `body` and
  inline `comments` (`%{"path", "body", "position"}`, a position as
  `HalC2.PullRequests.GitHub.submit_review/5` takes it) on commit `commit_id`. Forgejo
  places a comment by its line in the new file, or in the old one for a deleted line.
  Refused while the signed-in account has a pending review on the pull request, which
  Forgejo would publish the review's comments into: it may be the user's draft. When
  the post fails, the pending review it left is deleted, so no comment of a failed post
  is published by a later one; one that could not be deleted then is deleted by the
  next attempt, as its comments are all this review's. One it cannot tell is its own
  (one with no comments staged) is left, and the failure says so.
  """
  def submit_review(ctx, verdict, body, comments, commit_id \\ nil) do
    review =
      %{
        "event" =>
          %{
            "approve" => "APPROVED",
            "request-changes" => "REQUEST_CHANGES",
            "comment" => "COMMENT"
          }[
            verdict
          ],
        "body" => body,
        "comments" =>
          for c <- comments do
            place =
              case c["position"] do
                %{"kind" => "deleted", "oldLine" => line} ->
                  %{"old_position" => line}

                %{"kind" => "context", "side" => "left", "oldLine" => line} ->
                  %{"old_position" => line}

                %{"newLine" => line} ->
                  %{"new_position" => line}
              end

            Map.merge(%{"path" => c["path"], "body" => c["body"]}, place)
          end
      }
      |> then(&if(is_binary(commit_id), do: Map.put(&1, "commit_id", commit_id), else: &1))

    posted = MapSet.new(review["comments"], &{&1["path"], &1["body"]})

    with {:ok, reviews} <- pending(ctx),
         [] <- Enum.reject(reviews, &discard_own(ctx, &1, posted)) do
      case Forgejo.api(ctx.cwd, target(ctx), "#{base(ctx)}/pulls/#{ctx.number}/reviews",
             method: "POST",
             body: review
           ) do
        {:ok, _, _} ->
          :ok

        error ->
          if discard_failed(ctx, posted), do: error, else: left_pending(error)
      end
    else
      [_ | _] ->
        {:error,
         {:failed,
          "Your Forgejo account has a pending review on this pull request, which this " <>
            "review's comments would be published into. It may be a draft of yours, or " <>
            "left over from an earlier post of this plugin's that failed. Submit or " <>
            "discard it in Forgejo, and the review is posted on the next attempt."}}

      error ->
        error
    end
  end

  # The pending reviews of the signed-in account. Forgejo stages a review's comments in
  # one before it publishes them; while one stands, a post adds to it.
  defp pending(ctx) do
    with {:ok, viewer} <- signed_in(ctx),
         {:ok, reviews} <- pages(ctx.cwd, target(ctx), "#{base(ctx)}/pulls/#{ctx.number}/reviews") do
      {:ok,
       for(
         r <- reviews,
         r["state"] == "PENDING",
         is_integer(r["id"]),
         down(login(r["user"]) || "") == down(viewer),
         do: r
       )}
    end
  end

  # Forgejo keeps a failed post's staged comments in a pending review, and while it
  # stands the next post fails as well. There was none before the post, so one now is
  # the post's own, or one the user began meanwhile.
  # True when none is left: one with no comments staged, or any not all this review's,
  # is not this review's to delete.
  defp discard_failed(ctx, posted) do
    case pending(ctx) do
      {:ok, reviews} -> Enum.all?(reviews, &discard_own(ctx, &1, posted))
      _ -> false
    end
  end

  # The post's failure, saying the pending review it may have left stands: the next post
  # is refused until the user discards it.
  defp left_pending({:error, {kind, message}}) when is_binary(message),
    do:
      {:error,
       {kind,
        message <>
          " It may have left a pending review on the pull request that could not be " <>
          "cleared. Discard it in Forgejo before the review is posted again."}}

  defp left_pending(error), do: error

  # Deletes pending review `r` when it stages comments and all of them are among
  # `posted` (`{path, body}`): a failed post of this review left it. True once it is gone.
  defp discard_own(ctx, r, posted) do
    path = "#{base(ctx)}/pulls/#{ctx.number}/reviews/#{r["id"]}"

    with {:ok, [_ | _] = staged} <- list(ctx.cwd, target(ctx), "#{path}/comments"),
         true <- Enum.all?(staged, &MapSet.member?(posted, {&1["path"], &1["body"]})),
         {:ok, _, _} <- Forgejo.api(ctx.cwd, target(ctx), path, method: "DELETE") do
      true
    else
      _ -> false
    end
  end

  @doc """
  How a clone of the repository fetches it over HTTP from the server the pull
  request's API is read on: `%{"url", "username", "token", "server"}`, the token fj
  signs in with for git's credential prompt, and `server` the address it was issued
  for, which git may fetch from alone with it. The token is nil under tea, which keeps
  its own, and for a server over plain HTTP other than this machine, which would show
  it to the network.
  """
  def fetch_access(ctx) do
    with {:ok, resolved} <- Forgejo.resolve(ctx.cwd, target(ctx)) do
      server = Forgejo.api_base_url(resolved.base_url)

      token =
        with :fj <- resolved.command,
             true <- Forgejo.token_safe?(resolved.base_url),
             true <- Forgejo.token_safe?(server),
             {:ok, keys} <- Forgejo.keys(),
             token when is_binary(token) <- get_in(keys, ["hosts", resolved.login, "token"]),
             do: token,
             else: (_ -> nil)

      {:ok,
       %{
         "url" => "#{resolved.base_url}/#{resolved.repository}.git",
         "username" => "hal-c2",
         "token" => token,
         "server" => server
       }}
    end
  end

  # The head's statuses, as checks.
  defp statuses(cwd, target, base, sha) do
    case commit_statuses(cwd, target, base, sha) do
      {:ok, statuses} ->
        for s <- statuses, do: %{"name" => s["context"], "status" => s["status"] || s["state"]}

      _ ->
        []
    end
  end

  defp target(ctx), do: [remote_url: ctx[:remote_url], repository: ctx.repository]
  defp base(ctx), do: "repos/#{Forgejo.encode_repository(ctx.repository)}"

  # --- reading ------------------------------------------------------------------------

  defp get(cwd, target, path) do
    with {:ok, body, _} <- Forgejo.api(cwd, target, path) do
      case JSON.decode(body) do
        {:ok, data} -> {:ok, data}
        _ -> {:error, {:failed, "Forgejo answered in an unexpected shape."}}
      end
    end
  end

  # A list's rows, `{:ok, rows, meta}` (`meta` as `Forgejo.api/4` answers it).
  defp list_page(cwd, target, path) do
    with {:ok, body, meta} <- Forgejo.api(cwd, target, path) do
      case JSON.decode(body) do
        {:ok, rows} when is_list(rows) -> {:ok, Enum.filter(rows, &is_map/1), meta}
        _ -> {:error, {:failed, "Forgejo answered in an unexpected shape."}}
      end
    end
  end

  defp list(cwd, target, path) do
    with {:ok, rows, _} <- list_page(cwd, target, path), do: {:ok, rows}
  end

  # An issue's comments come in one answer: the endpoint takes `since` and `before`, not
  # `page` and `limit`, so paging it would read the whole list again on every page.
  defp issue_comments(cwd, target, base, number),
    do: list(cwd, target, "#{base}/issues/#{number}/comments")

  # Every page of a paginated list, `{:ok, rows}`, up to `@max_pages` of them, or an
  # error when more are known to follow: a short history is not a complete one. A
  # `rel="next"` link, or the total (`X-Total-Count`), says whether more follow; with
  # neither, a full page does. The total counts rows the server pages but hides, such
  # as other accounts' pending reviews, so a page may be short or empty with more to
  # come: pages are counted against it, at the server's page size (`size`), which may
  # be below the `limit` asked for. A short page is read as the last only once that
  # size is known. A total that changes between pages means the list changed while it
  # was read, and a row may have moved to a page already read: that read is an error.
  defp pages(cwd, target, path, page \\ 1, acc \\ [], size \\ nil, first \\ nil) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"

    with {:ok, rows, meta} <-
           list_page(cwd, target, "#{path}#{separator}limit=#{@page}&page=#{page}") do
      acc = acc ++ rows
      total = Map.get(meta, :total)
      link = Map.get(meta, :link)
      first = first || total

      size =
        cond do
          size -> size
          length(rows) >= @page -> @page
          is_integer(total) and length(acc) < total -> page_size(cwd, target)
          true -> nil
        end

      more? =
        cond do
          is_binary(link) and link != "" -> String.contains?(link, ~s(rel="next"))
          not is_integer(total) -> length(rows) >= @page
          length(acc) >= total -> false
          is_integer(size) -> page * size < total
          true -> :unknown
        end

      cond do
        total != first -> {:error, {:failed, "Forgejo's list changed while it was read."}}
        more? == :unknown -> {:error, {:failed, "Forgejo's list could not be read to its end."}}
        not more? -> {:ok, acc}
        page >= @max_pages -> {:error, {:failed, "Too many pages to read from Forgejo."}}
        true -> pages(cwd, target, path, page + 1, acc, size, first)
      end
    end
  end

  # The pull request's timeline. Forgejo pages it without a total (its `X-Total-Count`
  # counts the page) or a `rel="next"` link, and leaves review line comments out of each
  # page after reading it, so a short page, even an empty one, may have more after it.
  # The reviews' line comments (`hidden`) are as many rows as it can leave out: a page
  # is the last when it is short by more than are left.
  defp timeline(cwd, target, base, number) do
    with {:ok, reviews} <- pages(cwd, target, "#{base}/pulls/#{number}/reviews") do
      hidden =
        reviews
        |> Enum.map(&if(is_integer(&1["comments_count"]), do: &1["comments_count"], else: 0))
        |> Enum.sum()

      size = page_size(cwd, target) || @page
      timeline_pages(cwd, target, "#{base}/issues/#{number}/timeline", size, hidden, 1, [])
    end
  end

  defp timeline_pages(cwd, target, path, size, hidden, page, acc) do
    with {:ok, rows, _} <- list_page(cwd, target, "#{path}?limit=#{size}&page=#{page}") do
      acc = acc ++ rows
      short = max(size - length(rows), 0)

      cond do
        short > hidden -> {:ok, acc}
        page >= @max_pages -> {:error, {:failed, "Too many pages to read from Forgejo."}}
        true -> timeline_pages(cwd, target, path, size, hidden - short, page + 1, acc)
      end
    end
  end

  # How many rows the server serves a page at most, or nil when it does not say.
  defp page_size(cwd, target) do
    case get(cwd, target, "settings/api") do
      {:ok, %{"max_response_items" => max}} when is_integer(max) and max > 0 -> min(max, @page)
      _ -> nil
    end
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
