defmodule HalC2.Steps.Navigation.EnvironmentThemes do
  @moduledoc """
  Steps for `features/navigation/environment-themes.feature`.

  Published themes are observed the way a client sees them: a socket subscribed to
  the MC's config receives `config.themes` frames. A client following the
  environment's default theme is modelled by `context.theme_clients` (name →
  `%{theme, applied, published, settings, synced}`) and applies the settings it
  receives with the web client's rule (`apps/web/src/hooks/useDefaultTheme.ts`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient

  @built_in ~w(t3-chat grove ocean ember iris)

  # --- publishing themes from the MC ---------------------------------------------

  step "the MC's themes folder is empty", context do
    context = watch_themes(context)
    assert File.ls!(themes_dir(context)) == []
    assert context.published == []
    context
  end

  step "{string} with a dark palette is written into the themes folder",
       %{args: [file]} = context do
    write_theme(context, file, palette("Nightfall", "#7aa2f7"))
    context
  end

  step "within a few seconds the MC publishes a theme with the id {string}",
       %{args: [id]} = context do
    await_themes(context, &(id in ids(&1)))
  end

  step "a client is watching the MC's configuration", context do
    watch_themes(context)
  end

  step "a theme file is added to the themes folder", context do
    write_theme(context, "aurora.json", palette("Aurora", "#9ece6a"))
    context
  end

  step "the client receives the updated list of published themes", context do
    context = await_themes(context, &("aurora" in ids(&1)))
    assert "aurora" in ids(context.published)
    context
  end

  step "the MC publishes {string}", %{args: [id]} = context do
    context = watch_themes(context)
    write_theme(context, "#{id}.json", palette(String.capitalize(id), "#7aa2f7"))
    await_themes(context, &(id in ids(&1)))
  end

  # A different length, so the change shows in the file's size as well as its time.
  step "the user changes the accent in {string}", %{args: [file]} = context do
    id = Path.basename(file, ".json")
    write_theme(context, file, palette(String.capitalize(id), "#fa0"))
    Map.put(context, :new_accent, "#fa0")
  end

  step "the published {string} has the new accent", %{args: [id]} = context do
    await_themes(context, fn themes ->
      Enum.any?(themes, &(&1["id"] == id and &1["accent"] == context.new_accent))
    end)
  end

  step "{string} is no longer published", %{args: [id]} = context do
    context = await_themes(context, &(id not in ids(&1)))
    refute File.exists?(Path.join(themes_dir(context), "#{id}.json"))
    context
  end

  step "a theme file gives only a name, an appearance, a canvas and an accent", context do
    context = watch_themes(context)

    write_theme(context, "dusk.json", %{
      "name" => "Dusk",
      "appearance" => "dark",
      "canvas" => "#1a1b26",
      "accent" => "#bb9af7"
    })

    Map.put(context, :written, "dusk")
  end

  step "the theme is published", context do
    context = await_themes(context, &(context.written in ids(&1)))
    theme = Enum.find(context.published, &(&1["id"] == context.written))
    assert %{"canvas" => "#1a1b26", "accent" => "#bb9af7", "appearance" => "dark"} = theme
    context
  end

  # A good theme is published first, so "the other themes" exist; the bad file
  # follows, then a second good one: once that one is published, the MC has
  # read the bad file too.
  step ~r/^a theme file that is (?<problem>.+) is written into the themes folder$/,
       %{args: [problem]} = context do
    context = watch_themes(context)
    write_theme(context, "aurora.json", palette("Aurora", "#9ece6a"))
    context = await_themes(context, &("aurora" in ids(&1)))

    bad = write_unusable(context, problem)
    write_theme(context, "zenith.json", palette("Zenith", "#e0af68"))
    context = await_themes(context, &("zenith" in ids(&1)))
    Map.put(context, :bad_id, bad)
  end

  step "it is not published", context do
    refute context.bad_id in ids(context.published),
           "#{context.bad_id} was published: #{inspect(ids(context.published))}"

    refute context.bad_id in ids(HalC2.EnvironmentThemes.current())
    context
  end

  step "the other themes are still published", context do
    assert Enum.sort(ids(context.published)) == ["aurora", "zenith"]
    context
  end

  step "{int} valid theme files are written into the themes folder", %{args: [count]} = context do
    context = watch_themes(context)

    for i <- 1..count do
      name = "theme-#{String.pad_leading(Integer.to_string(i), 2, "0")}"
      write_theme(context, "#{name}.json", palette(name, "#7aa2f7"))
    end

    Map.put(context, :written_count, count)
  end

  step "at most {int} themes are published", %{args: [max]} = context do
    assert context.written_count > max
    context = await_themes(context, &(length(&1) >= max))
    assert length(context.published) == max

    # All of them are in the folder; the MC's current set, what it publishes, stays capped.
    assert length(File.ls!(themes_dir(context))) == context.written_count
    assert length(HalC2.EnvironmentThemes.current()) == max
    context
  end

  # --- a default theme set on the server -------------------------------------------

  step "two clients are connected", context do
    follow_default(context, ["first", "second"])
  end

  step "both clients switch to {string}", %{args: [theme]} = context do
    context = context |> await_theme("first", theme) |> await_theme("second", theme)
    assert context.theme_clients["first"].theme == theme
    assert context.theme_clients["second"].theme == theme
    context
  end

  step "a client is offline", context do
    context |> follow_default("default") |> World.disconnect("default")
  end

  step "the client switches to {string}", %{args: [theme]} = context do
    await_theme(context, "default", theme)
  end

  step "the server default is {string} and the client applied it", %{args: [theme]} = context do
    server_default(context, theme)
  end

  step "the server default is {string} and the user switched to {string}",
       %{args: [theme, chosen]} = context do
    context |> server_default(theme) |> choose(chosen)
  end

  step "the server default is {string}", %{args: [theme]} = context do
    server_default(context, theme)
  end

  step "the client keeps {string}", %{args: [theme]} = context do
    assert context.theme_clients["default"].theme == theme
    context
  end

  # `hal-c2 theme ...` is `mix hal_c2.theme ...` on the MC. A theme must be published
  # before it can be set, so "nightfall" is published first when it is not yet.
  step ~r/^the server operator runs "hal-c2 theme (?<args>[^"]+)"(?: again)?$/,
       %{args: [args]} = context do
    args = String.split(args)

    if match?(["set", _], args) do
      [_, id] = args
      if id not in @built_in, do: publish(context, id)
    end

    before = context |> Map.get(:theme_clients, %{}) |> Map.new(fn {k, v} -> {k, v.theme} end)
    Map.merge(context, %{operator_output: run_theme_task(args), themes_before: before})
  end

  step "no default is set", context do
    assert HalC2.EnvironmentThemes.show()["defaultTheme"] == nil
    {:ok, saved} = HalC2.Settings.saved()
    refute Map.has_key?(saved, "defaultTheme")
    refute Map.has_key?(saved, "defaultThemeSetAt")
    assert context.operator_output =~ "Environment theme cleared."
    context
  end

  step "every client keeps its current theme", context do
    assert context.themes_before != %{}

    Enum.reduce(context.themes_before, context, fn {name, theme}, context ->
      context =
        follow(context, name, &(&1.settings != nil and &1.settings["defaultTheme"] == nil))

      assert context.theme_clients[name].theme == theme
      context
    end)
  end

  step "the default theme and every published theme are listed", context do
    show = HalC2.EnvironmentThemes.show()
    assert show["defaultTheme"] != nil
    assert show["published"] != []
    assert context.operator_output =~ ~s(Environment theme: "#{show["defaultTheme"]}".)
    assert context.operator_output =~ "Published themes: #{Enum.join(show["published"], ", ")}."
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp themes_dir(context), do: Path.join(context.mc.home, "themes")

  # Starts the theme service with a short check interval (restored afterwards)
  # and the settings service, whose watchers the pushes go through.
  defp services(context) do
    unless Map.get(context, :theme_services) do
      previous = Application.get_env(:hal_c2, :theme_check_ms)
      Application.put_env(:hal_c2, :theme_check_ms, 50)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:hal_c2, :theme_check_ms, previous),
          else: Application.delete_env(:hal_c2, :theme_check_ms)
      end)

      Mc.ensure(HalC2.Settings)
      Mc.ensure(HalC2.EnvironmentThemes)
    end

    Map.put(context, :theme_services, true)
  end

  defp palette(name, accent),
    do: %{
      "name" => name,
      "appearance" => "dark",
      "canvas" => "#1a1b26",
      "accent" => accent,
      "colors" => %{"background" => "#1a1b26", "foreground" => "#c0caf5", "primary" => accent}
    }

  defp write_theme(context, file, theme) do
    File.mkdir_p!(themes_dir(context))
    File.write!(Path.join(themes_dir(context), file), JSON.encode!(theme))
  end

  defp publish(context, id) do
    unless File.exists?(Path.join(themes_dir(context), "#{id}.json")),
      do: write_theme(context, "#{id}.json", palette(String.capitalize(id), "#7aa2f7"))
  end

  # Writes a file the MC must skip; returns the id it would have had.
  defp write_unusable(context, problem) do
    dir = themes_dir(context)

    case problem do
      "not valid JSON" ->
        File.write!(Path.join(dir, "broken.json"), ~s({"name": "Broken", ))
        "broken"

      "without any colors" ->
        write_theme(context, "plain.json", %{"name" => "Plain", "appearance" => "dark"})
        "plain"

      "larger than 32 KB" ->
        theme = Map.put(palette("Bulky", "#7aa2f7"), "notes", String.duplicate("x", 33 * 1024))
        write_theme(context, "bulky.json", theme)
        "bulky"

      "a symbolic link" ->
        target = Path.join(Mc.tmp_dir(context.mc, "theme"), "linked.json")
        File.write!(target, JSON.encode!(palette("Linked", "#7aa2f7")))
        File.ln_s!(target, Path.join(dir, "linked.json"))
        "linked"

      "named system.json" ->
        write_theme(context, "system.json", palette("System", "#7aa2f7"))
        "system"

      "named after a built-in theme" ->
        write_theme(context, "grove.json", palette("Grove", "#7aa2f7"))
        "grove"

      "named with capital letters" ->
        write_theme(context, "Nightfall.json", palette("Nightfall", "#7aa2f7"))
        "Nightfall"
    end
  end

  defp ids(themes), do: Enum.map(themes, & &1["id"])

  defp themes_frame?(frame), do: frame["t"] == "config.themes"

  defp themes_client(context), do: context.clients["themes"]

  # A socket subscribed to the MC's config, keeping the last published set.
  defp watch_themes(context) do
    context = services(context)

    if context.clients["themes"] do
      context
    else
      client = Mc.sub(Mc.connect(context.mc), 1, config_shape())
      {frame, client} = Mc.await(client, &themes_frame?/1)
      context |> World.put_client("themes", client) |> Map.put(:published, frame["themes"])
    end
  end

  # Waits (the MC checks every 50 ms here) for a published set matching `fun`.
  defp await_themes(context, fun) do
    if fun.(context.published) do
      context
    else
      {frame, client} =
        Mc.await(themes_client(context), &(themes_frame?(&1) and fun.(&1["themes"])))

      context |> World.put_client("themes", client) |> Map.put(:published, frame["themes"])
    end
  end

  defp config_shape, do: %{"type" => "config", "mc" => Atom.to_string(node())}

  defp server_default(context, theme) do
    context = services(context)
    publish(context, theme)
    assert :ok = HalC2.EnvironmentThemes.set_default(theme)
    context |> follow_default("default") |> await_theme("default", theme)
  end

  defp choose(context, theme),
    do: update_in(context, [:theme_clients, "default"], &%{&1 | theme: theme})

  # Connects each of `names` to the MC's config as a client following its default
  # theme. A client starts on its own theme and has applied no default yet. All
  # sockets open before any subscribes, as opening one reads the process mailbox.
  defp follow_default(context, names) when is_list(names) do
    context = services(context)
    context = Enum.reduce(names, context, &World.put_client(&2, &1, Mc.connect(&2.mc)))

    Enum.reduce(names, context, fn name, context ->
      model =
        get_in(context, [Access.key(:theme_clients, %{}), name]) ||
          %{theme: "t3-chat", applied: nil, published: [], settings: nil}

      context
      |> World.put_client(name, Mc.sub(context.clients[name], 1, config_shape()))
      |> put_in([Access.key(:theme_clients, %{}), name], Map.put(model, :synced, false))
      |> Map.put(:on_choose, fn context, choice -> choose(context, choice) end)
      |> Map.put(:after_reconnect, fn context -> follow_default(context, "default") end)
      # Synced once the snapshot and the published themes that follow it are in.
      |> follow(name, & &1.synced)
    end)
  end

  defp follow_default(context, name), do: follow_default(context, [name])

  defp await_theme(context, name, theme), do: follow(context, name, &(&1.theme == theme))

  # Feeds `name`'s config frames to its model until `done?` holds.
  defp follow(context, name, done?) do
    model = context.theme_clients[name]

    if done?.(model) do
      context
    else
      {frame, client} = WsClient.recv(context.clients[name], 2_000)

      context
      |> World.put_client(name, client)
      |> put_in([:theme_clients, name], observe(model, frame))
      |> follow(name, done?)
    end
  end

  defp observe(model, %{"t" => "config", "config" => config}),
    do: apply_default(%{model | settings: config["settings"] || %{}})

  defp observe(model, %{"t" => "config.themes", "themes" => themes}),
    do: apply_default(%{model | published: ids(themes), synced: true})

  defp observe(model, %{"t" => "config.settings", "settings" => settings}),
    do: apply_default(%{model | settings: settings})

  defp observe(model, _frame), do: model

  # A set is applied once: its generation is the theme and when it was set, and a
  # client adopts a generation it has not applied when it knows the theme.
  defp apply_default(%{settings: settings} = model) when is_map(settings) do
    theme = settings["defaultTheme"]
    set_at = settings["defaultThemeSetAt"]

    generation =
      cond do
        not is_binary(theme) or theme == "" -> nil
        is_binary(set_at) and set_at != "" -> "#{theme}@#{set_at}"
        true -> theme
      end

    if generation && generation != model.applied && theme in (@built_in ++ model.published),
      do: %{model | applied: generation, theme: theme},
      else: model
  end

  defp apply_default(model), do: model

  # Runs the operator's command in this process, capturing what it prints.
  defp run_theme_task(args) do
    home = Application.fetch_env!(:hal_c2, :home)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.HalC2.Theme.run(args)
    after
      Mix.shell(shell)
    end

    assert Application.fetch_env!(:hal_c2, :home) == home
    collect_output([])
  end

  defp collect_output(lines) do
    receive do
      {:mix_shell, :info, [line]} -> collect_output([line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
