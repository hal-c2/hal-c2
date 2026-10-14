defmodule HalC2.Issues do
  @moduledoc """
  A repository's issues, milestones, sub-issues and dependencies, and the boards
  (GitHub Projects) they sit on, for MC plugins (`HalC2.Plugins.Host.issues/3`).

  Every input names `projectId`, the HAL-C2 project whose checkout and host serve
  the call, and most name `repository` (`owner/name`, default the project's own) on
  that host. Another issue is a reference `%{"repository", "number"}` whose
  repository defaults to the input's. GitHub is read and changed through the
  machine's `gh` login (`HalC2.PullRequests.GitHub`); projects on other hosts are
  refused for now. Answers are host-neutral camelCase maps and failures are
  `{:error, message}`. Nothing is kept here: every call asks the host.
  """

  alias HalC2.PullRequests
  alias HalC2.PullRequests.GitHub

  @methods %{
    "list" => :list,
    "detail" => :detail,
    "milestones" => :milestones,
    "boards" => :boards,
    "board" => :board,
    "create" => :create,
    "update" => :update,
    "comment" => :comment,
    "createMilestone" => :create_milestone,
    "updateMilestone" => :update_milestone,
    "addSubIssue" => :add_sub_issue,
    "removeSubIssue" => :remove_sub_issue,
    "addBlockedBy" => :add_blocked_by,
    "removeBlockedBy" => :remove_blocked_by,
    "addBoardItem" => :add_board_item,
    "setBoardField" => :set_board_field
  }

  @writes ~w(create update comment createMilestone updateMilestone addSubIssue removeSubIssue
             addBlockedBy removeBlockedBy addBoardItem setBoardField)

  @page 100
  @repository ~r/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/
  @date ~r/^\d{4}-\d{2}-\d{2}$/
  @scope "gh may not read boards with its current login. Run `gh auth refresh -s project` and try again."

  @ref "number repository { nameWithOwner }"

  @issue_fields """
  fragment IssueFields on Issue {
    number title body state stateReason url createdAt updatedAt closedAt
    repository { nameWithOwner }
    author { login }
    assignees(first: 20) { nodes { login } }
    labels(first: 50) { nodes { name } }
    milestone { number title dueOn }
    issueType { name }
    parent { #{@ref} }
    subIssues(first: 100) { nodes { #{@ref} } }
    subIssuesSummary { total completed }
    blockedBy(first: 50) { nodes { #{@ref} } }
    blocking(first: 50) { nodes { #{@ref} } }
    closedByPullRequestsReferences(first: 100, includeClosedPrs: true) {
      nodes { number title url state repository { nameWithOwner } }
    }
  }
  """

  @list_query """
  query($owner: String!, $name: String!, $states: [IssueState!], $labels: [String!],
        $filter: IssueFilters, $first: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      issues(first: $first, after: $after, states: $states, labels: $labels, filterBy: $filter,
             orderBy: {field: UPDATED_AT, direction: DESC}) {
        pageInfo { hasNextPage endCursor }
        nodes { ...IssueFields }
      }
    }
  }
  #{@issue_fields}
  """

  @detail_query """
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { issue(number: $number) { ...IssueFields } }
  }
  #{@issue_fields}
  """

  @pair_query """
  query($owner: String!, $name: String!, $number: Int!,
        $otherOwner: String!, $otherName: String!, $other: Int!) {
    issue: repository(owner: $owner, name: $name) { issue(number: $number) { id } }
    other: repository(owner: $otherOwner, name: $otherName) { issue(number: $other) { id } }
  }
  """

  @relations %{
    "addSubIssue" => {"subIssue", "addSubIssue", "subIssueId"},
    "removeSubIssue" => {"subIssue", "removeSubIssue", "subIssueId"},
    "addBlockedBy" => {"blockedBy", "addBlockedBy", "blockingIssueId"},
    "removeBlockedBy" => {"blockedBy", "removeBlockedBy", "blockingIssueId"}
  }

  @boards_query """
  query($owner: String!, $after: String) {
    repositoryOwner(login: $owner) {
      ... on ProjectV2Owner {
        projectsV2(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { number title url closed }
        }
      }
    }
  }
  """

  @board_fields """
  fields(first: 50) {
    nodes {
      ... on ProjectV2FieldCommon { id name dataType }
      ... on ProjectV2SingleSelectField { options { id name } }
      ... on ProjectV2IterationField {
        configuration {
          iterations { id title startDate duration }
          completedIterations { id title startDate duration }
        }
      }
    }
  }
  """

  @field_name "field { ... on ProjectV2FieldCommon { name } }"

  @board_query """
  query($owner: String!, $number: Int!, $first: Int!, $after: String) {
    repositoryOwner(login: $owner) {
      ... on ProjectV2Owner {
        projectV2(number: $number) {
          id title url
          #{@board_fields}
          items(first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              content {
                __typename
                ... on Issue { number title url state repository { nameWithOwner } }
                ... on PullRequest { number title url state repository { nameWithOwner } }
                ... on DraftIssue { title }
              }
              fieldValues(first: 50) {
                nodes {
                  __typename
                  ... on ProjectV2ItemFieldTextValue { text #{@field_name} }
                  ... on ProjectV2ItemFieldNumberValue { number #{@field_name} }
                  ... on ProjectV2ItemFieldDateValue { date #{@field_name} }
                  ... on ProjectV2ItemFieldSingleSelectValue { name #{@field_name} }
                  ... on ProjectV2ItemFieldIterationValue { title #{@field_name} }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @board_fields_query """
  query($owner: String!, $number: Int!) {
    repositoryOwner(login: $owner) {
      ... on ProjectV2Owner { projectV2(number: $number) { id #{@board_fields} } }
    }
  }
  """

  @board_content_query """
  query($owner: String!, $number: Int!, $contentOwner: String!, $contentName: String!, $content: Int!) {
    repositoryOwner(login: $owner) { ... on ProjectV2Owner { projectV2(number: $number) { id } } }
    repository(owner: $contentOwner, name: $contentName) {
      issueOrPullRequest(number: $content) { ... on Issue { id } ... on PullRequest { id } }
    }
  }
  """

  @add_item_mutation """
  mutation($project: ID!, $content: ID!) {
    addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
  }
  """

  @set_field_mutation """
  mutation($project: ID!, $item: ID!, $field: ID!, $value: ProjectV2FieldValue!) {
    updateProjectV2ItemFieldValue(
      input: {projectId: $project, itemId: $item, fieldId: $field, value: $value}
    ) { projectV2Item { id } }
  }
  """

  @clear_field_mutation """
  mutation($project: ID!, $item: ID!, $field: ID!) {
    clearProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field}) {
      projectV2Item { id }
    }
  }
  """

  @field_types %{
    "TEXT" => "text",
    "NUMBER" => "number",
    "DATE" => "date",
    "SINGLE_SELECT" => "singleSelect",
    "ITERATION" => "iteration"
  }

  @doc "Serves `issues.<method>`."
  def handle(method, input) when is_map(input) do
    case @methods[method] do
      nil -> {:error, "issues.#{method} is not served by this MC."}
      fun -> __MODULE__ |> apply(fun, [input]) |> answer()
    end
  end

  def handle(method, _input), do: {:error, "issues.#{method} needs an object as its input."}

  @doc "Whether `method` changes something on the host."
  def write?(method), do: method in @writes

  # --- reads ---------------------------------------------------------------------------

  @doc false
  def list(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, state} <- choice(input["state"], ~w(open closed all), "open"),
         {:ok, milestone} <- scalar(input["milestone"], "milestone") do
      {owner, name} = split(ctx.repository)
      limit = input["limit"] |> integer(200) |> min(1000) |> max(1)

      filter =
        %{}
        |> put_present("milestoneNumber", milestone)
        |> put_present("since", input["since"])

      variables = %{
        "owner" => owner,
        "name" => name,
        "states" => states(state),
        "labels" => non_empty(input["labels"]),
        "filter" => filter
      }

      with {:ok, issues} <- list_pages(ctx, variables, limit, nil, []),
           do: {:ok, %{"issues" => issues}}
    end
  end

  defp list_pages(ctx, variables, limit, cursor, acc) do
    variables = Map.merge(variables, %{"first" => min(@page, limit), "after" => cursor})

    with {:ok, data} <- GitHub.graphql(ctx, @list_query, variables),
         %{"nodes" => nodes, "pageInfo" => page} <- get_in(data, ["repository", "issues"]) do
      acc = acc ++ Enum.map(nodes, &issue/1)
      left = limit - length(nodes)

      if left > 0 and page["hasNextPage"] == true,
        do: list_pages(ctx, variables, left, page["endCursor"], acc),
        else: {:ok, acc}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error, "#{ctx.repository} was not found on #{ctx.host}, or this login cannot see it."}
    end
  end

  @doc false
  def detail(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, number} <- number(input["number"]),
         do: read_issue(ctx, number)
  end

  defp read_issue(ctx, number) do
    {owner, name} = split(ctx.repository)
    variables = %{"owner" => owner, "name" => name, "number" => number}

    case GitHub.graphql(ctx, @detail_query, variables) do
      {:ok, %{"repository" => %{"issue" => %{} = raw}}} -> {:ok, issue(raw)}
      {:ok, _} -> not_found(ctx.repository, number)
      error -> error
    end
  end

  # An issue GitHub has changed, read back; a failed read only loses the detail, so a
  # retry does not make the change twice.
  defp read_written(ctx, number, made) do
    case read_issue(ctx, number) do
      {:ok, issue} ->
        {:ok, issue}

      _ ->
        url = if is_map(made), do: made["html_url"]
        {:ok, %{"repository" => ctx.repository, "number" => number, "url" => url}}
    end
  end

  @doc false
  def milestones(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, state} <- choice(input["state"], ~w(open closed all), "open"),
         {:ok, raw} <- milestone_pages(ctx, state, 1, []) do
      {:ok, %{"milestones" => Enum.map(raw, &milestone/1)}}
    end
  end

  # REST pages until a short one: `gh api` reads only the page it is asked for.
  defp milestone_pages(ctx, state, page, acc) do
    path = "milestones?state=#{state}&per_page=#{@page}&page=#{page}"

    with {:ok, raw} <- GitHub.rest_api(ctx, path) do
      raw = raw || []

      if length(raw) < @page,
        do: {:ok, acc ++ raw},
        else: milestone_pages(ctx, state, page + 1, acc ++ raw)
    end
  end

  @doc false
  def boards(input) do
    with {:ok, ctx} <- project(input) do
      owner = input["owner"] || owner_of(ctx.repository)

      with {:ok, nodes} <- boards_pages(ctx, owner, nil, []) do
        {:ok,
         %{
           "boards" =>
             for board <- nodes, board do
               board
               |> Map.take(~w(number title url closed))
               |> Map.put("owner", owner)
             end
         }}
      end
    end
  end

  defp boards_pages(ctx, owner, cursor, acc) do
    case GitHub.graphql(ctx, @boards_query, %{"owner" => owner, "after" => cursor}) do
      {:ok, %{"repositoryOwner" => %{"projectsV2" => %{"nodes" => nodes} = found}}} ->
        page = found["pageInfo"] || %{}

        if page["hasNextPage"] == true,
          do: boards_pages(ctx, owner, page["endCursor"], acc ++ nodes),
          else: {:ok, acc ++ nodes}

      {:ok, _} ->
        {:error, "#{owner} was not found on #{ctx.host}."}

      error ->
        error
    end
  end

  @doc false
  def board(input) do
    with {:ok, ctx} <- project(input),
         {:ok, owner} <- text(input["owner"], "owner"),
         {:ok, number} <- number(input["number"]) do
      limit = input["limit"] |> integer(500) |> max(1)
      variables = %{"owner" => owner, "number" => number}

      with {:ok, project, items} <- board_pages(ctx, variables, limit, nil, nil, []) do
        {:ok,
         %{
           "owner" => owner,
           "number" => number,
           "title" => project["title"],
           "url" => project["url"],
           "fields" => Enum.flat_map(project["fields"]["nodes"] || [], &field/1),
           "items" => items
         }}
      end
    end
  end

  defp board_pages(ctx, variables, limit, cursor, project, acc) do
    variables = Map.merge(variables, %{"first" => min(@page, limit), "after" => cursor})

    with {:ok, data} <- GitHub.graphql(ctx, @board_query, variables),
         %{"items" => %{"nodes" => nodes, "pageInfo" => page}} = found <- board_of(data) do
      acc = acc ++ for(item <- nodes, item, do: item(item))
      left = limit - length(nodes)

      if left > 0 and page["hasNextPage"] == true,
        do: board_pages(ctx, variables, left, page["endCursor"], project || found, acc),
        else: {:ok, project || found, acc}
    else
      {:error, _} = error -> error
      _ -> no_board(variables)
    end
  end

  # --- writes --------------------------------------------------------------------------

  @doc false
  def create(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, title} <- text(input["title"], "title") do
      body =
        %{"title" => title}
        |> put_present("body", input["body"])
        |> put_present("labels", input["labels"])
        |> put_present("assignees", input["assignees"])
        |> put_present("milestone", input["milestone"])

      with {:ok, %{"number" => number} = made} <- post(ctx, "issues", "POST", body),
           do: read_written(ctx, number, made)
    end
  end

  @doc false
  def update(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, number} <- number(input["number"]) do
      body =
        input
        |> Map.take(~w(title body state labels assignees milestone))
        |> put_present("state_reason", input["stateReason"])

      with {:ok, made} <- post(ctx, "issues/#{number}", "PATCH", body),
           do: read_written(ctx, number, made)
    end
  end

  @doc false
  def comment(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, number} <- number(input["number"]),
         {:ok, _} <- text(input["body"], "body"),
         {:ok, raw} <-
           post(ctx, "issues/#{number}/comments", "POST", %{"body" => input["body"]}),
         do: {:ok, %{"url" => raw["html_url"]}}
  end

  @doc false
  def create_milestone(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, title} <- text(input["title"], "title"),
         {:ok, body} <- milestone_body(Map.put(input, "title", title)),
         {:ok, raw} <- post(ctx, "milestones", "POST", body),
         do: {:ok, milestone(raw)}
  end

  @doc false
  def update_milestone(input) do
    with {:ok, ctx} <- repository(input),
         {:ok, number} <- number(input["number"]),
         {:ok, body} <- milestone_body(input),
         {:ok, raw} <- post(ctx, "milestones/#{number}", "PATCH", body),
         do: {:ok, milestone(raw)}
  end

  # GitHub keeps a due date as a time; noon UTC is the same day everywhere it is shown.
  defp milestone_body(input) do
    body = Map.take(input, ~w(title description state))

    case Map.fetch(input, "dueOn") do
      :error ->
        {:ok, body}

      {:ok, nil} ->
        {:ok, Map.put(body, "due_on", nil)}

      {:ok, due} ->
        with {:ok, due} <- date(due), do: {:ok, Map.put(body, "due_on", due <> "T12:00:00Z")}
    end
  end

  @doc false
  def add_sub_issue(input), do: relate("addSubIssue", input)
  @doc false
  def remove_sub_issue(input), do: relate("removeSubIssue", input)
  @doc false
  def add_blocked_by(input), do: relate("addBlockedBy", input)
  @doc false
  def remove_blocked_by(input), do: relate("removeBlockedBy", input)

  # Sub-issues and dependencies are changed by node id, read for both issues at once.
  defp relate(method, input) do
    {key, mutation, other_id} = @relations[method]

    with {:ok, ctx} <- repository(input),
         {:ok, number} <- number(input["number"]),
         {:ok, other} <- ref(input[key], ctx.repository, key),
         {owner, name} = split(ctx.repository),
         {other_owner, other_name} = split(other["repository"]),
         variables = %{
           "owner" => owner,
           "name" => name,
           "number" => number,
           "otherOwner" => other_owner,
           "otherName" => other_name,
           "other" => other["number"]
         },
         {:ok, data} <- GitHub.graphql(ctx, @pair_query, variables),
         {:ok, issue_id} <- node(data, "issue", ctx.repository, number),
         {:ok, related_id} <- node(data, "other", other["repository"], other["number"]) do
      document = """
      mutation($issue: ID!, $other: ID!) {
        #{mutation}(input: {issueId: $issue, #{other_id}: $other}) { clientMutationId }
      }
      """

      with {:ok, _} <-
             GitHub.graphql(ctx, document, %{"issue" => issue_id, "other" => related_id}),
           do: {:ok, %{"ok" => true}}
    end
  end

  @doc false
  def add_board_item(input) do
    with {:ok, ctx} <- project(input),
         {:ok, owner} <- text(input["owner"], "owner"),
         {:ok, number} <- number(input["number"]),
         {:ok, item} <- ref(input["item"], input["repository"] || ctx.repository, "item"),
         {content_owner, content_name} = split(item["repository"]),
         variables = %{
           "owner" => owner,
           "number" => number,
           "contentOwner" => content_owner,
           "contentName" => content_name,
           "content" => item["number"]
         },
         {:ok, data} <- GitHub.graphql(ctx, @board_content_query, variables) do
      project_id = get_in(data, ["repositoryOwner", "projectV2", "id"])
      content_id = get_in(data, ["repository", "issueOrPullRequest", "id"])

      cond do
        project_id == nil ->
          no_board(variables)

        content_id == nil ->
          not_found(item["repository"], item["number"])

        true ->
          case GitHub.graphql(ctx, @add_item_mutation, %{
                 "project" => project_id,
                 "content" => content_id
               }) do
            {:ok, %{"addProjectV2ItemById" => %{"item" => %{"id" => id}}}} ->
              {:ok, %{"itemId" => id}}

            {:ok, _} ->
              {:error, "GitHub did not add #{item["repository"]}##{item["number"]} to the board."}

            error ->
              error
          end
      end
    end
  end

  @doc false
  def set_board_field(input) do
    with {:ok, ctx} <- project(input),
         {:ok, owner} <- text(input["owner"], "owner"),
         {:ok, number} <- number(input["number"]),
         {:ok, item_id} <- text(input["itemId"], "itemId"),
         {:ok, name} <- text(input["field"], "field"),
         variables = %{"owner" => owner, "number" => number},
         {:ok, data} <- GitHub.graphql(ctx, @board_fields_query, variables),
         %{"id" => project_id} = project <- board_of(data) || no_board(variables),
         {:ok, field} <- named_field(project, name, variables) do
      ids = %{"project" => project_id, "item" => item_id, "field" => field["id"]}

      result =
        case input["value"] do
          nil ->
            GitHub.graphql(ctx, @clear_field_mutation, ids)

          value ->
            with {:ok, value} <- field_value(field, value),
                 do: GitHub.graphql(ctx, @set_field_mutation, Map.put(ids, "value", value))
        end

      with {:ok, _} <- result, do: {:ok, %{"ok" => true}}
    end
  end

  defp named_field(project, name, variables) do
    fields = Enum.flat_map(project["fields"]["nodes"] || [], &field/1)
    lower = String.downcase(name)

    case Enum.find(fields, &(&1["name"] == name)) ||
           Enum.find(fields, &(String.downcase(&1["name"]) == lower)) do
      nil ->
        {:error,
         "The board #{variables["owner"]}/#{variables["number"]} has no field #{inspect(name)}."}

      field ->
        {:ok, field}
    end
  end

  # The value in the shape GitHub's `ProjectV2FieldValue` takes for the field's type:
  # a single-select option by its name, an iteration by its title.
  defp field_value(%{"type" => "text"} = field, value) do
    with {:ok, text} <- scalar(value, field["name"]), do: {:ok, %{"text" => text}}
  end

  defp field_value(%{"type" => "number"} = field, value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, %{"number" => number}}
      _ -> {:error, "#{field["name"]} takes a number, not #{inspect(value)}."}
    end
  end

  defp field_value(%{"type" => "number"}, value) when is_number(value),
    do: {:ok, %{"number" => value / 1}}

  defp field_value(%{"type" => "date"}, value) do
    with {:ok, date} <- date(value), do: {:ok, %{"date" => date}}
  end

  defp field_value(%{"type" => "singleSelect"} = field, value) do
    case Enum.find(field["options"], &same?(&1["name"], value)) do
      nil -> {:error, "#{field["name"]} has no option #{inspect(value)}."}
      option -> {:ok, %{"singleSelectOptionId" => option["id"]}}
    end
  end

  defp field_value(%{"type" => "iteration"} = field, value) do
    case Enum.find(field["iterations"], &same?(&1["title"], value)) do
      nil -> {:error, "#{field["name"]} has no iteration #{inspect(value)}."}
      iteration -> {:ok, %{"iterationId" => iteration["id"]}}
    end
  end

  defp field_value(field, _value), do: {:error, "#{field["name"]} cannot be set here."}

  # --- shapes --------------------------------------------------------------------------

  defp issue(raw) do
    %{
      "repository" => get_in(raw, ["repository", "nameWithOwner"]),
      "number" => raw["number"],
      "title" => raw["title"],
      "body" => raw["body"],
      "state" => down(raw["state"]),
      "stateReason" => down(raw["stateReason"]),
      "url" => raw["url"],
      "author" => get_in(raw, ["author", "login"]),
      "assignees" => nodes(raw["assignees"], "login"),
      "labels" => nodes(raw["labels"], "name"),
      "milestone" =>
        with(
          %{} = m <- raw["milestone"],
          do: %{"number" => m["number"], "title" => m["title"], "dueOn" => day(m["dueOn"])}
        ),
      "createdAt" => raw["createdAt"],
      "updatedAt" => raw["updatedAt"],
      "closedAt" => raw["closedAt"],
      "parent" => with(%{} = parent <- raw["parent"], do: issue_ref(parent)),
      "subIssues" => refs(raw["subIssues"]),
      "subIssuesSummary" => %{
        "total" => get_in(raw, ["subIssuesSummary", "total"]) || 0,
        "completed" => get_in(raw, ["subIssuesSummary", "completed"]) || 0
      },
      "blockedBy" => refs(raw["blockedBy"]),
      "blocking" => refs(raw["blocking"]),
      "pullRequests" =>
        for pr <- get_in(raw, ["closedByPullRequestsReferences", "nodes"]) || [], pr do
          %{
            "repository" => get_in(pr, ["repository", "nameWithOwner"]),
            "number" => pr["number"],
            "title" => pr["title"],
            "url" => pr["url"],
            "state" => down(pr["state"])
          }
        end,
      "issueType" => get_in(raw, ["issueType", "name"])
    }
  end

  defp issue_ref(raw),
    do: %{"repository" => get_in(raw, ["repository", "nameWithOwner"]), "number" => raw["number"]}

  defp refs(connection), do: for(n <- (connection || %{})["nodes"] || [], n, do: issue_ref(n))

  defp nodes(connection, key), do: for(n <- (connection || %{})["nodes"] || [], n, do: n[key])

  defp milestone(raw) do
    %{
      "number" => raw["number"],
      "title" => raw["title"],
      "description" => raw["description"],
      "state" => raw["state"],
      "dueOn" => day(raw["due_on"]),
      "url" => raw["html_url"],
      "openIssues" => raw["open_issues"],
      "closedIssues" => raw["closed_issues"]
    }
  end

  defp field(%{"id" => id, "name" => name} = raw) do
    [
      %{
        "id" => id,
        "name" => name,
        "type" => @field_types[raw["dataType"]] || "other",
        "options" => for(o <- raw["options"] || [], do: Map.take(o, ~w(id name))),
        "iterations" =>
          for(
            i <-
              (get_in(raw, ["configuration", "iterations"]) || []) ++
                (get_in(raw, ["configuration", "completedIterations"]) || []),
            do: Map.take(i, ~w(id title startDate duration))
          )
      }
    ]
  end

  defp field(_), do: []

  defp item(raw) do
    content = raw["content"] || %{}

    %{
      "id" => raw["id"],
      "content" => %{
        "kind" =>
          case content["__typename"] do
            "Issue" -> "issue"
            "PullRequest" -> "pullRequest"
            _ -> "draft"
          end,
        "repository" => get_in(content, ["repository", "nameWithOwner"]),
        "number" => content["number"],
        "title" => content["title"],
        "url" => content["url"],
        "state" => down(content["state"])
      },
      "fields" =>
        for value <- get_in(raw, ["fieldValues", "nodes"]) || [],
            name = get_in(value || %{}, ["field", "name"]),
            into: %{} do
          {name,
           value["date"] || value["text"] || value["number"] || value["name"] || value["title"]}
        end
    }
  end

  # --- plumbing ------------------------------------------------------------------------

  # The project serving the call; only GitHub is served yet.
  defp project(input) do
    id = input["projectId"]

    case Enum.find(PullRequests.projects(), &(&1.id == id)) do
      nil ->
        {:error, "No project #{inspect(id)} with a git remote is on this MC."}

      %{kind: "github"} = project ->
        {:ok, %{cwd: project.root, host: project.host, repository: project.repository}}

      project ->
        {:error, "Issues on #{project.host} cannot be read here yet."}
    end
  end

  defp repository(input) do
    with {:ok, ctx} <- project(input) do
      repository = input["repository"] || ctx.repository
      repository = if is_binary(repository), do: String.trim(repository), else: repository

      if is_binary(repository) and Regex.match?(@repository, repository),
        do: {:ok, %{ctx | repository: repository}},
        else: {:error, "#{inspect(repository)} is not a repository on GitHub (owner/name)."}
    end
  end

  defp ref(%{"number" => number} = ref, default, key) do
    repository = ref["repository"] || default

    cond do
      not (is_binary(repository) and Regex.match?(@repository, repository)) ->
        {:error, "#{key} names no repository (owner/name)."}

      not (is_integer(number) and number > 0) ->
        {:error, "#{key} names no issue number."}

      true ->
        {:ok, %{"repository" => repository, "number" => number}}
    end
  end

  defp ref(_, _default, key), do: {:error, "#{key} must be {repository, number}."}

  defp node(data, key, repository, number) do
    case get_in(data, [key, "issue", "id"]) do
      nil -> not_found(repository, number)
      id -> {:ok, id}
    end
  end

  defp board_of(data), do: get_in(data, ["repositoryOwner", "projectV2"])

  defp no_board(variables),
    do:
      {:error,
       "There is no board #{variables["owner"]}/#{variables["number"]}, or this login cannot see it."}

  defp post(ctx, path, method, body),
    do: GitHub.rest_api(ctx, path, method: method, input: JSON.encode!(body))

  defp states("closed"), do: ["CLOSED"]
  defp states("all"), do: nil
  defp states("open"), do: ["OPEN"]

  defp number(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp number(_), do: {:error, "number must be a positive whole number."}

  defp text(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "#{key} is required."}
      text -> {:ok, text}
    end
  end

  defp text(_value, key), do: {:error, "#{key} is required."}

  defp date(value) when is_binary(value) do
    if Regex.match?(@date, value) and match?({:ok, _}, Date.from_iso8601(value)),
      do: {:ok, value},
      else: {:error, "#{inspect(value)} is not a date (YYYY-MM-DD)."}
  end

  defp date(value), do: {:error, "#{inspect(value)} is not a date (YYYY-MM-DD)."}

  # A JSON string or number as GitHub's text; nil when absent.
  defp scalar(nil, _key), do: {:ok, nil}
  defp scalar(value, _key) when is_binary(value) or is_number(value), do: {:ok, to_string(value)}
  defp scalar(value, key), do: {:error, "#{key} takes text or a number, not #{inspect(value)}."}

  defp choice(nil, _choices, default), do: {:ok, default}

  defp choice(value, choices, _default) do
    if value in choices,
      do: {:ok, value},
      else: {:error, "#{inspect(value)} is not one of #{Enum.join(choices, ", ")}."}
  end

  defp integer(n, _default) when is_integer(n), do: n
  defp integer(_, default), do: default

  defp non_empty([_ | _] = list), do: list
  defp non_empty(_), do: nil

  defp split(repository) do
    [owner, name] = String.split(repository, "/", parts: 2)
    {owner, name}
  end

  defp owner_of(repository), do: repository |> split() |> elem(0)

  defp not_found(repository, number),
    do: {:error, "Issue #{repository}##{number} was not found, or this login cannot see it."}

  defp same?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(String.trim(right))

  defp same?(_, _), do: false

  defp down(value) when is_binary(value), do: String.downcase(value)
  defp down(_), do: nil

  # `2026-11-30T07:00:00Z` as the day GitHub shows it.
  defp day(value) when is_binary(value), do: binary_part(value, 0, min(10, byte_size(value)))
  defp day(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # What `gh` said, in words a plugin can show: its install and sign-in as pull
  # requests word them, and a login without the `project` scope how to get it. Other
  # missing scopes keep GitHub's own words, which name the scope.
  defp answer({:error, {reason, _detail}}) when reason in [:missing, :unauthenticated],
    do: {:error, PullRequests.requirement(reason)}

  defp answer({:error, {_reason, detail}}) do
    if detail =~ ~r/'(read:)?project'/,
      do: {:error, @scope},
      else: {:error, detail}
  end

  defp answer(other), do: other
end
