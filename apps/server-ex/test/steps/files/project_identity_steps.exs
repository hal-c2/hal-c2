defmodule T3.Steps.Files.ProjectIdentity do
  @moduledoc """
  Steps for `features/files/project-identity.feature`: a project's icon through a
  `project-favicon` asset URL fetched over HTTP, and the themes a node publishes
  from `<home>/themes` in its config subscription (`config.themes` frames). The ids
  a client was last offered go in `context.offered`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  @config 8101

  # --- icons -------------------------------------------------------------------------

  step "the checkout of {string} has {string}", %{args: [project, file]} = context do
    path = Path.join(World.project(context, project).root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s(<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>\n))
    Map.put(context, :favicon, path)
  end

  step "the checkout of {string} has no favicon", %{args: [project]} = context do
    root = World.project(context, project).root
    assert Path.wildcard(Path.join(root, "**/*{favicon,icon,logo}*"), match_dot: true) == []
    context
  end

  step "a client asks for the icon of {string}", %{args: [project]} = context do
    root = World.project(context, project).root

    {reply, context} =
      World.call(context, "assets.createUrl", %{
        "resource" => %{"_tag" => "project-favicon", "cwd" => root}
      })

    assert {:ok, %{"relativeUrl" => url}} = reply
    Map.put(context, :icon, get(context, url))
  end

  step "the favicon is served", context do
    assert {200, body} = context.icon
    assert body == File.read!(context.favicon)
    context
  end

  step "the node answers that there is no icon", context do
    assert {404, _} = context.icon
    context
  end

  # --- themes ------------------------------------------------------------------------

  step "the T3 home of {string} has the theme file {string}", %{args: [_env, file]} = context do
    theme(context, file)
    context
  end

  step "a client connects to {string}", %{args: [_env]} = context do
    connect(context)
  end

  step "a client is connected to {string}", %{args: [_env]} = context do
    connect(context)
  end

  # As a Given it publishes the theme first; afterwards it checks what was offered.
  step "the theme {string} is offered", %{args: [id]} = context do
    context =
      if Map.has_key?(context, :offered),
        do: context,
        else: context |> tap(&theme(&1, "themes/#{id}.json")) |> connect()

    assert id in context.offered, "#{id} not in #{inspect(context.offered)}"
    context
  end

  step "the user adds the theme file {string}", %{args: [file]} = context do
    theme(context, file)
    context
  end

  step "the client is offered the theme {string} within a few seconds", %{args: [id]} = context do
    await_themes(context, &(id in &1))
  end

  step "{string} is no longer offered", %{args: [id]} = context do
    await_themes(context, &(id not in &1))
  end

  step "the themes folder has a file named {string}", %{args: [name]} = context do
    bad(context, String.replace_suffix(name, ".json", ""), fn path -> write(path, valid(name)) end)
  end

  step "the themes folder has a file larger than {int} KB", %{args: [kb]} = context do
    bad(context, "big", fn path ->
      write(path, String.duplicate(" ", kb * 1024) <> JSON.encode!(valid("Big")))
    end)
  end

  step "the themes folder has a link to a theme elsewhere", context do
    bad(context, "linked", fn path ->
      elsewhere = Path.join(Node.tmp_dir(context.node, "elsewhere"), "linked.json")
      write(elsewhere, valid("Linked"))
      File.ln_s!(elsewhere, path)
    end)
  end

  step "the themes folder has a file that is not valid JSON", context do
    bad(context, "broken", fn path -> write(path, "{\"name\": ") end)
  end

  step "the themes folder has a theme with the colour {string} instead of hex",
       %{args: [colour]} = context do
    bad(context, "named-colour", fn path -> write(path, %{valid("Red") | "canvas" => colour}) end)
  end

  step "the themes folder has a theme without colours", context do
    bad(context, "colourless", fn path ->
      write(path, Map.drop(valid("Plain"), ~w(canvas accent colors)))
    end)
  end

  step "the node reads its themes", context do
    connect(context)
  end

  step "that theme is not offered", context do
    refute context.bad_theme in context.offered
    context
  end

  step "the other themes are offered", context do
    assert context.offered == ["dawn"]
    context
  end

  step "the themes folder has {int} valid theme files", %{args: [count]} = context do
    for n <- 1..count, do: theme(context, "themes/t#{pad(n)}.json")
    context
  end

  step "at most {int} themes are offered", %{args: [max]} = context do
    assert length(context.offered) == max
    context
  end

  step "the themes folder has valid theme files totalling {int} KB", %{args: [kb]} = context do
    # Files of 20 KB, each under the per-file limit.
    sizes =
      for n <- 1..div(kb, 20) do
        id = "t#{pad(n)}"
        body = JSON.encode!(%{valid(id) | "name" => id}) <> String.duplicate(" ", 20 * 1024)
        write(Path.join([context.node.home, "themes", "#{id}.json"]), body)
        {id, byte_size(body)}
      end

    Map.put(context, :theme_sizes, sizes)
  end

  step "only the themes within the first {int} KB are offered", %{args: [kb]} = context do
    expected =
      context.theme_sizes
      |> Enum.scan({nil, 0}, fn {id, size}, {_, total} -> {id, total + size} end)
      |> Enum.take_while(fn {_, total} -> total <= kb * 1024 end)
      |> Enum.map(&elem(&1, 0))

    assert context.offered == expected
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp valid(name),
    do: %{"name" => name, "appearance" => "dark", "canvas" => "#101820", "accent" => "#f2aa4c"}

  defp theme(context, file) do
    id = Path.basename(file, ".json")
    write(Path.join(context.node.home, file), valid(String.capitalize(id)))
  end

  # A rule-breaking file next to one good theme, "dawn".
  defp bad(context, id, write_bad) do
    theme(context, "themes/dawn.json")
    write_bad.(Path.join([context.node.home, "themes", "#{id}.json"]))
    Map.put(context, :bad_theme, id)
  end

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(is_binary(content), do: content, else: JSON.encode!(content)))
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp connect(context) do
    # The folder is checked often so a change reaches clients quickly.
    Application.put_env(:t3, :theme_check_ms, 50)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :theme_check_ms) end)
    Node.ensure(T3.Settings)
    Node.ensure(T3.EnvironmentThemes)

    client =
      Node.sub(Node.connect(context.node), @config, %{
        "type" => "config",
        "node" => Atom.to_string(node())
      })

    context = World.put_client(context, "themes", client)
    await_themes(context, fn _ -> true end)
  end

  defp await_themes(context, fun) do
    {frame, client} =
      Node.await(
        World.client(context, "themes"),
        &(&1["t"] == "config.themes" and &1["id"] == @config and fun.(ids(&1))),
        5_000
      )

    context |> World.put_client("themes", client) |> Map.put(:offered, ids(frame))
  end

  defp ids(frame), do: Enum.map(frame["themes"], & &1["id"])

  defp get(context, url) do
    :inets.start()

    {:ok, {{_, status, _}, _headers, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{context.node.port}#{url}", []}, [],
        body_format: :binary
      )

    {status, body}
  end
end
