defmodule HalC2.PullRequests do
  @moduledoc """
  Pull requests for this MC's projects (`pullRequests.*`). A project's repository is
  its checkout's primary remote; GitHub repositories are read and changed through `gh`
  (`HalC2.PullRequests.GitHub`). The listing also reads GitLab, Forgejo, Azure DevOps
  and Bitbucket projects (`HalC2.PullRequests.Hosts`) and GitLab ones are previewed
  through `glab`; other operations on those hosts are answered with
  `PullRequestUnavailableError` (`provider-unsupported`).

  A reference names a project and a repository. The project's own repository is
  served through its checkout; one that also names a `host` may point at any
  repository on that host, served through a checkout there.

  Who is signed in to each host is cached, and link previews for a few seconds
  (`HalC2.PullRequests.Held`). Every change made here forgets the branches held as
  having that pull request (`HalC2.PullRequests.Branches`) and bumps
  `HalC2.PullRequests.Refreshes`, which clients follow to read again.
  """

  require Logger

  alias HalC2.GitHub.Limits
  alias HalC2.PullRequests.{Branches, GitHub, Held, Hosts, Refreshes}
  alias HalC2.SourceControl.ChangeRequests
  alias HalC2.SourceControl.Cli

  @default_limit 99
  @viewer_ttl 600_000
  @viewers {__MODULE__, :viewers}
  @ssh_hosts {__MODULE__, :ssh_hosts}

  @requirements %{
    missing:
      "GitHub CLI (`gh`) is required to browse change requests on this host. Install it from https://cli.github.com/ and reload.",
    unauthenticated: "GitHub CLI is not authenticated. Run `gh auth login` and retry."
  }

  @action_refusals %{
    "merge" => "You need write access on this repository to merge.",
    "ready" =>
      "You need write access on this repository, or to have opened this change request, to mark it ready for review.",
    "draft" =>
      "You need write access on this repository, or to have opened this change request, to return it to a draft.",
    "close" =>
      "You need write access on this repository, or to have opened this change request, to close it.",
    "update-branch" =>
      "You need write access on this repository, or to have opened this change request, to update its branch.",
    "reopen" =>
      "You need write access on this repository, or to have opened this change request, to reopen it.",
    "enable-auto-merge" =>
      "You need write access on this repository to have it merged for you once it is ready.",
    "disable-auto-merge" =>
      "You need write access on this repository to stop it being merged for you once it is ready.",
    "revert" => "You need write access on this repository to open a revert pull request.",
    "approve-workflows" =>
      "You need write access on this repository to approve workflows from a fork pull request.",
    "allow-maintainer-edits" =>
      "Only the author of a pull request from a fork can let maintainers edit its branch.",
    "stop-maintainer-edits" =>
      "Only the author of a pull request from a fork can stop maintainers editing its branch."
  }

  @auto_merge_refusal "Auto-merge is not available here: this repository has it switched off, " <>
                        "or the pull request can be merged now."

  @verdict_labels %{
    "approve" => "approve",
    "request-changes" => "request changes on",
    "comment" => "comment on"
  }

  @reviewer_refusal "You need write access on this repository to ask for a review."
  @label_refusal "You need triage access on this repository to change its labels."

  # What a host cannot do at all, said as the user is told it (`PullRequestCapabilities`
  # of the removed server's providers): Azure DevOps writes no remark of any kind,
  # Forgejo has no thread replies or resolution, Bitbucket and Azure DevOps have no
  # reactions, and a host no provider claims cannot be rewritten on. A host that can
  # do a thing but has no MC provider yet still answers `provider-unsupported`.
  @host_capabilities %{
    "azure-devops" => %{
      comment: false,
      inline: false,
      reply: false,
      resolve: false,
      reactions: false,
      verdicts: [],
      edit_comment: false
    },
    "bitbucket" => %{reactions: false},
    "forgejo" => %{reply: false, resolve: false},
    "unknown" => %{edit_change_request: false, edit_comment: false}
  }

  @host_refusal_details %{
    comment: "This host cannot post a comment on a change request.",
    inline: "This host cannot comment on a line of a change request.",
    reply: "This host cannot reply to a review conversation.",
    resolve: "This host cannot resolve a review conversation.",
    reactions: "This host has no reactions.",
    edit_change_request: "This host cannot rewrite a change request.",
    edit_comment: "This host cannot rewrite a comment."
  }

  @methods %{
    "list" => :list,
    "listStats" => :list_stats,
    "summary" => :summary,
    "routing" => :routing,
    "routingIdentity" => :routing_identity,
    "stack" => :stack,
    "linkedThreads" => :linked_threads,
    "detail" => :detail,
    "preview" => :preview,
    "checks" => :checks,
    "activity" => :activity,
    "threadComments" => :thread_comments,
    "diffFileContents" => :diff_file_contents,
    "filesViewed" => :files_viewed,
    "setFilesViewed" => :set_files_viewed,
    "runAction" => :run_action,
    "update" => :update,
    "comment" => :comment,
    "updateComment" => :update_comment,
    "submitReview" => :submit_review,
    "replyToThread" => :reply_to_thread,
    "setThreadResolution" => :set_thread_resolution,
    "setReaction" => :set_reaction,
    "invalidate" => :invalidate,
    "reviewerCandidates" => :reviewer_candidates,
    "requestReviewers" => :request_reviewers,
    "labelCandidates" => :label_candidates,
    "setLabels" => :set_labels
  }

  # What the user did, rather than a view reading: these go through a rate-limit pause.
  @asked ~w(setFilesViewed runAction update comment updateComment submitReview replyToThread
            setThreadResolution setReaction requestReviewers setLabels)

  @doc "Serves `pullRequests.<method>` (`HalC2.Rpc`)."
  def handle(method, input) do
    case @methods[method] do
      nil -> {:error, "pullRequests.#{method} is not served by this MC yet"}
      fun when method in @asked -> HalC2.GitHub.asked(fn -> apply(__MODULE__, fun, [input]) end)
      fun -> apply(__MODULE__, fun, [input])
    end
  end

  # --- listing ----------------------------------------------------------------------

  @doc """
  `pullRequests.list`: each GitHub repository read at once, newest update first. A
  repository that could not be read is an entry in `errors` rather than a failure,
  unless no host the listing covers can be read at all. Repositories on a host a git
  host plugin serves (`HalC2.Plugins.GitHost`) are read through it, on the first page.

  A repository GitHub gave up on (a 502 or 504, an answer cut off, no answer in time)
  is held back from the listings that follow, which say when it is read again
  (`HalC2.GitHub.Limits`), and read for a while at the page size that got through. A hand
  refresh (`invalidate/1`) and a read under `HalC2.GitHub.asked/1` go through the hold.
  """
  def list(input) do
    with {:ok, cursors} <- decode_cursors(input["cursors"]) do
      {github, others} = input |> workspace() |> Enum.split_with(&(&1.kind == "github"))
      {hosted, others} = Enum.split_with(others, &HalC2.Plugins.git_host(&1.host))
      {driven, others} = Enum.split_with(others, &Hosts.kind?(&1.kind))
      plugged = if cursors, do: plugin_listing([]), else: plugin_listing(hosted)

      identities =
        github
        |> Enum.uniq_by(& &1.host)
        |> Task.async_stream(&{&1.host, identity(&1)}, timeout: :infinity)
        |> Map.new(fn {:ok, pair} -> pair end)

      # Who is signed in on each other host a driver here can read.
      driven_viewers =
        driven
        |> Enum.uniq_by(& &1.host)
        |> Task.async_stream(&{&1.host, Hosts.viewer(&1)}, timeout: :infinity)
        |> Map.new(fn {:ok, pair} -> pair end)

      viewers =
        Map.merge(
          for({host, {:ok, login}} <- driven_viewers, into: %{}, do: {host, login}),
          for({host, {:ok, %{"login" => login}}} <- identities, into: %{}, do: {host, login})
        )

      counts = Enum.frequencies_by(github, & &1.host)

      providers =
        for({host, identity} <- identities, do: provider(host, counts[host], identity)) ++
          plugged.providers ++
          driven_providers(driven, driven_viewers) ++
          for {host, [first | _] = on_host} <- Enum.group_by(others, & &1.host) do
            %{
              "host" => host,
              "kind" => first.kind,
              "searchesOnHost" => false,
              "projectCount" => length(on_host),
              "configured" => false,
              "detail" => "This host cannot be browsed here yet."
            }
          end

      selected =
        if cursors, do: Enum.filter(github, &Map.has_key?(cursors, key(&1))), else: github

      {readable, unreadable} = Enum.split_with(selected, &Map.has_key?(viewers, &1.host))
      result = %{"viewers" => viewers, "providers" => providers}

      driven_selected =
        if cursors, do: Enum.filter(driven, &Map.has_key?(cursors, key(&1))), else: driven

      driven_batches =
        driven_selected
        |> Task.async_stream(
          &read_driven(&1, driven_viewers[&1.host], input, cursors && cursors[key(&1)]),
          max_concurrency: 12,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, batch} -> batch end)

      if readable == [] do
        failures =
          for p <- Enum.uniq_by(selected, & &1.host), {:error, e} <- [identities[p.host]], do: e

        case Enum.find(failures, &(elem(&1, 0) in [:missing, :unauthenticated])) ||
               List.first(failures) do
          failure when failure == nil or hosted != [] or driven_batches != [] ->
            batches = driven_batches

            {:ok,
             Map.merge(result, %{
               "entries" => listed(Enum.flat_map(batches, & &1.entries) ++ plugged.entries),
               "errors" =>
                 Enum.map(unreadable, &unreadable(&1, identities[&1.host])) ++
                   Enum.flat_map(batches, & &1.errors) ++ plugged.errors,
               "truncated" => Enum.any?(batches, & &1.truncated),
               "nextCursors" => for(b <- batches, b.next, into: %{}, do: {b.key, b.next})
             })}

          failure ->
            provider_error("list", failure)
        end
      else
        batches =
          readable
          |> Task.async_stream(
            &read_repository(&1, viewers[&1.host], input, cursors && cursors[key(&1)]),
            max_concurrency: 12,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, batch} -> batch end)

        batches = batches ++ driven_batches

        {:ok,
         Map.merge(result, %{
           "entries" => listed(Enum.flat_map(batches, & &1.entries) ++ plugged.entries),
           "errors" =>
             Enum.map(unreadable, &unreadable(&1, identities[&1.host])) ++
               Enum.flat_map(batches, & &1.errors) ++ plugged.errors,
           "truncated" => Enum.any?(batches, & &1.truncated),
           "nextCursors" => for(b <- batches, b.next, into: %{}, do: {b.key, b.next})
         })}
      end
    end
  end

  # Repositories read through their host's plugin, which names their entries' provider.
  defp plugin_listing(projects) do
    at = System.system_time(:millisecond)

    reads =
      for project <- projects, plugin = HalC2.Plugins.git_host(project.host) do
        {project, plugin, HalC2.Plugins.pull_requests(plugin, project.repository)}
      end

    %{
      providers:
        for {host, [{_, plugin, _} | _] = on_host} <- Enum.group_by(reads, &elem(&1, 0).host) do
          %{
            "host" => host,
            "kind" => plugin,
            "searchesOnHost" => false,
            "projectCount" => length(on_host),
            "configured" => true,
            "detail" => nil
          }
        end,
      entries:
        for {project, plugin, {:ok, items}} <- reads, item <- items do
          Map.merge(item, %{
            "provider" => plugin,
            "host" => project.host,
            "projectId" => project.id,
            "projectTitle" => project.title,
            "repository" => project.repository,
            "observedAt" => at
          })
        end,
      errors: for({project, _, {:error, _} = error} <- reads, do: unreadable(project, error))
    }
  end

  # Hosts a driver here can read, once signed in; one that is not is listed as
  # not configured, the way a host with no driver is.
  defp driven_providers(driven, viewers) do
    for {host, [first | _] = on_host} <- Enum.group_by(driven, & &1.host) do
      configured = match?({:ok, _}, viewers[host])

      %{
        "host" => host,
        "kind" => first.kind,
        "searchesOnHost" => first.kind in ["gitlab", "bitbucket"],
        "projectCount" => length(on_host),
        "configured" => configured,
        "detail" =>
          if configured do
            nil
          else
            case viewers[host] do
              {:error, {reason, _detail}} when reason in [:missing, :unauthenticated] ->
                "This host cannot be browsed here yet."

              {:error, {_reason, detail}} ->
                detail

              _ ->
                "This host cannot be browsed here yet."
            end
          end
      }
    end
  end

  # One driven host's repository: the host was asked for the state (and its own
  # text search where it has one); involvement and the row filters are applied
  # here, and the same boundary cursor as GitHub's carries the list on. The
  # cursor's boundary goes into the host read itself, so a continuation starts
  # where the last page ended instead of re-reading the newest pages.
  defp read_driven(project, {:ok, viewer}, input, cursor) do
    state = input["state"] || "open"
    limit = input["limit"] || @default_limit
    before = cursor && cursor.boundary

    case Hosts.list(project, %{state: state, query: input["query"], before: before}) do
      {:ok, %{items: items, more: more}} ->
        kept =
          for item <- items,
              state == "all" or item["state"] == state,
              involved?(item, input["involvement"] || "all", viewer),
              GitHub.row_match?(item, input["filters"], viewer, true),
              do: item

        fetched =
          if cursor,
            do: Enum.filter(kept, &no_newer?(cursor_at(&1), cursor.boundary)),
            else: kept

        after_seen =
          if cursor,
            do:
              Enum.reject(
                fetched,
                &(same_instant?(cursor_at(&1), cursor.boundary) and
                    &1["number"] in cursor.seen)
              ),
            else: fetched

        slice = Enum.take(after_seen, limit)
        truncated = more or length(after_seen) > limit

        # A page emptied by the filters above still carries on from the oldest
        # row the host read, when that moves the boundary; if it cannot move,
        # the list stops claiming more rather than offering a dead end.
        next =
          cond do
            truncated and slice != [] -> next_cursor(cursor, slice, length(slice))
            truncated and advances?(cursor, items) -> next_cursor(cursor, items, 0)
            true -> nil
          end

        at = System.system_time(:millisecond)

        %{
          key: key(project),
          entries: for(item <- slice, do: entry(project, item, viewer, at)),
          errors: [],
          truncated: truncated and next != nil,
          next: next
        }

      {:error, _} = error ->
        failed(project, unreadable(project, error))
    end
  end

  defp read_driven(project, {:error, {reason, _detail}}, _input, _cursor)
       when reason in [:missing, :unauthenticated] do
    %{key: key(project), entries: [], errors: [], truncated: false, next: nil}
  end

  defp read_driven(project, {:error, _} = error, _input, _cursor),
    do: failed(project, unreadable(project, error))

  defp read_driven(project, _viewer, _input, _cursor),
    do: %{key: key(project), entries: [], errors: [], truncated: false, next: nil}

  defp involved?(item, "authored", viewer),
    do:
      item["author"] != nil and
        String.downcase(item["author"]["login"]) == String.downcase(viewer)

  defp involved?(item, "reviewing", viewer),
    do:
      Enum.any?(
        item["reviewRequestLogins"] || [],
        &(String.downcase(&1) == String.downcase(viewer))
      )

  defp involved?(_item, _involvement, _viewer), do: true

  defp provider(host, count, identity) do
    %{
      "host" => host,
      "kind" => "github",
      "searchesOnHost" => true,
      "projectCount" => count,
      "configured" => match?({:ok, _}, identity),
      "detail" =>
        case identity do
          {:ok, _} -> nil
          {:error, {reason, detail}} -> @requirements[reason] || detail
        end
    }
  end

  defp read_repository(project, viewer, input, cursor) do
    opts = %{
      state: input["state"] || "open",
      involvement: input["involvement"] || "all",
      viewer: viewer,
      limit: input["limit"] || @default_limit,
      query: input["query"],
      filters: input["filters"],
      cursor: cursor
    }

    # A repository GitHub keeps giving up on is held back from background reads
    # (`HalC2.GitHub.Limits`). A listing is a view's read, so today a hand refresh
    # passes the hold through `invalidate/1`; a caller that lists under
    # `HalC2.GitHub.asked/1` goes through it here.
    case Limits.repository(project.host, project.repository, github_now()) do
      {:held, until, page, detail} ->
        if HalC2.GitHub.asked?(),
          do: read_list(project, viewer, input, cursor, Map.put(opts, :page, page)),
          else: failed(project, held_back(project, until, detail))

      {:ok, page} ->
        read_list(project, viewer, input, cursor, Map.put(opts, :page, page))
    end
  end

  defp read_list(project, viewer, input, cursor, opts) do
    case GitHub.list(ctx(project, nil), opts) do
      {:ok, page} ->
        Limits.repository_read(project.host, project.repository, page.page, github_now())
        at = System.system_time(:millisecond)

        # The boundary instant is asked for inclusively, so the rows already sent at
        # it come back and are dropped here.
        items =
          if cursor,
            do:
              Enum.reject(
                page.items,
                &(same_instant?(&1["updatedAt"], cursor.boundary) and
                    &1["number"] in cursor.seen)
              ),
            else: page.items

        %{
          key: key(project),
          entries:
            for(
              item <- items,
              GitHub.row_match?(item, input["filters"], viewer, false),
              do: entry(project, item, viewer, at)
            ),
          errors: [],
          truncated: page.truncated,
          next:
            if(page.sorted and page.truncated, do: next_cursor(cursor, page.items, length(items)))
        }

      {:error, {:failed, detail}} = error ->
        case gave_up(project, detail) do
          nil ->
            failed(project, unreadable(project, error))

          {until, new?} ->
            # Once per hold, not on every poll that meets it.
            if new?,
              do:
                Logger.warning(
                  "#{project.repository} could not be read: #{detail}; read again at #{clock(until)}"
                )

            failed(project, held_back(project, until, detail))
        end

      {:error, _} = error ->
        failed(project, unreadable(project, error))
    end
  end

  # GitHub giving up on the read, or `gh` not answering in time, holds the repository
  # back: `{until, new?}`, or nil for any other failure.
  defp gave_up(project, detail) do
    if GitHub.gave_up?(detail) or detail == "gh did not answer in time.",
      do: Limits.repository_failed(project.host, project.repository, github_now(), detail)
  end

  defp failed(project, error),
    do: %{key: key(project), entries: [], errors: [error], truncated: false, next: nil}

  # A repository held back after GitHub gave up on it, said with when it is read again.
  defp held_back(project, until, detail) do
    reason =
      "#{project.host} did not answer in time. #{project.repository} is read again at " <>
        "#{clock(until)}; refresh to read it now."

    error(project, reason, detail)
  end

  defp clock(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S UTC")

  defp github_now,
    do: (Application.get_env(:hal_c2, :github_clock) || (&system_ms/0)).()

  # Says why, so a caller that only sees the message (a plugin, the list's banner) can
  # tell a host that is down from a pull request that is not there. `reason` is what a
  # client shows the user; `detail` keeps what the host or its CLI said, for diagnostics.
  # Every host's failure passes here, so the wording does not depend on the provider.
  defp unreadable(project, error) do
    detail = reason(error)

    # A read the rate limit gate turned away never reached GitHub; the gate's pause is
    # the news, not each poll that meets it.
    unless detail =~ "paused until it resets at",
      do: Logger.warning("#{project.repository} could not be read: #{detail}")

    error(project, phrase(detail, project), detail)
  end

  defp error(project, reason, detail) do
    %{
      "projectId" => project.id,
      "projectTitle" => project.title,
      "repository" => project.repository,
      "reason" => reason,
      "detail" => detail,
      "message" => "#{project.repository} could not be read: #{reason}"
    }
  end

  # A host's failure in words a user can act on; what matches nothing here is the
  # host's own text (a plugin's "not running", the CLI requirements).
  defp phrase(detail, project) do
    host = project.host || "The host"

    cond do
      # `HalC2.GitHub` already says when the pause ends.
      detail =~ ~r/until it resets at/ ->
        detail

      detail =~ ~r/HTTP 429|rate limit/i ->
        "#{host}'s rate limit was reached. Try again in a few minutes."

      detail =~
          ~r/HTTP 5\d\d|timed? ?out|did not answer in time|unexpected end of JSON|deadline exceeded|connection (reset|refused)|temporarily unavailable|could not resolve|no such host/i ->
        "#{host} did not answer in time. Try again."

      detail =~ ~r/HTTP 401|bad credentials/i ->
        "#{host} did not accept the sign-in. Sign in again and retry."

      detail =~ ~r/HTTP 403/ ->
        "#{host} refused access to #{project.repository}. Check that this account may read it."

      detail =~ ~r/HTTP 404/ ->
        "#{project.repository} was not found on #{host}, or this account cannot see it."

      true ->
        detail
    end
  end

  defp reason({:error, {reason, detail}}) when is_atom(reason),
    do: @requirements[reason] || detail

  defp reason({:error, detail}) when is_binary(detail), do: detail
  defp reason(_), do: "the host did not answer."

  defp entry(project, item, viewer, at) do
    me = String.downcase(viewer)
    author = item["author"] && String.downcase(item["author"]["login"])

    item
    |> Map.take(
      ~w(number title url headBranch baseBranch state isDraft mergeability additions deletions createdAt updatedAt labels)
    )
    |> Map.merge(%{
      "provider" => project.kind,
      "host" => project.host,
      "projectId" => project.id,
      "projectTitle" => project.title,
      "repository" => project.repository,
      "author" =>
        if(project.kind == "github",
          do: GitHub.with_avatar(item["author"], project.host),
          else: item["author"]
        ),
      "observedAt" => at,
      "viewerReviewRequested" =>
        author != me and Enum.any?(item["reviewRequestLogins"], &(String.downcase(&1) == me))
    })
    |> put_present("headSha", item["headSha"])
    |> put_present("reviewDecision", item["reviewDecision"])
    |> put_present("checksState", item["checksState"])
    |> put_present("stack", item["stack"])
    # Carried only until `listed/1` sorts the merged page; dropped there.
    |> put_present("cursorAt", item["cursorAt"])
  end

  # The merged page, newest first by the instant each row is ordered and
  # carried on by (`cursor_at/1`), so loading more never brings in a row
  # that belongs before one already shown; the instant itself is the
  # listing's own and is dropped before the rows go to a client.
  defp listed(entries) do
    entries
    |> Enum.sort_by(&instant_key(cursor_at(&1)), :desc)
    |> Enum.map(&Map.delete(&1, "cursorAt"))
  end

  # A continuation is `<instant>|<rows delivered>|<numbers already sent at it>`: the
  # next slice reads that instant and everything older.
  @cursor ~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2}))\|(\d{1,9})\|(\d{1,9}(?:,\d{1,9})*)?$/

  defp decode_cursors(nil), do: {:ok, nil}

  defp decode_cursors(cursors) do
    Enum.reduce_while(cursors, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case Regex.run(@cursor, raw) do
        [_, boundary, delivered | seen] ->
          seen = seen |> List.first("") |> String.split(",", trim: true)

          cursor = %{
            boundary: boundary,
            delivered: String.to_integer(delivered),
            seen: Enum.map(seen, &String.to_integer/1)
          }

          {:cont, {:ok, Map.put(acc, key, cursor)}}

        nil ->
          {:halt, refuse("list", "The list could not be carried on from where it left off.")}
      end
    end)
  end

  # Instants are compared as instants, not as text: hosts write fractions
  # of a second at different precisions (and a cursor may carry another
  # host's spelling), where text order and time order disagree.
  defp instant(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp same_instant?(left, right) do
    case {instant(left), instant(right)} do
      {%DateTime{} = at, %DateTime{} = other} -> DateTime.compare(at, other) == :eq
      _ -> left == right
    end
  end

  defp no_newer?(text, boundary) do
    case {instant(text), instant(boundary)} do
      {%DateTime{} = at, %DateTime{} = limit} -> DateTime.compare(at, limit) != :gt
      _ -> text <= boundary
    end
  end

  defp older?(text, boundary) do
    case {instant(text), instant(boundary)} do
      {%DateTime{} = at, %DateTime{} = limit} -> DateTime.compare(at, limit) == :lt
      _ -> text < boundary
    end
  end

  # The instant a row is ordered and carried on by: its update time, except
  # where the host pages by another (Azure, by creation; see
  # `HalC2.PullRequests.Hosts`). Internal to the listing: `entry/4` does
  # not carry it to clients.
  defp cursor_at(item), do: item["cursorAt"] || item["updatedAt"]

  defp oldest(items),
    do:
      items
      |> Enum.min_by(&{instant_key(cursor_at(&1)), cursor_at(&1)})
      |> cursor_at()

  defp instant_key(text) do
    case instant(text) do
      %DateTime{} = at -> DateTime.to_unix(at, :microsecond)
      nil -> 0
    end
  end

  # Whether a cursor built from `items` would move past `previous`: an older
  # boundary, or the same one with a number at it that was not already sent.
  defp advances?(nil, items), do: items != []

  defp advances?(_previous, []), do: false

  defp advances?(previous, items) do
    boundary = oldest(items)

    older?(boundary, previous.boundary) or
      (same_instant?(boundary, previous.boundary) and
         Enum.any?(
           items,
           &(same_instant?(cursor_at(&1), boundary) and
               &1["number"] not in previous.seen)
         ))
  end

  defp next_cursor(_previous, [], _count), do: nil

  defp next_cursor(previous, fetched, count) do
    boundary = oldest(fetched)

    kept =
      if previous && same_instant?(previous.boundary, boundary), do: previous.seen, else: []

    seen =
      kept ++
        for(item <- fetched, same_instant?(cursor_at(item), boundary), do: item["number"])

    "#{boundary}|#{((previous && previous.delivered) || 0) + count}|#{Enum.join(seen, ",")}"
  end

  @doc """
  `pullRequests.listStats`: line counts for rows on the page, one aliased read per
  host. A row that cannot be answered for is left out.
  """
  def list_stats(%{"refs" => refs}) do
    by_id = Map.new(projects(), &{&1.id, &1})

    wanted =
      for ref <- refs,
          project = by_id[ref["projectId"]],
          project.kind == "github",
          same?(project.repository, ref["repository"]),
          uniq: true,
          do: {project, ref["number"]}

    stats =
      wanted
      |> Enum.group_by(fn {project, _} -> project.host end)
      |> Enum.flat_map(fn {_host, [{first, _} | _] = group} ->
        owners = Map.new(group, fn {p, n} -> {{String.downcase(p.repository), n}, p} end)
        refs = Enum.map(group, fn {p, n} -> {p.repository, n} end)

        for {repository, number, additions, deletions} <- GitHub.stats(ctx(first, nil), refs),
            project = owners[{String.downcase(repository), number}] do
          %{
            "projectId" => project.id,
            "repository" => project.repository,
            "number" => number,
            "additions" => additions,
            "deletions" => deletions
          }
        end
      end)

    {:ok, %{"stats" => stats}}
  end

  # --- one pull request ----------------------------------------------------------------

  def summary(ref) do
    read(ref, "summary", fn project, ctx ->
      at = System.system_time(:millisecond)

      with {:ok, summary} <- GitHub.summary(ctx) do
        {:ok,
         Map.merge(summary, %{
           "provider" => "github",
           "projectId" => project.id,
           "repository" => project.repository,
           "observedAt" => at
         })}
      end
    end)
  end

  def detail(ref) do
    read(ref, "detail", fn project, ctx ->
      at = System.system_time(:millisecond)
      token = Held.token()
      read_at = now()

      [detail, identity] =
        Task.await_many(
          [Task.async(fn -> GitHub.detail(ctx) end), Task.async(fn -> identity(project) end)],
          :infinity
        )

      with {:ok, detail, _head} <- held_detail(detail, project, ctx, read_at, token) do
        {:ok,
         detail
         |> Map.merge(%{
           "provider" => "github",
           "capabilities" => GitHub.capabilities(),
           "projectId" => project.id,
           "projectTitle" => project.title,
           "workspaceRoot" => project.root,
           "repository" => project.repository,
           "observedAt" => at
         })
         |> put_present("viewer", login_of(identity))}
      end
    end)
  end

  @doc """
  `pullRequests.preview`: the hover card of a pull request, from the host's narrow
  read. One read in the last 15 seconds answers it, a preview or one cut from a full
  details read (`HalC2.PullRequests.Held`); a details read still in flight is never
  waited on. While the host's rate limit pauses reads (GitHub's, every call to it:
  `HalC2.GitHub.Limits`), held previews are still answered and the rest refused until
  it resets.
  """
  def preview(ref) do
    read(
      ref,
      "preview",
      fn project, ctx ->
        key = held_key(project, ctx.number)

        case Held.lookup(key, now()) do
          {:ok, preview} ->
            {:ok, preview}

          {:paused, until} ->
            paused(project, until)

          {:miss, token} ->
            read_at = now()

            case host_preview(project, ctx) do
              {:ok, preview} ->
                preview = preview_fields(preview, project)
                Held.put_preview(key, preview, read_at, token)
                {:ok, preview}

              error ->
                limited(error, project)
            end
        end
      end,
      ["github", "gitlab"]
    )
  end

  # GitHub has a narrow read for a preview; a host without one answers from its full
  # read, cut down to the same fields. Its CLI's own failures are told as they are, not
  # as `gh`'s.
  defp host_preview(%{kind: "github"}, ctx), do: GitHub.preview(ctx)

  defp host_preview(project, ctx) do
    case ChangeRequests.view(project.root, project, ctx.number) do
      {:error, {reason, detail}} when reason in [:missing, :unauthenticated] ->
        {:error, {:failed, detail}}

      other ->
        other
    end
  end

  # `PullRequestPreview`'s fields, from a preview or a full read.
  defp preview_fields(read, project) do
    read
    |> Map.take(~w(number title url author state isDraft createdAt))
    |> Map.merge(%{"projectId" => project.id, "repository" => project.repository})
  end

  defp held_detail({:ok, detail, _head} = read, project, ctx, read_at, token) do
    Held.put_detail(
      held_key(project, ctx.number),
      preview_fields(detail, project),
      read_at,
      token
    )

    read
  end

  # GitHub's rate limit is kept in `HalC2.GitHub.Limits`, which every `gh` call passes.
  defp held_detail(error, _project, _ctx, _read_at, _token), do: error

  defp held_key(project, number),
    do: {lower(project.host), lower(project.repository), number, project.id}

  # A host's rate limit pauses its previews until it resets: GitHub's every call, in
  # `HalC2.GitHub.Limits`; another host's previews, in `Held`.
  defp limited({:error, {:rate_limited, detail}}, %{kind: "github"}),
    do: refuse("preview", detail)

  defp limited(error, project) do
    if rate_limited?(error),
      do: paused(project, Held.rate_limited(lower(project.host), now())),
      else: error
  end

  defp rate_limited?({:error, {_, detail}}) when is_binary(detail),
    do: detail =~ ~r/HTTP 429|rate limit/i

  defp rate_limited?(_), do: false

  defp lower(nil), do: ""
  defp lower(text), do: String.downcase(text)

  defp paused(project, until) do
    resets = DateTime.from_unix!(until, :millisecond) |> Calendar.strftime("%H:%M:%S UTC")

    refuse(
      "preview",
      "#{project.host}'s rate limit was reached; previews are paused until it resets at #{resets}."
    )
  end

  # Milliseconds since the epoch; `:pull_requests_clock` stands in for the system clock.
  defp now, do: (Application.get_env(:hal_c2, :pull_requests_clock) || (&system_ms/0)).()

  defp system_ms, do: System.system_time(:millisecond)

  def checks(ref) do
    read(ref, "checks", fn _project, ctx ->
      with {:ok, detail, _head} <- GitHub.detail(ctx),
           do: {:ok, %{"state" => detail["state"], "checks" => detail["checks"]}}
    end)
  end

  def activity(ref), do: read(ref, "activity", fn _project, ctx -> GitHub.activity(ctx) end)

  def thread_comments(input),
    do:
      read(input, "threadComments", fn _project, ctx ->
        GitHub.thread_comments(ctx, input["threadId"], input["cursor"])
      end)

  def diff_file_contents(input),
    do: read(input, "diffFileContents", fn _project, ctx -> GitHub.file_contents(ctx, input) end)

  def files_viewed(ref),
    do: read(ref, "filesViewed", fn _project, ctx -> GitHub.files_viewed(ctx) end)

  # Ticking a file says nothing about the pull request, so nobody is told to read again.
  def set_files_viewed(input),
    do:
      read(input, "setFilesViewed", fn _project, ctx ->
        GitHub.set_files_viewed(ctx, input["files"] || [])
      end)

  @doc "`POST /api/pull-requests/diff`: a slice of the patch (`PullRequestDiffResult`)."
  def diff(input),
    do:
      read(input, "diff", fn _project, ctx ->
        GitHub.diff(ctx, input["cursor"], input["commit"])
      end)

  @doc "`diff/1` on the MC that holds the project, for a request that reached any MC."
  def diff_on_project_mc(input) do
    id = input["projectId"]

    owner =
      Enum.find_value(HalC2.Shell.rows(), node(), fn
        {{mc, ^id}, {"project", _}} -> mc
        _ -> nil
      end)

    :erpc.call(owner, __MODULE__, :diff, [input], 150_000)
  catch
    _, _ -> refuse("diff", "The MC holding this project is unavailable.")
  end

  @doc "The host-native stack a pull request is in, or nil; `details?` false skips its second read."
  def stack(ref, details? \\ true),
    do: read(ref, "stack", fn _project, ctx -> GitHub.stack(ctx, details?) end)

  @doc """
  Summaries for pull requests on this MC's GitHub hosts, keyed by the refs asked
  for (`%{"host", "repository", "number"}`), read in one batch per host through any
  checkout there. A ref no checkout here can answer for, or GitHub left unanswered, is
  absent.
  """
  def summaries(refs) do
    checkouts = projects() |> Enum.filter(&(&1.kind == "github")) |> Enum.group_by(& &1.host)

    refs
    |> Enum.group_by(&String.downcase(&1["host"] || ""))
    |> Enum.flat_map(fn {host, refs} ->
      case checkouts[host] do
        [project | _] ->
          found =
            GitHub.summaries(ctx(project, nil), Enum.map(refs, &{&1["repository"], &1["number"]}))

          for ref <- refs,
              summary = found[{String.downcase(ref["repository"]), ref["number"]}],
              do: {ref, summary}

        nil ->
          []
      end
    end)
    |> Map.new()
  end

  # --- changes ----------------------------------------------------------------------

  # A writer is refused enabling auto-merge only where GitHub would not wait.
  defp refusal("enable-auto-merge", viewer) do
    if "merge" in viewer["actions"],
      do: @auto_merge_refusal,
      else: @action_refusals["enable-auto-merge"]
  end

  # The toggle offered follows the current state, so a request that already holds
  # (the page was stale) is answered as such, not as a lack of rights.
  defp refusal("allow-maintainer-edits", %{"actions" => actions} = viewer) do
    if "stop-maintainer-edits" in actions,
      do: "Maintainers can already edit this branch.",
      else: refusal_default("allow-maintainer-edits", viewer)
  end

  defp refusal("stop-maintainer-edits", %{"actions" => actions} = viewer) do
    if "allow-maintainer-edits" in actions,
      do: "Maintainers already can't edit this branch.",
      else: refusal_default("stop-maintainer-edits", viewer)
  end

  defp refusal(action, viewer), do: refusal_default(action, viewer)
  defp refusal_default(action, _viewer), do: @action_refusals[action]

  @doc """
  `pullRequests.runAction`: refused when GitHub cannot do it or this account may not,
  asked of the host fresh. Stack actions are not served.
  """
  def run_action(input) do
    input
    |> change("runAction", fn _project, ctx ->
      action = input["action"]
      capabilities = GitHub.capabilities()

      cond do
        input["stackNumber"] != nil and
            (capabilities["stackActions"] != true or action not in ["merge", "update-branch"] or
               input["expectedStackHeads"] == nil or
               (action == "update-branch" and input["updateMethod"] != "rebase")) ->
          refuse(
            "runAction",
            "This stack action is not supported or has no expected head revision."
          )

        action not in capabilities["actions"] ->
          refuse("runAction", "This host cannot #{action} a change request.")

        input["mergeMethod"] && input["mergeMethod"] not in capabilities["mergeMethods"] ->
          refuse("runAction", "This host cannot merge with the #{input["mergeMethod"]} strategy.")

        input["updateMethod"] && input["updateMethod"] not in capabilities["updateMethods"] ->
          refuse("runAction", "This host cannot update a branch by #{input["updateMethod"]}.")

        true ->
          # Rebasing a stack needs write access to its branches, not GitHub's
          # update-branch button on this one.
          stack_rebase = input["stackNumber"] != nil and action == "update-branch"

          with {:ok, viewer} <-
                 GitHub.viewer_permissions(
                   ctx,
                   action == "update-branch"
                 ) do
            cond do
              if(stack_rebase,
                do: viewer["stackRebase"] != true,
                else: action not in viewer["actions"]
              ) ->
                refuse("runAction", refusal(action, viewer))

              (not stack_rebase and input["updateMethod"]) &&
                  input["updateMethod"] not in (viewer["updateMethods"] || []) ->
                refuse("runAction", @action_refusals["update-branch"])

              input["stackNumber"] != nil ->
                HalC2.PullRequests.GitHubStack.run(ctx, input)

              true ->
                GitHub.action(ctx, action, input["mergeMethod"], input["updateMethod"])
            end
          end
      end
    end)
    # Linked threads show what the action did without waiting for the next sweep.
    |> tap(&if(match?({:ok, _}, &1), do: HalC2.PullRequests.Sync.request(input)))
  end

  # Rewriting is left to the host to allow: whoever wrote something may rewrite it,
  # and no host reports that as a permission.
  def update(input) do
    host_refusal(input, "update", :edit_change_request) ||
      change(input, "update", fn _project, ctx ->
        case Map.take(input, ["title", "body"]) do
          fields when fields == %{} -> refuse("update", "Nothing was changed.")
          fields -> GitHub.update(ctx, fields)
        end
      end)
  end

  def comment(input) do
    unless_blank(input["body"], "comment", "A comment cannot be empty.", fn ->
      host_refusal(input, "comment", :comment) ||
        change(input, "comment", fn _project, ctx -> GitHub.comment(ctx, input["body"]) end)
    end)
  end

  def update_comment(input) do
    unless_blank(input["body"], "updateComment", "A comment cannot be empty.", fn ->
      host_refusal(input, "updateComment", :edit_comment) ||
        change(input, "updateComment", fn _project, ctx ->
          GitHub.update_comment(ctx, input["commentId"], input["kind"], input["body"])
        end)
    end)
  end

  def submit_review(input) do
    review_refusal(input) ||
      submit_review_on_host(input)
  end

  defp submit_review_on_host(input) do
    change(input, "submitReview", fn _project, ctx ->
      verdict = input["verdict"]
      comments = input["comments"] || []

      if verdict != "approve" and String.trim(input["body"] || "") == "" and comments == [] do
        refuse("submitReview", "A review needs a summary or at least one comment.")
      else
        # Only an author is held to comments (`GitHub.permissions/1`).
        with {:ok, viewer} <- GitHub.viewer_permissions(ctx) do
          if verdict in viewer["verdicts"],
            do:
              GitHub.submit_review(ctx, verdict, input["body"] || "", comments, input["commitId"]),
            else:
              refuse(
                "submitReview",
                "You cannot #{@verdict_labels[verdict]} your own change request."
              )
        end
      end
    end)
  end

  def reply_to_thread(input) do
    unless_blank(input["body"], "replyToThread", "A reply cannot be empty.", fn ->
      host_refusal(input, "replyToThread", :reply) ||
        change(input, "replyToThread", fn _project, ctx ->
          GitHub.reply(ctx, input["threadId"], input["body"])
        end)
    end)
  end

  def set_thread_resolution(input) do
    host_refusal(input, "setThreadResolution", :resolve) ||
      set_thread_resolution_on_host(input)
  end

  defp set_thread_resolution_on_host(input) do
    change(input, "setThreadResolution", fn _project, ctx ->
      with {:ok, viewer} <- GitHub.viewer_permissions(ctx) do
        if viewer["resolve"],
          do: GitHub.resolve(ctx, input["threadId"], input["resolved"]),
          else:
            refuse(
              "setThreadResolution",
              "You need write access on this repository, or to have opened this change request, to resolve a review conversation."
            )
      end
    end)
  end

  # Anyone who can read a pull request may react to it.
  def set_reaction(input) do
    host_refusal(input, "setReaction", :reactions) ||
      change(input, "setReaction", fn _project, ctx ->
        GitHub.react(ctx, input["subjectId"], input["content"], input["reacted"])
      end)
  end

  @doc "Who a review may be asked of, only for someone who may ask."
  def reviewer_candidates(ref) do
    read(ref, "reviewerCandidates", fn _project, ctx ->
      permitted(ctx, "reviewerCandidates", "requestReviewers", @reviewer_refusal, fn ->
        GitHub.reviewer_candidates(ctx)
      end)
    end)
  end

  def request_reviewers(input) do
    change(input, "requestReviewers", fn _project, ctx ->
      permitted(ctx, "requestReviewers", "requestReviewers", @reviewer_refusal, fn ->
        GitHub.request_reviewers(ctx, input["reviewers"], input["requested"])
      end)
    end)
  end

  def label_candidates(ref) do
    read(ref, "labelCandidates", fn _project, ctx ->
      permitted(ctx, "labelCandidates", "labels", @label_refusal, fn ->
        GitHub.label_candidates(ctx)
      end)
    end)
  end

  def set_labels(input) do
    change(input, "setLabels", fn _project, ctx ->
      permitted(ctx, "setLabels", "labels", @label_refusal, fn ->
        GitHub.set_labels(ctx, input["labels"], input["applied"] == true)
      end)
    end)
  end

  @doc """
  `pullRequests.invalidate`: forgets the held previews of the reference, or with no
  reference every one and who is signed in. Readers are told to read again, except
  for a refresh of review marks alone.
  """
  def invalidate(input) do
    if input["filesViewedOnly"] != true do
      if input["reference"] == nil, do: :persistent_term.erase(@viewers)
      if input["reference"] == nil, do: :persistent_term.erase(@ssh_hosts)
      forget(input["reference"])
      # A reader asking for fresh host state wants the thread links it feeds to follow.
      if input["reference"], do: HalC2.PullRequests.Sync.request(input["reference"])
      Refreshes.bump()
    end

    {:ok, nil}
  end

  # A hand refresh also lets a repository GitHub kept giving up on be read at once.
  defp forget(nil) do
    Limits.release()
    Held.forget_all()
    Branches.forget()
  end

  defp forget(reference) do
    with {:ok, project} <- project_for(reference) do
      Limits.release(project.host, project.repository)
      Held.forget(project.host, project.repository, reference["number"])
      Branches.forget_pull_request(project.repository, reference["number"])
    end
  end

  @doc """
  A turn that ran in `cwd` may have pushed to its repository or changed its pull
  requests: what is held of that repository's pull requests is dropped, and only that.
  """
  def turn_finished(cwd) do
    with true <- Held.holding?(),
         %{host: host, repository: repository} <- remote(cwd),
         do: Held.forget(host, repository)

    :ok
  end

  # --- routing ----------------------------------------------------------------------

  @doc "`pullRequests.routing`: the account and checkout a reference is served through."
  def routing(ref) do
    read(ref, "routeIdentity", fn project, _ctx ->
      with {:ok, %{"id" => id, "login" => login}} <- identity(project) do
        {:ok,
         %{
           "accountId" => id,
           "viewer" => login,
           "host" => project.host,
           "provider" => "github",
           "projectTitle" => project.title,
           "workspaceRoot" => project.root
         }}
      end
    end)
  end

  @doc "`pullRequests.routingIdentity`: who `gh` is signed in as on a host this MC has."
  def routing_identity(%{"host" => host}) do
    host = host |> String.trim() |> String.downcase()

    case Enum.find(projects(), &(&1.kind == "github" and &1.host == host)) do
      nil ->
        unavailable("provider-unsupported", nil)

      project ->
        case identity(project) do
          {:ok, %{"id" => id, "login" => login}} ->
            {:ok, %{"accountId" => id, "viewer" => login, "host" => host, "provider" => "github"}}

          {:error, failure} ->
            provider_error("routeIdentity", failure)
        end
    end
  end

  @doc """
  The host-level key (`%{"host", "repository", "number"}`) a checkout-scoped
  reference (`%{"projectId", "repository", "number"}`, with `"host"` when it
  names one) belongs to, or nil when it cannot be identified. The host is the
  reference's own when it names one, else its project's checkout's. A host
  whose tools select a repository by its bare name (Azure DevOps) can only
  key such a reference through the project's own repository, under its
  canonical `org/project/_git/name` on `dev.azure.com`, however the checkout
  was cloned.
  """
  def sync_key(ref) do
    identity = if ref["projectId"], do: identity_for(ref["projectId"])
    sync_key(ref, identity)
  end

  # The one project's checkout identity (`remote/1` on its root only), so a
  # reference is resolved without asking git about every project on the MC.
  defp identity_for(id) do
    case HalC2.Shell.row(node(), id) do
      {"project", %{"workspaceRoot" => root} = project} when is_binary(root) ->
        if project["deletedAt"] == nil, do: remote(root)

      _ ->
        nil
    end
  end

  @doc "As `sync_key/1`, with the project's checkout (`%{host, repository, kind}`) given."
  def sync_key(ref, identity) do
    alias HalC2.Projection.PullRequests, as: Links

    repository = String.trim(ref["repository"] || "")
    number = ref["number"]

    canonical =
      if identity do
        Links.normalize(%{
          "host" => identity.host,
          "repository" => identity.repository,
          "number" => number
        })
      end

    cond do
      identity && identity.kind == "azure-devops" && !String.contains?(repository, "/") ->
        selector = canonical["repository"] |> String.split("/") |> List.last()

        host =
          ref["host"] && ref["host"] |> String.trim() |> String.downcase() |> azure_host()

        if String.downcase(repository) == selector && host in [nil, canonical["host"]],
          do: canonical

      true ->
        host =
          (ref["host"] && ref["host"] |> String.trim() |> String.downcase()) ||
            (canonical && canonical["host"])

        if host do
          Links.normalize(%{"host" => host, "repository" => repository, "number" => number})
        end
    end
  end

  # Every Azure DevOps host spelling names the one canonical host.
  defp azure_host(host) do
    if host in ["ssh.dev.azure.com", "vs-ssh.visualstudio.com"] or
         String.ends_with?(host, [".dev.azure.com", ".visualstudio.com"]),
       do: "dev.azure.com",
       else: host
  end

  @doc "`pullRequests.linkedThreads`: this MC's threads linked to the pull request."
  def linked_threads(ref) do
    {host, repository} =
      case sync_key(ref) do
        %{"host" => host, "repository" => repository} ->
          {host, repository}

        nil ->
          {nil, String.downcase(String.trim(ref["repository"] || ""))}
      end

    threads =
      for {{mc, _}, {"thread", row}} <- HalC2.Shell.rows(),
          host != nil and mc == node() and row["deletedAt"] == nil,
          Enum.any?(row["pullRequests"] || [], &linked?(&1, host, repository, ref["number"])) do
        row
      end
      |> Enum.sort_by(& &1["id"])
      |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
      |> Enum.map(
        &%{
          "id" => &1["id"],
          "projectId" => &1["projectId"],
          "title" => &1["title"] || "",
          "archivedAt" => &1["archivedAt"]
        }
      )

    {:ok, %{"threads" => threads}}
  rescue
    error ->
      Logger.warning("linked threads could not be loaded: #{Exception.message(error)}")
      refuse("linkedThreads", "Could not load linked threads.")
  catch
    kind, reason ->
      Logger.warning("linked threads could not be loaded: #{kind} #{inspect(reason)}")
      refuse("linkedThreads", "Could not load linked threads.")
  end

  defp linked?(link, host, repository, number) do
    normalized = HalC2.Projection.PullRequests.normalize(link)

    link["source"] != "stack-dismissed" and
      normalized == %{"host" => host, "repository" => repository, "number" => number}
  end

  # --- projects -----------------------------------------------------------------------

  # This MC's projects whose checkout has a remote, as
  # `%{id, title, root, host, repository, kind}`.
  @doc "This MC's projects whose checkout has a remote, with its host and repository."
  def projects do
    for {{mc, id}, {"project", %{"workspaceRoot" => root} = project}} <- HalC2.Shell.rows(),
        mc == node() and is_binary(root) and project["deletedAt"] == nil,
        remote = remote(root) do
      Map.merge(remote, %{
        id: project["id"] || id,
        title: project["title"] || Path.basename(root),
        root: root
      })
    end
    |> Enum.sort_by(& &1.id)
  end

  # Worktrees of one repository are separate projects; each repository is read once.
  defp workspace(input) do
    host = input["host"] && String.downcase(input["host"])

    projects()
    |> Enum.filter(fn p ->
      (input["projectId"] == nil or p.id == input["projectId"]) and
        (input["projectIds"] == nil or p.id in input["projectIds"]) and
        (host == nil or p.host == host)
    end)
    |> Enum.uniq_by(&key/1)
  end

  # How a listing tells repositories apart: the same `owner/repo` can live on two hosts.
  defp key(project), do: "#{project.host} #{String.downcase(project.repository)}"

  defp remote(root) do
    with {:ok, out} <- HalC2.Git.ok(root, ~w(remote -v)),
         remotes =
           for(
             line <- String.split(out, "\n"),
             [name, url | _] <- [String.split(line)],
             do: {name, url}
           ),
         {_, url} <- List.keyfind(remotes, "origin", 0) || List.first(remotes) do
      url |> parse_remote() |> resolve_ssh_alias()
    else
      _ -> nil
    end
  end

  # A remote spelled as an SSH alias (`git@work-gitlab:acme/infra.git`) names no
  # host the kind rules know; the alias's `HostName` in `~/.ssh/config` does, so
  # the project is read as that host's kind. An alias that resolves to nothing
  # recognisable stays unknown.
  defp resolve_ssh_alias(%{kind: "unknown", host: host} = remote) do
    case ssh_hostname(host) do
      nil -> remote
      hostname -> %{remote | host: hostname, kind: kind(hostname)}
    end
  end

  defp resolve_ssh_alias(remote), do: remote

  # Resolving an alias can start `ssh` (and evaluate the user's config), and
  # `projects/0` asks once per project on unrecognised hosts on every list
  # read, so an answer is held per alias until the configs it came from
  # change: keyed on the newest modification time of the two configs, their
  # conventional `Include` directories (`config.d`, `ssh_config.d`, whose own
  # time moves when a file in them is added or removed) and the files in
  # them, and forgotten with the signed-in accounts on `invalidate/1`. An
  # edit to a file included from anywhere else needs that refresh. Answers
  # held under an older stamp are dropped when a new one is stored. A host that resolves to
  # nothing is held too, so a self-hosted forge under an unrecognised name
  # does not pay for `ssh` on every read either.
  defp ssh_hostname(alias_name) do
    config = ssh_config()
    stamp = ssh_config_stamp(config)
    held = :persistent_term.get(@ssh_hosts, %{})
    key = {config, stamp, String.downcase(alias_name)}

    case Map.fetch(held, key) do
      {:ok, :none} ->
        nil

      {:ok, hostname} ->
        hostname

      :error ->
        hostname = ssh_g_hostname(alias_name, config) || ssh_config_hostname(alias_name, config)
        current = for {{^config, ^stamp, _} = k, v} <- held, into: %{}, do: {k, v}
        :persistent_term.put(@ssh_hosts, Map.put(current, key, hostname || :none))
        hostname
    end
  end

  defp ssh_config,
    do: Path.join([System.get_env("HOME") || System.user_home() || "", ".ssh", "config"])

  defp ssh_config_stamp(config) do
    dirs = [config <> ".d", "/etc/ssh/ssh_config.d"]

    included =
      for dir <- dirs,
          {:ok, names} <- [File.ls(dir)],
          name <- names,
          do: Path.join(dir, name)

    [config, "/etc/ssh/ssh_config" | dirs ++ included]
    |> Enum.map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, stat} -> stat.mtime
        _ -> 0
      end
    end)
    |> Enum.max()
  end

  # How `ssh` itself resolves the alias (`ssh -G` prints the effective
  # configuration without connecting), which follows `Include`s, `Host=`
  # spellings and wildcard patterns the way a real connection would. The
  # alias comes from a git remote, so only a plain host name is ever
  # handed to `ssh`: nothing that could be read as one of its options.
  # Evaluating the config is `ssh`'s own work on the user's own config,
  # the same a `git` transport through this alias would do.
  defp ssh_g_hostname(alias_name, config) do
    if alias_name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ do
      # `ssh` reads the config under the account's home, not `$HOME`, so
      # name the config under the MC's home when there is one there.
      args =
        if File.regular?(config), do: ["-G", "-F", config, alias_name], else: ["-G", alias_name]

      case Cli.run("ssh", args, timeout: 5_000) do
        {:ok, out, _} ->
          Enum.find_value(String.split(out, ~r/\r?\n/), fn line ->
            case Regex.run(~r/^hostname\s+(\S+)$/i, String.trim(line)) do
              [_, hostname] ->
                hostname = String.downcase(hostname)
                if hostname != String.downcase(alias_name), do: hostname

              _ ->
                nil
            end
          end)

        _ ->
          nil
      end
    end
  end

  # The plain reading of the config file, for a machine with no `ssh` to
  # ask: only the one config under the MC's own home, the same file named
  # to `ssh -G` above (under `$HOME` when it is set, else the account's
  # home, which is where `ssh` itself looks).
  # sobelow_skip ["Traversal.FileModule"]
  defp ssh_config_hostname(alias_name, path) do
    with {:ok, text} <- File.read(path) do
      text
      |> String.split(~r/\r?\n/)
      |> Enum.chunk_while(
        nil,
        fn line, block ->
          if line =~ ~r/^\s*Host\s+/i,
            do: {:cont, block, [line]},
            else: {:cont, (block || []) ++ [line]}
        end,
        fn block -> {:cont, block, nil} end
      )
      |> Enum.find_value(fn
        [head | rest] ->
          names =
            head |> String.trim() |> String.split(~r/\s+/) |> tl() |> Enum.map(&String.downcase/1)

          if alias_name in names do
            Enum.find_value(rest, fn line ->
              case Regex.run(~r/^\s*HostName\s+(\S+)/i, line) do
                [_, hostname] -> String.downcase(hostname)
                _ -> nil
              end
            end)
          end

        _ ->
          nil
      end)
    else
      _ -> nil
    end
  end

  @doc "A git remote URL's host, repository path and host kind, or nil."
  def parse_remote(url) do
    url = String.trim(url)

    {host, path} =
      cond do
        String.contains?(url, "://") ->
          case URI.new(url) do
            {:ok, %URI{host: host, path: path}} when is_binary(host) and host != "" ->
              {host, path || ""}

            _ ->
              {nil, ""}
          end

        match = Regex.run(~r/^[A-Za-z0-9._-]+@([^:\/]+):(.+)$/, url) ->
          {Enum.at(match, 1), Enum.at(match, 2)}

        true ->
          {nil, ""}
      end

    repository = path |> String.trim("/") |> String.replace_suffix(".git", "")

    if host && repository != "" do
      host = String.downcase(host)
      kind = kind(host)

      # GitHub names a repository `owner/name`; anything else is not addressable there.
      if kind != "github" or Regex.match?(~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/, repository),
        do: %{host: host, repository: repository, kind: kind}
    end
  end

  defp kind(host) do
    labels = String.split(host, ".")

    cond do
      host == "codeberg.org" or "forgejo" in labels or "gitea" in labels ->
        "forgejo"

      host == "github.com" or "github" in labels ->
        "github"

      host == "gitlab.com" or "gitlab" in labels ->
        "gitlab"

      host == "dev.azure.com" or String.ends_with?(host, [".dev.azure.com", ".visualstudio.com"]) ->
        "azure-devops"

      host == "bitbucket.org" or "bitbucket" in labels ->
        "bitbucket"

      true ->
        "unknown"
    end
  end

  # The project that serves a reference: its own when the repository is its own,
  # else, for a reference that names a host, a checkout on that host. Only GitHub is
  # browsed; an operation names the other hosts it can serve in `kinds`.
  defp project_for(ref, kinds \\ ["github"]) do
    all = projects()
    own = Enum.find(all, &(&1.id == ref["projectId"]))
    repository = String.trim(ref["repository"] || "")
    host = ref["host"] && ref["host"] |> String.trim() |> String.downcase()

    project =
      cond do
        own && same?(own.repository, repository) && host in [nil, own.host] ->
          {:ok, own}

        host == nil and own == nil ->
          unavailable("provider-unsupported", nil)

        host == nil ->
          refuse(
            "resolveRepository",
            "The change request does not belong to the selected project."
          )

        true ->
          on_host = Enum.filter(all, &(&1.host == host))

          case Enum.find(on_host, &same?(&1.repository, repository)) || List.first(on_host) do
            nil -> unavailable("provider-unsupported", nil)
            route -> {:ok, %{route | repository: repository}}
          end
      end

    with {:ok, project} <- project do
      cond do
        project.kind not in kinds ->
          unavailable("provider-unsupported", project.kind)

        project.kind == "github" and
            not Regex.match?(~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/, project.repository) ->
          refuse("resolveRepository", "The repository cannot be addressed on GitHub.")

        true ->
          verified(project, ref)
      end
    end
  end

  # A routed operation names the account it expects to act as; anything else is refused.
  defp verified(project, %{"expectedAccountId" => expected} = ref) when is_binary(expected) do
    host = ref["host"] && String.downcase(ref["host"])

    case host == project.host && identity(project) do
      {:ok, %{"id" => ^expected}} ->
        {:ok, project}

      _ ->
        refuse(
          "routeIdentity",
          "The GitHub account could not be verified before starting the operation."
        )
    end
  end

  defp verified(project, _ref), do: {:ok, project}

  defp same?(left, right), do: String.downcase(left) == String.downcase(String.trim(right || ""))

  defp ctx(project, number),
    do: %{cwd: project.root, host: project.host, repository: project.repository, number: number}

  # Who is signed in to the project's host, believed for ten minutes per credential:
  # signing in as someone else is noticed at once.
  defp identity(%{host: host, root: root}) do
    now = System.monotonic_time(:millisecond)
    held = :persistent_term.get(@viewers, %{})
    key = {host, GitHub.credential_fingerprint(root, host)}

    case held[key] do
      {at, identity} when now - at < @viewer_ttl ->
        {:ok, identity}

      _ ->
        with {:ok, identity} <- GitHub.viewer(root, host) do
          :persistent_term.put(@viewers, Map.put(held, key, {now, identity}))
          {:ok, identity}
        end
    end
  end

  # --- plumbing -----------------------------------------------------------------------

  defp read(ref, operation, fun, kinds \\ ["github"]) do
    with {:ok, project} <- project_for(ref, kinds) do
      case fun.(project, ctx(project, ref["number"])) do
        :ok ->
          {:ok, nil}

        {:error, {reason, detail}} when is_atom(reason) ->
          provider_error(operation, {reason, detail})

        other ->
          other
      end
    end
  end

  # A change forgets what is held of the pull request, whether or not the host took it.
  defp change(ref, operation, fun) do
    forgetting = fn project, ctx ->
      try do
        fun.(project, ctx)
      after
        Held.forget(project.host, project.repository, ctx.number)
        Branches.forget_pull_request(project.repository, ctx.number)
      end
    end

    with {:ok, _} = done <- read(ref, operation, forgetting) do
      Refreshes.bump()
      done
    end
  end

  defp permitted(ctx, operation, permission, refusal, fun) do
    with {:ok, viewer} <- GitHub.viewer_permissions(ctx) do
      if viewer[permission] == false, do: refuse(operation, refusal), else: fun.()
    end
  end

  # Markdown keeps its whitespace, so a body of nothing but whitespace is refused here.
  defp unless_blank(body, operation, detail, fun) do
    if String.trim(body || "") == "", do: refuse(operation, detail), else: fun.()
  end

  # The kind of the host a reference names, from its project's checkout (or the
  # host it names), without asking that host anything.
  defp ref_kind(ref) do
    project = Enum.find(projects(), &(&1.id == ref["projectId"]))

    cond do
      project -> project.kind
      is_binary(ref["host"]) -> kind(String.downcase(String.trim(ref["host"])))
      true -> nil
    end
  end

  # `refuse/2` for a thing the reference's host cannot do at all
  # (`@host_capabilities`), or nil where it can — or where no provider here
  # claims the host either way, which `project_for/2` then answers for.
  defp host_refusal(ref, operation, capability) do
    capabilities = @host_capabilities[ref_kind(ref)] || %{}

    if capabilities[capability] == false,
      do: refuse(operation, @host_refusal_details[capability])
  end

  # As `host_refusal/3`, for a review: a line comment on a host without them is
  # refused for that first, then a verdict the host does not take.
  defp review_refusal(input) do
    capabilities = @host_capabilities[ref_kind(input)] || %{}
    verdict = input["verdict"]

    cond do
      not Map.has_key?(@verdict_labels, verdict) ->
        refuse("submitReview", "A review needs a verdict: approve, request changes or comment.")

      (input["comments"] || []) != [] and capabilities[:inline] == false ->
        refuse("submitReview", @host_refusal_details.inline)

      is_list(capabilities[:verdicts]) and verdict not in capabilities.verdicts ->
        refuse("submitReview", "This host cannot #{@verdict_labels[verdict]} a change request.")

      true ->
        nil
    end
  end

  defp provider_error(_operation, {:missing, _}), do: unavailable("cli-missing", "github")

  defp provider_error(_operation, {:unauthenticated, _}),
    do: unavailable("cli-unauthenticated", "github")

  defp provider_error(operation, {_reason, detail}), do: refuse(operation, detail)

  defp unavailable(reason, provider) do
    message =
      case reason do
        "cli-missing" -> @requirements.missing
        "cli-unauthenticated" -> @requirements.unauthenticated
        _ -> "Change requests cannot be browsed for this project's host yet."
      end

    {:error,
     %{"_tag" => "PullRequestUnavailableError", "reason" => reason, "message" => message}
     |> put_present("provider", provider)}
  end

  defp refuse(operation, detail),
    do:
      {:error,
       %{
         "_tag" => "PullRequestOperationError",
         "operation" => operation,
         "detail" => detail,
         "message" => "Pull request operation #{operation} failed: #{detail}"
       }}

  @doc "What to do when `gh` is `:missing` or `:unauthenticated`, as the user is told."
  def requirement(reason), do: @requirements[reason]

  defp login_of({:ok, %{"login" => login}}), do: login
  defp login_of(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
