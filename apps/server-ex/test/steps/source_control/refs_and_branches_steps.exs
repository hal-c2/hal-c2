defmodule T3.Steps.SourceControl.RefsAndBranches do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  defp git(context, args), do: World.git!(context.cwd, args)

  defp refs(context) do
    assert {:ok, %{"refs" => refs}} = context.reply
    refs
  end

  defp names(context), do: Enum.map(refs(context), & &1["name"])

  defp list_refs(context, input) do
    {reply, context} = World.call(context, "vcs.listRefs", Map.put(input, "cwd", context.cwd))
    Map.put(context, :reply, reply)
  end

  # As the branch picker does: switch the checkout, then record the branch on the thread.
  defp switch(context, ref) do
    {reply, context} =
      World.call(context, "vcs.switchRef", %{"cwd" => context.cwd, "refName" => ref})

    context = Map.put(context, :reply, reply)

    case reply do
      {:ok, %{"refName" => branch}} ->
        id = World.thread_id(context, context.thread_title)

        {{:ok, _}, context} =
          World.dispatch(context, %{
            "type" => "thread.metadata.update",
            "threadId" => id,
            "branch" => branch,
            "worktreePath" => nil
          })

        context

      _ ->
        context
    end
  end

  defp commit_time(context, ref), do: git(context, ["log", "-1", "--format=%ct", ref])

  step "{string} has the branches {string}, {string} and {string}",
       %{args: [_title | branches]} = context do
    existing = git(context, ["branch", "--format=%(refname:short)"])

    for branch <- branches, not String.contains?(existing, branch) do
      # Older work than anything on the current branch.
      System.cmd("git", ["branch", branch, "main"], cd: context.cwd)
    end

    World.commit!(context.cwd, %{"src/tax.ts" => "export const tax = 1\n"}, "Add tax")
    assert Enum.all?(branches, &(git(context, ["branch", "--list", &1]) != ""))
    context
  end

  step "{string} is marked current and listed first", %{args: [name]} = context do
    assert [%{"name" => ^name, "current" => true} | _] = refs(context)
    context
  end

  step "{string} is marked default and listed next", %{args: [name]} = context do
    assert [_, %{"name" => ^name, "isDefault" => true} | _] = refs(context)
    context
  end

  step "the other branches follow, most recently committed first", context do
    [_, _ | rest] = refs(context)
    assert rest != []
    times = Enum.map(rest, &commit_time(context, &1["name"]))
    assert times == Enum.sort(times, :desc)
    assert Enum.all?(rest, &(&1["current"] == false and &1["isDefault"] == false))
    context
  end

  step "the user searches the branch list for {string}", %{args: [query]} = context do
    list_refs(context, %{"query" => query})
  end

  step "only {string} is listed", %{args: [name]} = context do
    assert names(context) == [name]
    context
  end

  step "{string} and {string} point at the same place", %{args: [local, remote]} = context do
    git(context, ["push", "-q", "origin", local])
    git(context, ~w(fetch -q origin))
    assert git(context, ["rev-parse", local]) == git(context, ["rev-parse", remote])
    context
  end

  step "the user lists all refs", context do
    list_refs(context, %{})
  end

  step "{string} is not listed on its own", %{args: [name]} = context do
    assert "main" in names(context)
    refute name in names(context)
    context
  end

  step "it is listed when the user asks for matching remote refs too", context do
    context = list_refs(context, %{"includeMatchingRemoteRefs" => true})

    assert %{"isRemote" => true, "remoteName" => "origin"} =
             Enum.find(refs(context), &(&1["name"] == "origin/main"))

    context
  end

  step "the user lists branches", context do
    list_refs(context, %{"refKind" => "local"})
  end

  step "{string} is marked with that worktree's path", %{args: [name]} = context do
    ref = Enum.find(refs(context), &(&1["name"] == name))
    assert ref["worktreePath"] == context.other_worktree
    assert ref["current"] == false
    context
  end

  step "the user switches the thread to {string}", %{args: [ref]} = context do
    switch(context, ref)
  end

  step "the user switches to {string}", %{args: [ref]} = context do
    switch(context, ref)
  end

  step "the checkout is on {string}", %{args: [branch]} = context do
    assert git(context, ~w(branch --show-current)) == branch
    context
  end

  step "the thread's branch reads {string}", %{args: [branch]} = context do
    assert World.thread(context, context.thread_title)["branch"] == branch
    context
  end

  step "{string} exists and there is no local {string}",
       %{args: ["origin/" <> branch, branch]} = context do
    git(context, ["push", "-q", "origin", "HEAD:refs/heads/#{branch}"])
    git(context, ~w(fetch -q origin))
    assert git(context, ["branch", "--list", branch]) == ""
    context
  end

  step "a local {string} tracking {string} is checked out",
       %{args: [branch, upstream]} = context do
    assert {:ok, %{"refName" => ^branch}} = context.reply
    assert git(context, ~w(branch --show-current)) == branch
    assert git(context, ~w(rev-parse --abbrev-ref --symbolic-full-name @{upstream})) == upstream
    context
  end

  step "a file is named {string} and the branch {string} no longer exists",
       %{args: [file, branch]} = context do
    World.commit!(context.cwd, %{file => "committed\n"}, "Add #{file}")
    File.write!(Path.join(context.cwd, file), "edited\n")
    assert git(context, ["branch", "--list", branch]) == ""
    Map.merge(context, %{kept_file: file, kept_content: "edited\n"})
  end

  step "the switch fails and the file is left as it was", context do
    assert {:error, _, _} = context.reply
    assert File.read!(Path.join(context.cwd, context.kept_file)) == context.kept_content
    context
  end

  step "the user searched the branch list for {string}", %{args: [query]} = context do
    context |> list_refs(%{"query" => query}) |> Map.put(:query, query)
  end

  step "no ref matches", context do
    assert {:ok, %{"refs" => [], "totalCount" => 0}} = context.reply
    context
  end

  step "the user creates it", context do
    {reply, context} =
      World.call(context, "vcs.createRef", %{
        "cwd" => context.cwd,
        "refName" => context.query,
        "switchRef" => true
      })

    Map.put(context, :reply, reply)
  end

  step "{string} is created and the checkout switches to it", %{args: [branch]} = context do
    assert {:ok, %{"refName" => ^branch}} = context.reply
    assert git(context, ~w(branch --show-current)) == branch
    context
  end

  step "the user creates the branch {string} without switching", %{args: [branch]} = context do
    {reply, context} =
      World.call(context, "vcs.createRef", %{
        "cwd" => context.cwd,
        "refName" => branch,
        "switchRef" => false
      })

    Map.put(context, :reply, reply)
  end

  step "{string} exists and the checkout stays on {string}",
       %{args: [branch, current]} = context do
    assert {:ok, _} = context.reply
    assert git(context, ["branch", "--list", branch]) != ""
    assert git(context, ~w(branch --show-current)) == current
    context
  end

  step "uncommitted changes in {string} conflict with {string}",
       %{args: [file, other]} = context do
    current = git(context, ~w(branch --show-current))
    git(context, ["checkout", "-q", other])
    World.commit!(context.cwd, %{file => "on #{other}\n"}, "Change #{file} on #{other}")
    git(context, ["checkout", "-q", current])
    World.commit!(context.cwd, %{file => "on #{current}\n"}, "Change #{file} on #{current}")
    File.write!(Path.join(context.cwd, file), "work in progress\n")
    Map.merge(context, %{kept_file: file, kept_content: "work in progress\n"})
  end

  step "the switch fails with git's explanation", context do
    assert {:error, _, detail} = context.reply
    assert detail["detail"] =~ "would be overwritten by checkout"
    assert git(context, ~w(branch --show-current)) == "feature/tax"
    context
  end

  step "the changes in {string} are kept", %{args: [file]} = context do
    assert File.read!(Path.join(context.cwd, file)) == context.kept_content
    context
  end
end
