for file <- ~w(plan slack sync),
    do: Code.require_file("../../../../plugins/planner/mc/#{file}.ex", __DIR__)

defmodule HalC2.PlannerTest do
  @moduledoc """
  The planner plugin's rules (`plugins/planner/mc`): the plan's items, what clients
  see derived from them, an agent's proposed changes, views, prompts and what goes
  to Slack. These are plain functions; the plugin process, its runs, GitHub and
  Slack are covered by `features/planning/planner.feature` and
  `prop/hal_c2/planner_prop_test.exs`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.Planner.{Plan, Slack, Sync}

  @now "2026-10-15T09:00:00Z"
  @today "2026-10-15"

  defp plan(specs) do
    Enum.reduce(specs, %{}, fn {id, fields}, items ->
      {:ok, items, _} = Plan.add(items, id, Map.put_new(fields, "title", id), @now)
      items
    end)
  end

  defp derived(items, id), do: Enum.find(Plan.derive(items, @today), &(&1["id"] == id))

  describe "items" do
    test "nothing waits for itself, however long the way round" do
      items = plan([{"a", %{}}, {"b", %{"after" => ["a"]}}, {"c", %{"after" => ["b"]}}])

      assert {:error, "That would make a wait for itself."} =
               Plan.update(items, "a", %{"after" => ["c"]}, @now)

      assert {:error, "That would make a wait for itself."} =
               Plan.update(items, "a", %{"after" => ["a"]}, @now)
    end

    test "nothing is its own subtask, and a parent or dependency must exist" do
      items = plan([{"a", %{}}, {"b", %{"parent" => "a"}}])

      assert {:error, "That would make a a subtask of itself."} =
               Plan.update(items, "a", %{"parent" => "b"}, @now)

      assert {:error, "a cannot be a subtask of itself."} =
               Plan.update(items, "a", %{"parent" => "a"}, @now)

      assert {:error, "There is no task x."} =
               Plan.add(items, "c", %{"title" => "c", "parent" => "x"}, @now)

      assert {:error, "There is no task x."} =
               Plan.add(items, "c", %{"title" => "c", "after" => ["x"]}, @now)
    end

    test "a task ends no earlier than it starts, and a milestone has only a date" do
      assert {:error, "a cannot end before it starts."} =
               Plan.add(
                 %{},
                 "a",
                 %{"title" => "a", "start" => "2026-10-20", "due" => "2026-10-19"},
                 @now
               )

      assert {:ok, _, %{"kind" => "milestone", "start" => nil, "due" => "2026-11-01"}} =
               Plan.add(
                 %{},
                 "m",
                 %{
                   "title" => "Beta",
                   "kind" => "milestone",
                   "start" => "2026-10-01",
                   "due" => "2026-11-01"
                 },
                 @now
               )
    end

    test "fields are checked one by one, and an update leaves out what is not a field" do
      assert {:error, "A task needs a title."} = Plan.add(%{}, "a", %{"title" => "  "}, @now)

      assert {:error, "due: \"soon\" is not a date (YYYY-MM-DD)."} =
               Plan.add(%{}, "a", %{"title" => "a", "due" => "soon"}, @now)

      assert {:error, "progress is a number from 0 to 100."} =
               Plan.add(%{}, "a", %{"title" => "a", "progress" => 101}, @now)

      assert {:error, "late is not a field a change can set."} =
               Plan.add(%{}, "a", %{"title" => "a", "late" => true}, @now)

      # An owner is a login: the blanks around it go, those inside refuse it.
      assert {:error, "owner: \"da na\" is not a login."} =
               Plan.add(%{}, "a", %{"title" => "a", "owner" => " da na "}, @now)

      assert {:ok, %{"a" => %{"owner" => "dana"}}, _} =
               Plan.add(%{}, "a", %{"title" => "a", "owner" => " dana "}, @now)

      # The rest of the host's login shape refuses it here too, not at every
      # push; the cases are the host suite's own (`HalC2.Test.LoginCases`).
      for bad <- HalC2.Test.LoginCases.bad() do
        assert {:error, _} = Plan.add(%{}, "a", %{"title" => "a", "owner" => bad}, @now)
      end

      for good <- HalC2.Test.LoginCases.good() do
        assert {:ok, %{"a" => %{"owner" => ^good}}, _} =
                 Plan.add(%{}, "a", %{"title" => "a", "owner" => good}, @now)
      end

      assert {:ok, %{"a" => %{"owner" => "copilot[bot]"}}, _} =
               Plan.add(%{}, "a", %{"title" => "a", "owner" => "copilot[bot]"}, @now)

      items = plan([{"a", %{}}])

      {:ok, _items, old, new} =
        Plan.update(items, "a", Map.merge(derived(items, "a"), %{"late" => true}), "later")

      assert old == new
    end

    test "removing a task moves its subtasks up and lets go of what waited for it" do
      items =
        plan([
          {"top", %{}},
          {"a", %{"parent" => "top"}},
          {"b", %{"parent" => "a"}},
          {"c", %{"after" => ["a", "top"]}}
        ])

      items = Plan.remove(items, "a")

      refute Map.has_key?(items, "a")
      assert items["b"]["parent"] == "top"
      assert items["c"]["after"] == ["top"]
      assert Plan.remove(items, "gone") == items
    end

    test "moving a task places it before a sibling and numbers its siblings again" do
      items = plan([{"a", %{}}, {"b", %{}}, {"c", %{}}])
      {:ok, items} = Plan.move(items, "c", nil, "a", @now)

      assert items |> Plan.derive(@today) |> Enum.map(& &1["id"]) == ["c", "a", "b"]
      assert Enum.map(~w(c a b), &items[&1]["order"]) == [0, 1, 2]

      {:ok, items} = Plan.move(items, "c", "a", nil, @now)
      assert %{"parent" => "a", "order" => 0} = items["c"]
    end
  end

  describe "what clients see" do
    test "a task is late once its due date passes, unless it is closed" do
      items =
        plan([
          {"late", %{"due" => "2026-10-14"}},
          {"done", %{"due" => "2026-10-14", "status" => "done"}},
          {"today", %{"due" => @today}}
        ])

      assert derived(items, "late")["late"]
      refute derived(items, "done")["late"]
      refute derived(items, "today")["late"]
    end

    test "a task starting before what it waits for ends is early; a milestone may end that day" do
      items =
        plan([
          {"schema", %{"start" => "2026-10-19", "due" => "2026-10-23"}},
          {"beta", %{"kind" => "milestone", "due" => "2026-10-26"}},
          {"api", %{"start" => "2026-10-21", "due" => "2026-10-30", "after" => ["schema"]}},
          {"docs", %{"start" => "2026-10-26", "due" => "2026-11-02", "after" => ["beta"]}},
          {"open", %{"after" => ["schema"]}}
        ])

      assert derived(items, "api")["early"] == ["schema"]
      assert derived(items, "docs")["early"] == []
      assert derived(items, "open")["early"] == []
    end

    test "progress is done, then the user's, then the subtasks', then the share of merged pull requests" do
      items =
        plan([
          {"parent", %{}},
          {"a", %{"parent" => "parent", "status" => "done"}},
          {"b", %{"parent" => "parent", "progress" => 50}},
          {"c", %{"parent" => "parent", "status" => "dropped"}},
          {"d", %{"parent" => "parent"}},
          {"set", %{"progress" => 30, "status" => "doing"}},
          {"closed", %{"progress" => 30, "status" => "done"}}
        ])

      pr = &%{"pullRequest" => %{"repository" => "acme/api", "number" => &1, "state" => &2}}

      items =
        Map.update!(
          items,
          "d",
          &(&1 |> Plan.link(pr.(1, "merged"), @now) |> Plan.link(pr.(2, "open"), @now))
        )

      assert derived(items, "d")["derivedProgress"] == 50
      assert derived(items, "parent")["derivedProgress"] == 67
      assert derived(items, "parent")["children"] == 4
      assert derived(items, "set")["derivedProgress"] == 30
      assert derived(items, "closed")["derivedProgress"] == 100
    end

    test "slip is the days a task's due date moved past its baseline's" do
      items = plan([{"a", %{"due" => "2026-11-04"}}, {"b", %{"due" => "2026-10-30"}}])
      items = put_in(items["a"]["baseline"], %{"start" => nil, "due" => "2026-10-30"})

      assert derived(items, "a")["slip"] == 5
      assert derived(items, "b")["slip"] == nil
    end

    test "linking a pull request twice links it once, whatever the case of its repository" do
      ref = %{"pullRequest" => %{"repository" => "acme/api", "number" => 4}}

      item =
        plan([{"a", %{}}])["a"]
        |> Plan.link(ref, @now)
        |> Plan.link(put_in(ref["pullRequest"]["repository"], "Acme/API"), @now)

      assert [%{"number" => 4, "url" => "https://github.com/acme/api/pull/4", "state" => "open"}] =
               item["pullRequests"]
    end

    test "a link keeps the address of the pull request it names, and a second one corrects it" do
      ghe = "https://ghe.example.com/acme/api/pull/4"
      ref = fn fields -> %{"repository" => "acme/api", "number" => 4} |> Map.merge(fields) end

      for url <- [
            "https://ghe.example.com/acme/tools/pull/4",
            "https://ghe.example.com/acme/api",
            "https://ghe.example.com/acme/api/pull/44",
            "https://ghe.example.com/acme/api/pull/14",
            "https://ghe.example.com/acme/api/issues/4"
          ] do
        assert {:ok, %{"repository" => "acme/api", "number" => 4} = given} =
                 Plan.ref(ref.(%{"url" => url}), "pullRequest")

        refute Map.has_key?(given, "url")
      end

      assert {:ok, %{"url" => ^ghe}} = Plan.ref(ref.(%{"url" => ghe}), "pullRequest")
      assert {:ok, %{"url" => ^ghe}} = Plan.ref(ref.(%{"url" => ghe}))

      item = plan([{"a", %{}}])["a"] |> Plan.link(%{"pullRequest" => ref.(%{})}, @now)
      assert [%{"url" => "https://github.com/acme/api/pull/4"}] = item["pullRequests"]

      item = Plan.link(item, %{"pullRequest" => ref.(%{"url" => ghe})}, @now)
      assert [%{"number" => 4, "url" => ^ghe}] = item["pullRequests"]

      # A link made again without an address does not take the corrected one back.
      item = Plan.link(item, %{"pullRequest" => ref.(%{})}, @now)
      assert [%{"number" => 4, "url" => ^ghe}] = item["pullRequests"]
    end

    test "an address keeps only its scheme, host, port and path, and names the kind it links" do
      ref = %{"repository" => "acme/api", "number" => 4}

      url = fn url, kind ->
        with({:ok, given} <- Plan.ref(Map.put(ref, "url", url), kind), do: given["url"])
      end

      assert url.(
               "https://user:token@ghe.example.com/acme/api/pull/4?token=abc#files",
               "pullRequest"
             ) ==
               "https://ghe.example.com/acme/api/pull/4"

      assert url.("https://github.com@evil.example/acme/api/pull/4", "pullRequest") ==
               "https://evil.example/acme/api/pull/4"

      # The path is made over, so the same pull request is one address however it was
      # given, and nothing odd after the number stays.
      for path <- ["/files", "/../../evil", "/", "/%2e%2e/x"] do
        assert url.("https://ghe.example.com:8443/acme/api/pull/4#{path}", "pullRequest") ==
                 "https://ghe.example.com:8443/acme/api/pull/4"
      end

      assert url.("https://ghe.example.com/ACME/Api/PULL/4", "pullRequest") ==
               "https://ghe.example.com/acme/api/pull/4"

      # A literal IPv6 host keeps its brackets, so the address reads back to that host.
      stored = url.("https://[::1]:8443/acme/api/pull/4", "pullRequest")
      assert stored == "https://[::1]:8443/acme/api/pull/4"
      assert URI.parse(stored).host == "::1"

      assert url.("https://ghe.example.com:443/acme/api/pull/4", "pullRequest") ==
               "https://ghe.example.com/acme/api/pull/4"

      assert url.("https://ghe.example.com/acme/api/issues/4", "issue") ==
               "https://ghe.example.com/acme/api/issues/4"

      assert url.("https://ghe.example.com/acme/api/pull/4", "issue") == nil

      # The host is canonical, as everywhere else it is derived.
      assert url.("https://GHE.Example.COM./acme/api/pull/4", "pullRequest") ==
               "https://ghe.example.com/acme/api/pull/4"

      assert url.("https://ghe.example.com:0/acme/api/pull/4", "pullRequest") == nil
      assert url.("https://ghe.example.com:99999/acme/api/pull/4", "pullRequest") == nil

      # A host that canonicalizes to nothing, or holds whitespace, names no host.
      assert url.("https://./acme/api/pull/4", "pullRequest") == nil
      assert url.("https://../acme/api/pull/4", "pullRequest") == nil
      assert url.("https://exa mple.com/acme/api/pull/4", "pullRequest") == nil

      # A host with an empty label or a `%` in it names no host either.
      assert url.("https://ghe..example.com/acme/api/pull/4", "pullRequest") == nil
      assert url.("https://ghe.example.com%2f.evil.com/acme/api/pull/4", "pullRequest") == nil

      # Nor does a label starting or ending with a hyphen, or an IPv6 literal
      # with a zone, which `URI.parse/1` would mangle into another address.
      assert url.("https://-ghe.example.com/acme/api/pull/4", "pullRequest") == nil
      assert url.("https://ghe-.example.com/acme/api/pull/4", "pullRequest") == nil
      assert url.("https://[fe80::1%25eth0]/acme/api/pull/4", "pullRequest") == nil

      # Nor does an IPv6-shaped string that is no address.
      for host <- ["[:::]", "[....:]", "[1:2:3:4:5:6:7:8:9]", "[::ffff:999.999.999.999]"] do
        assert url.("https://#{host}/acme/api/pull/4", "pullRequest") == nil
      end

      assert url.("https://[::ffff:1.2.3.4]/acme/api/pull/4", "pullRequest") ==
               "https://[::ffff:1.2.3.4]/acme/api/pull/4"

      # A repository that is no `owner/name` over GitHub's charset is no ref:
      # it would otherwise be interpolated verbatim into the stored address.
      assert :error = Plan.ref(%{"repository" => "../evil", "number" => 4}, "pullRequest")
      assert :error = Plan.ref(%{"repository" => "acme/api\n", "number" => 4}, "pullRequest")

      # A leading dot or underscore is a repository name like any other
      # (`owner/.github` is the conventional one), and links as one.
      assert {:ok, %{"repository" => "acme/.github", "url" => ghe_github}} =
               Plan.ref(
                 %{
                   "repository" => "acme/.github",
                   "number" => 4,
                   "url" => "https://ghe.example.com/acme/.github/pull/4"
                 },
                 "pullRequest"
               )

      assert ghe_github == "https://ghe.example.com/acme/.github/pull/4"

      item =
        plan([{"a", %{}}])["a"]
        |> Plan.link(
          %{"pullRequest" => %{"repository" => "acme/.github", "number" => 4}},
          @now
        )

      assert [%{"repository" => "acme/.github", "number" => 4}] = item["pullRequests"]
    end

    test "a correcting link to another host forgets what the old host's look stored" do
      ghe = "https://ghe.example.com/acme/api/pull/4"
      ref = fn fields -> %{"repository" => "acme/api", "number" => 4} |> Map.merge(fields) end

      item = plan([{"a", %{}}])["a"] |> Plan.link(%{"pullRequest" => ref.(%{})}, @now)

      item =
        put_in(item["pullRequests"], [
          %{
            "repository" => "acme/api",
            "number" => 4,
            "url" => "https://github.com/acme/api/pull/4",
            "title" => "Old",
            "state" => "merged"
          }
        ])

      item = Plan.link(item, %{"pullRequest" => ref.(%{"url" => ghe})}, @now)
      assert [%{"url" => ^ghe, "state" => "open", "title" => nil}] = item["pullRequests"]
    end

    test "an issue linked again with the address of its host takes that address and keeps the rest" do
      ghe = "https://ghe.example.com/acme/api/issues/7"
      ref = fn fields -> %{"repository" => "acme/api", "number" => 7} |> Map.merge(fields) end
      item = plan([{"a", %{}}])["a"] |> Plan.link(%{"issue" => ref.(%{})}, @now)
      item = put_in(item["issue"]["state"], "closed")
      assert item["issue"]["url"] == "https://github.com/acme/api/issues/7"

      # A correction to another host forgets what the old host's look stored, as a
      # pull request does: that closed state described a different issue, and so
      # do the milestone, the board row, the failure and the synced snapshot.
      item =
        item
        |> put_in(["issue", "milestone"], %{"number" => 3})
        |> Map.merge(%{
          "boardItemId" => "PVTI_1",
          "syncError" => "refused",
          "synced" => %{"title" => "T"}
        })

      item = Plan.link(item, %{"issue" => ref.(%{"url" => ghe})}, @now)

      assert %{"url" => ^ghe, "state" => "open", "title" => nil, "milestone" => nil} =
               item["issue"]

      assert %{"boardItemId" => nil, "syncError" => nil, "synced" => nil} = item

      # A same-host correction keeps the rest.
      item = put_in(item["issue"]["state"], "closed")
      ported = "https://ghe.example.com:8443/acme/api/issues/7"
      item = Plan.link(item, %{"issue" => ref.(%{"url" => ported})}, @now)
      assert %{"url" => ^ported, "state" => "closed"} = item["issue"]
      ghe = ported

      assert %{"url" => ^ghe} = Plan.link(item, %{"issue" => ref.(%{})}, @now)["issue"]
    end

    test "a task linked to another issue leaves the old issue's board row and failure behind" do
      issue = fn repository, number ->
        %{"issue" => %{"repository" => repository, "number" => number}}
      end

      item =
        plan([{"a", %{}}])["a"]
        |> Plan.link(issue.("acme/api", 7), @now)
        |> Map.merge(%{"boardItemId" => "item-7", "syncError" => "HTTP 422"})

      assert %{"boardItemId" => "item-7", "syncError" => "HTTP 422"} =
               Plan.link(item, issue.("Acme/API", 7), @now)

      assert %{"issue" => %{"number" => 8}, "boardItemId" => nil, "syncError" => nil} =
               Plan.link(item, issue.("acme/api", 8), @now)
    end
  end

  describe "an agent's changes" do
    setup do
      %{
        items:
          plan([
            {"schema", %{"title" => "Schema"}},
            {"api", %{"title" => "API", "after" => ["schema"]}}
          ])
      }
    end

    test "are numbered, and one that would not take says which and why", %{items: items} do
      assert {:ok, [%{"id" => "c1", "outcome" => nil, "dismissed" => false}]} =
               Plan.check_changes(items, [
                 %{"op" => "update", "itemId" => "api", "fields" => %{"due" => "2026-11-06"}}
               ])

      assert {:error, "Change 2: That would make Schema wait for itself."} =
               Plan.check_changes(items, [
                 %{"op" => "update", "itemId" => "api", "fields" => %{"due" => "2026-11-06"}},
                 %{"op" => "update", "itemId" => "schema", "fields" => %{"after" => ["api"]}}
               ])

      assert {:error, "Change 1: There is no task routes."} =
               Plan.check_changes(items, [
                 %{"op" => "update", "itemId" => "api", "fields" => %{"after" => ["routes"]}}
               ])

      assert {:error, "Change 1: There is no task routes."} =
               Plan.check_changes(items, [
                 %{"op" => "add", "fields" => %{"title" => "Handlers", "parent" => "routes"}}
               ])

      assert {:error, "Change 1: projectId is not a field a change can set."} =
               Plan.check_changes(items, [
                 %{"op" => "update", "itemId" => "api", "fields" => %{"projectId" => "web"}}
               ])

      assert {:error, "Change 1: The task gone is no longer in the plan."} =
               Plan.check_changes(items, [%{"op" => "remove", "itemId" => "gone"}])

      assert {:error, "Change 1: a task it adds needs a title."} =
               Plan.check_changes(items, [%{"op" => "add", "fields" => %{}}])

      assert {:error, "changes is a list."} = Plan.check_changes(items, %{})
    end

    test "a link names just one pull request or issue, never two at once", %{items: items} do
      pr = %{"repository" => "acme/api", "number" => 12}
      issue = %{"repository" => "acme/api", "number" => 7}
      link = &%{"op" => "link", "itemId" => "api", "fields" => &1}

      refused =
        "Change 1: link gives in fields just one of: a pullRequest or an issue as {repository, number, url}."

      assert {:ok, [%{"fields" => %{"issue" => ^issue}}]} =
               Plan.check_changes(items, [link.(%{"issue" => issue, "pullRequest" => nil})])

      for fields <- [
            %{"pullRequest" => pr, "issue" => issue},
            %{"issue" => issue, "threadId" => "t1"},
            %{"issue" => issue, "title" => "API"},
            %{"threadId" => "t1"},
            %{}
          ],
          do: assert({:error, ^refused} = Plan.check_changes(items, [link.(fields)]))

      kinds = ~w(pullRequest issue threadId)
      assert {:ok, %{"threadId" => "t1"}} = Plan.link_target(%{"threadId" => "t1"}, kinds)
      given = %{"repository" => "acme/api", "number" => 4, "state" => %{}, "url" => 1}

      assert Plan.link_target(%{"pullRequest" => given}, kinds) ==
               {:ok, %{"pullRequest" => %{"repository" => "acme/api", "number" => 4}}}

      assert :error = Plan.link_target(%{"pullRequest" => pr, "threadId" => "t1"}, kinds)
      assert :error = Plan.link_target(%{"issue" => %{"repository" => 7, "number" => 1}}, kinds)
    end

    test "an added task's ref is named by later changes, and it lands in its parent's project", %{
      items: items
    } do
      items = put_in(items["api"]["projectId"], "api")

      {:ok, changes} =
        Plan.check_changes(items, [
          %{"op" => "add", "ref" => "a", "fields" => %{"title" => "Routes", "parent" => "api"}},
          %{
            "op" => "add",
            "ref" => "b",
            "fields" => %{"title" => "Handlers", "parent" => "api", "after" => ["a"]}
          }
        ])

      {items, applied} = Plan.apply_changes(items, changes, @now, "fallback", &"new-#{&1}")

      assert Enum.map(applied, & &1["outcome"]) == ["applied", "applied"]
      assert %{"parent" => "api", "projectId" => "api"} = items["new-1"]
      assert %{"parent" => "api", "after" => ["new-1"]} = items["new-2"]
    end

    test "the user's dismissals are skipped, and a change whose task went is stale", %{
      items: items
    } do
      {:ok, changes} =
        Plan.check_changes(items, [
          %{"op" => "add", "ref" => "a", "fields" => %{"title" => "Routes"}},
          %{"op" => "update", "itemId" => "schema", "fields" => %{"due" => "2026-10-30"}},
          %{"op" => "add", "fields" => %{"title" => "Handlers", "after" => ["a", "api"]}}
        ])

      changes = List.update_at(changes, 0, &%{&1 | "dismissed" => true})

      {items, applied} =
        Plan.apply_changes(Plan.remove(items, "schema"), changes, @now, "api", &"new-#{&1}")

      assert [
               %{"outcome" => nil},
               %{"outcome" => "stale", "staleReason" => reason},
               %{"outcome" => "applied"}
             ] = applied

      assert reason == "The task schema is no longer in the plan."
      refute Map.has_key?(items, "new-1")
      assert %{"after" => ["api"], "projectId" => "api"} = items["new-3"]
    end
  end

  describe "views" do
    test "a new plan has a timeline, a board and a list of every task" do
      assert [
               %{"id" => "timeline", "name" => "Timeline", "layout" => "gantt"},
               %{"id" => "board", "name" => "Board", "layout" => "board", "groupBy" => "status"},
               %{"id" => "list", "name" => "All tasks", "layout" => "list"}
             ] = Plan.default_views()
    end

    test "a view gets what it leaves out, and what it cannot hold is refused" do
      assert {:ok,
              %{
                "name" => "Mine",
                "layout" => "list",
                "groupBy" => "none",
                "filter" => %{"hideDone" => true, "text" => ""}
              }} =
               Plan.check_view(%{
                 "name" => " Mine ",
                 "filter" => %{"hideDone" => true},
                 "colour" => "red"
               })

      assert {:error, "colour is not something a view can group by."} =
               Plan.check_view(%{"name" => "Mine", "groupBy" => "colour"})

      assert {:error, "A view needs a name."} = Plan.check_view(%{"name" => ""})

      assert {:error, "notes is not a field a view can show."} =
               Plan.check_view(%{"name" => "Mine", "fields" => ["notes"]})
    end

    test "a view naming an object where text belongs is refused, not a crash" do
      for key <- ~w(layout groupBy sortBy zoom) do
        assert {:error, message} = Plan.check_view(%{"name" => "Mine", key => %{"a" => 1}})
        assert message =~ ~s(%{"a" => 1})
      end

      assert {:error, ~s(%{"a" => 1} is not a field a view can show.)} =
               Plan.check_view(%{"name" => "Mine", "fields" => [%{"a" => 1}]})
    end
  end

  describe "prompts" do
    test "a template has the names it knows filled in and the others kept" do
      assert Plan.fill("{{ today }}: {{item.title}} {{unknown}}", %{
               "today" => @today,
               "item.title" => "API"
             }) ==
               "2026-10-15: API {{unknown}}"
    end

    test "the outline has every task under its parent, with its dates, state and dependencies" do
      items =
        plan([
          {"schema",
           %{
             "title" => "Schema",
             "start" => "2026-10-19",
             "due" => "2026-10-23",
             "projectId" => "api"
           }},
          {"api",
           %{
             "title" => "API",
             "start" => "2026-10-21",
             "due" => "2026-10-30",
             "after" => ["schema"],
             "owner" => "dana"
           }},
          {"routes", %{"title" => "Routes", "parent" => "api"}},
          {"beta", %{"title" => "Beta", "kind" => "milestone", "due" => "2026-11-01"}}
        ])

      derived = Plan.derive(items, @today)

      assert Plan.outline(derived) ==
               """
               - [schema] Schema (task, todo, 0% done): 2026-10-19 to 2026-10-23, project api
               - [api] API (task, todo, 0% done): 2026-10-21 to 2026-10-30, owner dana, waits for Schema [schema], starts before Schema ends
                 - [routes] Routes (task, todo, 0% done): no dates
               - [beta] Beta (milestone, todo, 0% done): on 2026-11-01\
               """

      assert Plan.outline([]) == "The plan has no tasks yet."

      api = Enum.find(derived, &(&1["id"] == "api"))
      values = Plan.values(derived, [api], @today, "API service")

      assert %{
               "project" => "API service",
               "item.title" => "API",
               "item.after" => "Schema (schema)"
             } = values

      assert values["item.subtasks"] == "- [routes] Routes (task, todo, 0% done): no dates"
      assert Plan.values(derived, [], @today, nil)["items"] == "Every task of the plan."
    end
  end

  describe "Slack" do
    test "an update is its health's mark and word, then its text" do
      assert Slack.update(%{"health" => "at-risk", "text" => "Docs slip."}) ==
               ":large_yellow_circle: *At risk*: Docs slip."

      assert Slack.update(%{"health" => "off-track", "text" => "Late."}) ==
               ":red_circle: *Off track*: Late."
    end

    test "an announcement counts the changes the user has not dismissed" do
      run = %{
        "label" => "Reschedule",
        "changes" => [%{"dismissed" => false}, %{"dismissed" => true}]
      }

      assert Slack.announce(run, ["API"]) == "Reschedule has 1 change waiting in HAL-C2: API"

      assert Slack.announce(%{run | "changes" => []}, []) ==
               "Reschedule has 0 changes waiting in HAL-C2"
    end

    test "the status names late tasks, those in progress and the latest health" do
      items = [
        %{
          "title" => "API",
          "due" => "2026-10-30",
          "late" => true,
          "status" => "doing",
          "derivedProgress" => 40
        },
        %{
          "title" => "Docs",
          "due" => "2026-11-02",
          "late" => false,
          "status" => "doing",
          "derivedProgress" => 0
        }
      ]

      assert Slack.status(items, [%{"health" => "on-track", "text" => "Fine."}]) ==
               "Late: API (due 2026-10-30)\nIn progress: Docs (0% done)\nHealth: :large_green_circle: *On track*: Fine."

      assert Slack.status([], []) ==
               "Late: nothing.\nIn progress: nothing.\nHealth: no status update yet."
    end

    test "a command names an action by its id or the first word of its label" do
      actions = [
        %{"id" => "validate", "label" => "Validate progress"},
        %{"id" => "give-feedback", "label" => "Give feedback"}
      ]

      assert Slack.command("", actions) == :status
      assert Slack.command(" status ", actions) == :status
      assert {:run, %{"id" => "validate"}, "API"} = Slack.command("Validate API", actions)

      assert {:run, %{"id" => "give-feedback"}, "Docs and API"} =
               Slack.command("give Docs and API", actions)

      assert {:unknown, "dance"} = Slack.command("dance", actions)
    end

    test "a word that begins more than one label names no action, but an id still does" do
      actions = [
        %{"id" => "check-api", "label" => "Check API"},
        %{"id" => "check-docs", "label" => "Check docs"}
      ]

      assert {:ambiguous, "check", [%{"id" => "check-api"}, %{"id" => "check-docs"}]} =
               Slack.command("Check API", actions)

      assert {:run, %{"id" => "check-docs"}, "Docs"} = Slack.command("check-docs Docs", actions)
    end

    test "run names an action only by its id, even one the command's own words hide" do
      actions = [
        %{"id" => "status", "label" => "Write status update"},
        %{"id" => "run-tests", "label" => "Run tests"}
      ]

      assert Slack.command("Status", actions) == :status
      assert {:run, %{"id" => "status"}, ""} = Slack.command("run status", actions)
      assert {:run, %{"id" => "run-tests"}, "API"} = Slack.command("Run  run-tests API", actions)
      assert {:unknown, "tests"} = Slack.command("run tests", actions)
      assert {:unknown, ""} = Slack.command("run", actions)

      assert Slack.actions("", actions, "/planner") =~
               ~r"^Name the action to run\..*\n/planner run status — Write status update\n"
    end
  end

  describe "a milestone's correction GitHub refused" do
    @repo "acme/api"
    @projects [%{"id" => "p", "kind" => "github", "repository" => @repo}]

    # The milestone "ms" kept the correction of the issue #7 of the task "t" (`misplaced`),
    # which "mr" holds now; `task` is what "t" is by then.
    defp corrected(task) do
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "refs" => %{},
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => %{"repository" => @repo, "number" => 7}}
        }
      }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items = Map.new([milestone.("ms", 3, []), milestone.("mr", 4, ["t"]), {"t", task}])

      assert [{"update", input, took}] =
               Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)

      assert took.(synced)["misplaced"] == %{}
      input
    end

    defp task(issue), do: %{"id" => "t", "projectId" => "p", "after" => [], "issue" => issue}

    test "goes again to the milestone holding the task that still names the issue" do
      input = corrected(task(%{"repository" => @repo, "number" => 7}))
      assert %{"number" => 7, "milestone" => 4} = input
    end

    test "is dropped once the milestone holds the task that still names the issue again" do
      synced = %{
        "after" => ["t"],
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => %{"repository" => @repo, "number" => 7}}
        }
      }

      items = %{"t" => task(%{"repository" => @repo, "number" => 7})}

      assert Sync.settled(synced, %{"after" => ["t"]}, items)["misplaced"] == %{}

      assert %{"misplaced" => %{"acme/api#7" => _}} =
               Sync.settled(synced, %{"after" => []}, items)

      assert Sync.settled(nil, %{"after" => ["t"]}, items) == nil
    end

    test "stays when the milestone holds the task again under another issue, and takes the first out" do
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "refs" => %{},
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => %{"repository" => @repo, "number" => 7}}
        }
      }

      ms = %{
        "id" => "ms",
        "title" => "Launch",
        "due" => nil,
        "after" => ["t"],
        "projectId" => "p",
        "milestone" => %{"repository" => @repo, "number" => 3}
      }

      items = %{"ms" => ms, "t" => task(%{"repository" => @repo, "number" => 8})}
      assert synced == Sync.settled(synced, ms, items)

      assert [{"update", into, took_into}, {"update", out, took_out}] =
               Sync.pushes(%{"sync" => "twoWay"}, synced, ms, items, @projects)

      assert %{"number" => 7, "milestone" => nil} = out
      assert %{"number" => 8, "milestone" => 3} = into

      # The issue the task names now being in the milestone does not clear the mark of
      # the other, if its correction is refused; the correction's landing does, and the
      # task stays on the milestone.
      assert %{"misplaced" => %{"acme/api#7" => _}} = took_into.(synced)
      landed = took_out.(took_into.(synced))
      assert landed["after"] == ["t"]
      assert landed["misplaced"] == %{}
    end

    test "takes the issue out of any milestone once the task names another" do
      input = corrected(task(%{"repository" => @repo, "number" => 8}))
      assert %{"number" => 7, "milestone" => nil} = input
    end

    test "goes to the milestone of a task that took the issue over" do
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "refs" => %{},
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => %{"repository" => @repo, "number" => 7}}
        }
      }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items =
        Map.new([
          milestone.("ms", 3, []),
          milestone.("mr", 4, ["u"]),
          {"t", task(%{"repository" => @repo, "number" => 8})},
          {"u",
           %{
             "id" => "u",
             "projectId" => "p",
             "after" => [],
             "issue" => %{"repository" => @repo, "number" => 7}
           }}
        ])

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)
      asks = for {"update", %{"number" => 7} = input, took} <- ops, do: {input, took}
      assert [{%{"milestone" => 4}, took}] = asks
      assert took.(synced)["misplaced"] == %{}
    end

    test "goes to this milestone when the task that took the issue over is held by it" do
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "refs" => %{},
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => %{"repository" => @repo, "number" => 7}}
        }
      }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items =
        Map.new([
          milestone.("ms", 3, ["u"]),
          milestone.("mr", 4, []),
          {"t", task(%{"repository" => @repo, "number" => 8})},
          {"u",
           %{
             "id" => "u",
             "projectId" => "p",
             "after" => [],
             "issue" => %{"repository" => @repo, "number" => 7}
           }}
        ])

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)
      asks = for {"update", %{"number" => 7} = input, took} <- ops, do: {input, took}
      assert [{%{"milestone" => 3}, took}] = asks
      assert took.(synced)["misplaced"] == %{}
    end

    test "keeps a mark per issue, so a task that left two issues behind loses neither" do
      issue = fn n -> %{"repository" => @repo, "number" => n} end
      op = fn n -> {"t", {"update", issue.(n), nil}} end

      # Two late pushes left #7, then #8, in the milestone "ms" after the task
      # was relinked and moved on; its `synced` remembers only #8 by then, so
      # the #7 mark is the only thing still naming #7.
      synced =
        %{
          "title" => "Launch",
          "due" => nil,
          "after" => ["t"],
          "refs" => %{"t" => issue.(8)}
        }
        |> Sync.misplaced([op.(7)])
        |> Sync.misplaced([op.(8)])

      assert synced["misplaced"] == %{
               "acme/api#7" => %{"task" => "t", "issue" => issue.(7)},
               "acme/api#8" => %{"task" => "t", "issue" => issue.(8)}
             }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items =
        Map.new([milestone.("ms", 3, []), milestone.("mr", 4, ["t"]), {"t", task(issue.(8))}])

      assert [{"update", out, _}, {"update", into, _}] =
               Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)

      assert %{"number" => 7, "milestone" => nil} = out
      assert %{"number" => 8, "milestone" => 4} = into
    end

    test "the older mark survives the newer correction taking, so its issue still goes out" do
      issue = fn n -> %{"repository" => @repo, "number" => n} end

      # As the mark-per-task shape left it: "t" was relinked from #7 to #8 in
      # "ms", #8's correction took and #7's was refused, and `refs` names #8.
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => ["t"],
        "refs" => %{"t" => issue.(8)},
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => issue.(7)},
          "acme/api#8" => %{"task" => "t", "issue" => issue.(8)}
        }
      }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items =
        Map.new([milestone.("ms", 3, []), milestone.("mr", 4, ["t"]), {"t", task(issue.(8))}])

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)
      asks = for {"update", %{"number" => n} = input, took} <- ops, do: {n, input, took}
      assert [{7, _, _}, {8, _, _}] = Enum.sort_by(asks, &elem(&1, 0))

      # #8's correction takes; #7 must still be asked out by the next push.
      {_, _, took8} = Enum.find(asks, &(elem(&1, 0) == 8))
      landed = took8.(synced)
      assert landed["misplaced"] == %{"acme/api#7" => %{"task" => "t", "issue" => issue.(7)}}

      ops = Sync.pushes(%{"sync" => "twoWay"}, landed, items["ms"], items, @projects)

      assert [{"update", %{"number" => 7, "milestone" => nil}, _}] =
               for({"update", input, took} <- ops, do: {"update", input, took})
    end

    test "asks the issue its task left once, though both its removal and its correction send it out" do
      issue = fn n -> %{"repository" => @repo, "number" => n} end

      # "ms" has the task "t" for #7 and a mark for #7; "t" names #8 by now and "ms" holds it.
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => ["t"],
        "refs" => %{"t" => issue.(7)},
        "misplaced" => %{"acme/api#7" => %{"task" => "t", "issue" => issue.(7)}}
      }

      ms = %{
        "id" => "ms",
        "title" => "Launch",
        "due" => nil,
        "after" => ["t"],
        "projectId" => "p",
        "milestone" => %{"repository" => @repo, "number" => 3}
      }

      items = %{"ms" => ms, "t" => task(issue.(8))}

      assert [{"update", out, took_out}, {"update", into, took_into}] =
               Sync.pushes(%{"sync" => "twoWay"}, synced, ms, items, @projects)

      assert %{"number" => 7, "milestone" => nil} = out
      assert %{"number" => 8, "milestone" => 3} = into

      landed = synced |> took_out.() |> took_into.()
      assert %{"after" => ["t"], "refs" => %{"t" => %{"number" => 8}}} = landed
      assert landed["misplaced"] == %{}
    end

    test "reads a mark named for its task, as a plan saved before marks were named for their issue" do
      issue = fn n -> %{"repository" => @repo, "number" => n} end

      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "refs" => %{},
        "misplaced" => %{"t" => issue.(7)}
      }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items =
        Map.new([
          milestone.("ms", 3, []),
          milestone.("mr", 4, ["u"]),
          {"t", task(issue.(8))},
          {"u", %{"id" => "u", "projectId" => "p", "after" => [], "issue" => issue.(7)}}
        ])

      assert Sync.settled(synced, %{"after" => []}, items)["misplaced"] ==
               %{"acme/api#7" => %{"task" => "t", "issue" => issue.(7)}}

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)
      asks = for {"update", %{"number" => 7} = input, took} <- ops, do: {input, took}
      assert [{%{"milestone" => 4}, took}] = asks
      assert took.(synced)["misplaced"] == %{}
    end

    test "an issue sent out of any milestone and to another in one push is asked once, for the other" do
      issue = fn n -> %{"repository" => @repo, "number" => n} end

      # "t" left #7 in "ms" (remembered in `refs`, marked), names #8 in "mr"
      # by now, and "u" names #7 in "mr": one push would send #7 out by the
      # move and in by the correction.
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => ["t"],
        "refs" => %{"t" => issue.(7)},
        "misplaced" => %{"acme/api#7" => %{"task" => "t", "issue" => issue.(7)}}
      }

      milestone = fn id, number, after_ ->
        {id,
         %{
           "id" => id,
           "title" => "Launch",
           "due" => nil,
           "after" => after_,
           "projectId" => "p",
           "milestone" => %{"repository" => @repo, "number" => number}
         }}
      end

      items =
        Map.new([
          milestone.("ms", 3, []),
          milestone.("mr", 4, ["t", "u"]),
          {"t", task(issue.(8))},
          {"u", %{"id" => "u", "projectId" => "p", "after" => [], "issue" => issue.(7)}}
        ])

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, items["ms"], items, @projects)
      asks = for {"update", %{"number" => 7} = input, took} <- ops, do: {input, took}
      assert [{%{"milestone" => 4}, took}] = asks

      landed = took.(synced)
      assert landed["misplaced"] == %{}
      refute "t" in landed["after"]
    end

    test "asks an issue two tasks send out of any milestone once, and runs both tasks' tooks" do
      issue = fn n -> %{"repository" => @repo, "number" => n} end

      # "ms" held "old" for #7 (remembered in `refs`) and has a mark for "new" over #7;
      # both name #8 by now, so #7 leaves any milestone by both of them.
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => ["old"],
        "refs" => %{"old" => issue.(7)},
        "misplaced" => %{"acme/api#7" => %{"task" => "new", "issue" => issue.(7)}}
      }

      ms = %{
        "id" => "ms",
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "projectId" => "p",
        "milestone" => %{"repository" => @repo, "number" => 3}
      }

      items = %{
        "ms" => ms,
        "old" => %{"id" => "old", "projectId" => "p", "after" => [], "issue" => issue.(8)},
        "new" => %{"id" => "new", "projectId" => "p", "after" => [], "issue" => issue.(8)}
      }

      assert [{"update", input, took}] =
               Sync.pushes(%{"sync" => "twoWay"}, synced, ms, items, @projects)

      assert %{"number" => 7, "milestone" => nil} = input
      landed = took.(synced)
      assert landed["after"] == []
      assert landed["misplaced"] == %{}
    end

    test "drops an ask for an issue whose saved ref is not whole, instead of raising" do
      ms = %{
        "id" => "ms",
        "title" => "Launch",
        "due" => nil,
        "after" => ["t"],
        "projectId" => "p",
        "milestone" => %{"repository" => @repo, "number" => 3}
      }

      synced = %{"title" => "Launch", "due" => nil, "after" => [], "refs" => %{}}
      items = %{"ms" => ms, "t" => task(%{"repository" => @repo})}

      assert [] = Sync.pushes(%{"sync" => "twoWay"}, synced, ms, items, @projects)
    end

    test "takes the issue out of any milestone once the task names none" do
      input = corrected(Map.delete(task(nil), "issue"))
      assert %{"number" => 7, "milestone" => nil} = input
    end

    test "takes the issue out of any milestone once the task is gone from the plan" do
      synced = %{
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "refs" => %{},
        "misplaced" => %{
          "acme/api#7" => %{"task" => "t", "issue" => %{"repository" => @repo, "number" => 7}}
        }
      }

      milestone = %{
        "id" => "ms",
        "title" => "Launch",
        "due" => nil,
        "after" => [],
        "projectId" => "p",
        "milestone" => %{"repository" => @repo, "number" => 3}
      }

      items = %{"ms" => milestone}

      assert [{"update", input, took}] =
               Sync.pushes(%{"sync" => "twoWay"}, synced, milestone, items, @projects)

      assert %{"number" => 7, "milestone" => nil} = input
      assert took.(synced)["misplaced"] == %{}
    end
  end

  describe "pushes" do
    test "a relink and an owner change in one push take the old owner off the old issue" do
      projects = [%{"id" => "p", "kind" => "github", "repository" => "acme/api"}]
      issue = fn n -> %{"repository" => "acme/api", "number" => n} end

      new = %{
        "id" => "t",
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "status" => "todo",
        "owner" => "dana",
        "issue" => issue.(8),
        "after" => [],
        "parent" => nil,
        "projectId" => "p"
      }

      synced = %{
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "state" => "open",
        "owner" => "alice",
        "start" => nil,
        "due" => nil,
        "after" => [],
        "parent" => nil,
        "refs" => %{},
        "issue" => issue.(7)
      }

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, new, %{"t" => new}, projects)

      assert {"removeAssignees", %{"number" => 7, "assignees" => ["alice"]}, _} =
               Enum.find(ops, &(elem(&1, 0) == "removeAssignees"))

      assert {"addAssignees", %{"number" => 8, "assignees" => ["dana"]}, _} =
               Enum.find(ops, &(elem(&1, 0) == "addAssignees"))
    end

    test "a case-only owner change pushes no assignee ops" do
      projects = [%{"id" => "p", "kind" => "github", "repository" => "acme/api"}]
      issue = %{"repository" => "acme/api", "number" => 7}

      new = %{
        "id" => "t",
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "status" => "todo",
        "owner" => "Alice",
        "issue" => issue,
        "after" => [],
        "parent" => nil,
        "projectId" => "p"
      }

      synced = %{
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "state" => "open",
        "owner" => "alice",
        "start" => nil,
        "due" => nil,
        "after" => [],
        "parent" => nil,
        "refs" => %{},
        "issue" => issue
      }

      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, new, %{"t" => new}, projects)

      refute Enum.any?(ops, &(elem(&1, 0) in ["addAssignees", "removeAssignees"]))
    end

    test "a stored owner that is no login is never taken off, only the new one added" do
      projects = [%{"id" => "p", "kind" => "github", "repository" => "acme/api"}]
      issue = %{"repository" => "acme/api", "number" => 7}

      base = %{
        "id" => "t",
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "status" => "todo",
        "issue" => issue,
        "after" => [],
        "parent" => nil,
        "projectId" => "p"
      }

      synced = %{
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "state" => "open",
        "owner" => "Dana Smith",
        "start" => nil,
        "due" => nil,
        "after" => [],
        "parent" => nil,
        "refs" => %{},
        "issue" => issue
      }

      new = Map.put(base, "owner", "dana")
      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, new, %{"t" => new}, projects)

      assert {"addAssignees", %{"number" => 7, "assignees" => ["dana"]}, _} =
               Enum.find(ops, &(elem(&1, 0) == "addAssignees"))

      refute Enum.any?(ops, &(elem(&1, 0) == "removeAssignees"))

      cleared = Map.put(base, "owner", nil)
      ops = Sync.pushes(%{"sync" => "twoWay"}, synced, cleared, %{"t" => cleared}, projects)
      refute Enum.any?(ops, &(elem(&1, 0) in ["addAssignees", "removeAssignees"]))
    end

    test "a bot or managed user as the old owner is taken off like any login" do
      projects = [%{"id" => "p", "kind" => "github", "repository" => "acme/api"}]
      issue = %{"repository" => "acme/api", "number" => 7}

      for old <- ["copilot[bot]", "dana_acme"] do
        new = %{
          "id" => "t",
          "title" => "T",
          "notes" => nil,
          "labels" => [],
          "status" => "todo",
          "owner" => "dana",
          "issue" => issue,
          "after" => [],
          "parent" => nil,
          "projectId" => "p"
        }

        synced = %{
          "title" => "T",
          "notes" => nil,
          "labels" => [],
          "state" => "open",
          "owner" => old,
          "start" => nil,
          "due" => nil,
          "after" => [],
          "parent" => nil,
          "refs" => %{},
          "issue" => issue
        }

        ops = Sync.pushes(%{"sync" => "twoWay"}, synced, new, %{"t" => new}, projects)

        assert {"removeAssignees", %{"number" => 7, "assignees" => [^old]}, _} =
                 Enum.find(ops, &(elem(&1, 0) == "removeAssignees"))
      end
    end

    test "a push takes a stored owner off exactly for the logins Plan takes" do
      projects = [%{"id" => "p", "kind" => "github", "repository" => "acme/api"}]
      issue = %{"repository" => "acme/api", "number" => 7}

      new = %{
        "id" => "t",
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "status" => "todo",
        "owner" => "erin",
        "issue" => issue,
        "after" => [],
        "parent" => nil,
        "projectId" => "p"
      }

      synced = %{
        "title" => "T",
        "notes" => nil,
        "labels" => [],
        "state" => "open",
        "start" => nil,
        "due" => nil,
        "after" => [],
        "parent" => nil,
        "refs" => %{},
        "issue" => issue
      }

      # The same cases `Plan` makes an owner by and the host suite runs, so the
      # push's own gate cannot drift from either.
      for bad <- HalC2.Test.LoginCases.bad() do
        ops =
          Sync.pushes(
            %{"sync" => "twoWay"},
            Map.put(synced, "owner", bad),
            new,
            %{"t" => new},
            projects
          )

        refute Enum.any?(ops, &(elem(&1, 0) == "removeAssignees")),
               "expected no removal for #{inspect(bad)}"
      end

      for good <- HalC2.Test.LoginCases.good() do
        ops =
          Sync.pushes(
            %{"sync" => "twoWay"},
            Map.put(synced, "owner", good),
            new,
            %{"t" => new},
            projects
          )

        assert {"removeAssignees", %{"number" => 7, "assignees" => [^good]}, _} =
                 Enum.find(ops, &(elem(&1, 0) == "removeAssignees")),
               "expected a removal for #{inspect(good)}"
      end
    end
  end
end
