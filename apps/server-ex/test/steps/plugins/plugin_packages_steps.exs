defmodule HalC2.Steps.Plugins.Packages do
  @moduledoc """
  Plugin packages for scenarios (`HalC2.Plugins.Package`), written as directories
  into the MC's plugins directory. The default package is a small code-review
  plugin: a manifest with an icon, screenshots, typed settings, permissions and
  UI parts, and an extension whose calls exercise the host API. Its
  `handle_event/2` tells `:hal_c2_plugin_probe` what it heard.
  """

  alias HalC2.Steps.Plugins.Fixtures

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  @doc "The manifest of the default package `id`."
  def manifest(id) do
    %{
      "id" => id,
      "name" => "Code Review",
      "version" => "1.0.0",
      "apiVersion" => 1,
      "description" => "Agents review pull requests.",
      "author" => %{"name" => "HAL-C2"},
      "license" => "MIT",
      "icon" => "assets/icon.svg",
      "screenshots" => [
        %{"path" => "assets/reviews.png", "caption" => "The reviews page"},
        %{"path" => "assets/thread.png"}
      ],
      "permissions" => [
        permission("pullRequests:read"),
        permission("pullRequests:write"),
        permission("threads:create")
      ],
      "settings" => [
        %{
          "key" => "host",
          "label" => "Host",
          "type" => "choice",
          "options" => [
            %{"value" => "github", "label" => "GitHub"},
            %{"value" => "gitlab", "label" => "GitLab", "disabled" => true}
          ],
          "default" => "github"
        },
        %{"key" => "repositories", "label" => "Repositories", "type" => "list", "default" => []},
        %{
          "key" => "skipDrafts",
          "label" => "Skip drafts",
          "type" => "boolean",
          "default" => true
        },
        %{
          "key" => "prompt",
          "label" => "Prompt",
          "type" => "longText",
          "default" => "Review this pull request."
        },
        %{"key" => "token", "label" => "Token", "type" => "secret"}
      ],
      "contributes" => %{
        "pages" => [%{"id" => "reviews", "title" => "Reviews", "qml" => "ui/ReviewsPage.qml"}],
        "threadKinds" => [
          %{
            "kind" => "review",
            "label" => "Review",
            "rowMark" => "ui/ReviewRowMark.qml",
            "header" => "ui/ReviewHeader.qml"
          }
        ],
        "slots" => [%{"slot" => "statusbar", "qml" => "ui/Status.qml"}]
      }
    }
  end

  @doc "A permission request with the reason the default package gives."
  def permission(id), do: %{"id" => id, "reason" => "The reviews need it (#{id})."}

  @doc """
  Writes package `id` and rescans. `opts`: `manifest` (merged over the default),
  `json` (the manifest's raw text), `mc: false` for UI parts only, `raise` (a call
  that raises), `dir` (the directory name, default `id`).
  """
  def install(context, id, opts \\ []) do
    dir = dir(context, opts[:dir] || id)
    File.rm_rf!(dir)
    manifest = Map.merge(manifest(id), opts[:manifest] || %{})

    files =
      %{
        "plugin.json" => opts[:json] || JSON.encode!(manifest),
        "assets/icon.svg" => ~s(<svg xmlns="http://www.w3.org/2000/svg"/>),
        "assets/reviews.png" => @png,
        "assets/thread.png" => @png
      }
      |> Map.merge(Map.new(qml_paths(manifest), &{&1, "import QtQuick\nItem {}\n"}))
      |> Map.merge(if opts[:mc] == false, do: %{}, else: %{"mc/#{id}.ex" => source(id, opts)})

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    Fixtures.rescan(Fixtures.ensure(context))
  end

  def dir(context, id), do: Path.join([context.mc.home, "plugins", id])

  @doc "Every QML file a manifest names."
  def qml_paths(manifest) do
    contributes = manifest["contributes"] || %{}

    Enum.map(contributes["pages"] || [], & &1["qml"]) ++
      Enum.flat_map(contributes["threadKinds"] || [], &[&1["rowMark"], &1["header"]]) ++
      Enum.map(contributes["slots"] || [], & &1["qml"]) ++
      List.wrap(contributes["settingsPage"])
  end

  @doc "Installs the default package unless the scenario already did."
  def ensure(context, id) do
    if File.dir?(dir(context, id)), do: context, else: install(context, id)
  end

  defp source(id, opts) do
    module =
      Module.concat(HalC2PluginFixture.Package, Macro.camelize(String.replace(id, "-", "_")))

    raising = opts[:raise]

    """
    defmodule #{inspect(module)} do
      @behaviour HalC2.Plugins.Extension
      alias HalC2.Plugins.Host

      @id #{inspect(id)}

      @impl true
      def call(method, _input, _context) when method == #{inspect(raising)},
        do: raise("the review index is corrupt")

      def call("reviews.list", _input, context),
        do: {:ok, %{"reviews" => [%{"number" => 12, "state" => "running"}], "host" => context.settings["host"]}}

      def call("reviews.publish", reviews, _context) do
        Host.publish(@id, "reviews", reviews)
        {:ok, %{}}
      end

      def call("notes.save", note, _context) do
        File.write!(Path.join(Host.data_dir(@id), "note.json"), JSON.encode!(note))
        {:ok, %{}}
      end

      def call("notes.read", _input, _context),
        do: {:ok, JSON.decode!(File.read!(Path.join(Host.data_dir(@id), "note.json")))}

      def call("threads.start", input, _context) do
        with {:ok, _} <- Host.launch_thread(@id, input["kind"], input["thread"], listed: input["listed"]),
             do: {:ok, %{"threadId" => input["thread"]["threadId"]}}
      end

      def call(method, _input, _context), do: {:error, "no method " <> method}

      @impl true
      def handle_event(event, context) do
        if probe = Process.whereis(:hal_c2_plugin_probe),
          do: send(probe, {:plugin_event, context.id, event})
      end
    end
    """
  end
end

defmodule HalC2.Steps.Plugins.PluginPackages do
  @moduledoc "Steps for `features/plugins/plugin-packages.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.{Fixtures, Packages, Turns}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # --- what a package is -----------------------------------------------------------------

  step "the plugins directory contains the package {string} with a name, description, author, icon and two screenshots",
       %{args: [id]} = context do
    Packages.install(context, id)
  end

  step "{string} is listed with its name, description, author and version",
       %{args: [id]} = context do
    assert %{
             "source" => "package",
             "name" => "Code Review",
             "description" => "Agents review pull requests.",
             "author" => %{"name" => "HAL-C2"},
             "version" => "1.0.0",
             "status" => "disabled"
           } = Fixtures.entry(id)

    Map.put(context, :plugin, id)
  end

  step "its icon and screenshots can be fetched from the MC", context do
    entry = Fixtures.entry(context.plugin)

    {icon, context} = file(context, context.plugin, entry["icon"])
    assert %{"encoding" => "utf8", "content" => "<svg" <> _} = icon

    for %{"path" => path} <- entry["screenshots"], reduce: context do
      context ->
        {shot, context} = file(context, context.plugin, path)
        assert %{"encoding" => "base64", "revision" => revision} = shot
        assert revision == entry["revision"]

        assert Base.decode64!(shot["content"]) ==
                 File.read!(Path.join(Packages.dir(context, context.plugin), path))

        context
    end
  end

  step "the plugins directory contains the package {string} whose manifest is not valid JSON",
       %{args: [id]} = context do
    Packages.install(context, id, json: "{ \"id\": ")
  end

  step "{string} is listed with an error naming its manifest", %{args: [id]} = context do
    assert %{"status" => "error", "error" => error} = Fixtures.entry(id)
    assert error =~ "plugin.json"
    context
  end

  step "the plugins directory contains the directory {string} whose manifest says its id is {string}",
       %{args: [dir, id]} = context do
    Packages.install(context, id, dir: dir)
  end

  step "{string} is listed with an error saying the directory and the id differ",
       %{args: [dir]} = context do
    assert %{"status" => "error", "error" => error} = Fixtures.entry(dir)
    assert error =~ "its directory is \"#{dir}\""
    context
  end

  step "{string} is listed with an error saying what an id may hold", %{args: [dir]} = context do
    assert %{"status" => "error", "error" => error} = Fixtures.entry(dir)
    assert error =~ "an id is lowercase letters, digits and dashes"
    context
  end

  step "the plugins directory contains the package {string} whose choice setting lists bare strings as options",
       %{args: [id]} = context do
    setting = %{"key" => "host", "label" => "Host", "type" => "choice", "options" => ["github"]}
    Packages.install(context, id, manifest: %{"settings" => [setting]})
  end

  step "the plugins directory contains the package {string} whose setting is on or off, with the default {string}",
       %{args: [id, default]} = context do
    setting = %{"key" => "host", "label" => "Host", "type" => "boolean", "default" => default}
    Packages.install(context, id, manifest: %{"settings" => [setting]})
  end

  step "the plugins directory contains the package {string} whose setting is a choice whose default is turned off",
       %{args: [id]} = context do
    Packages.install(context, id, manifest: %{"settings" => [host_choice("gitlab")]})
  end

  step "the plugins directory contains the package {string} whose setting is a choice whose default is not one of its options",
       %{args: [id]} = context do
    Packages.install(context, id, manifest: %{"settings" => [host_choice("forgejo")]})
  end

  step "the plugins directory contains the package {string} whose manifest has {string}",
       %{args: [id, part]} = context do
    wrong = %{
      "screenshots that are an object" => %{"screenshots" => %{"x" => 1}},
      "a page without a title" => %{
        "contributes" => %{"pages" => [%{"id" => "reviews", "qml" => "ui/Reviews.qml"}]}
      },
      "an author that is only a name" => %{"author" => "HAL-C2"},
      "a setting that is not an object" => %{"settings" => ["host"]},
      "a permission without a reason" => %{"permissions" => [%{"id" => "projects:read"}]}
    }

    Packages.install(context, id, manifest: Map.fetch!(wrong, part))
  end

  step "{string} is listed with an error naming {string}", %{args: [id, where]} = context do
    assert %{"status" => "error", "error" => error} = Fixtures.entry(id)
    assert error =~ "plugin.json does not fit its schema: #{where} "
    context
  end

  step "{string} is listed with an error naming its setting", %{args: [id]} = context do
    assert %{"status" => "error", "error" => error} = Fixtures.entry(id)
    assert error =~ "setting"
    assert error =~ ~s("host")
    context
  end

  step "the plugins directory contains the package {string} built for a newer plugin API",
       %{args: [id]} = context do
    Packages.install(context, id, manifest: %{"apiVersion" => 2})
  end

  step "the plugins directory contains the package {string} with a UI part and no MC part",
       %{args: [id]} = context do
    Packages.install(context, id,
      mc: false,
      manifest: %{
        "permissions" => [],
        "contributes" => %{"slots" => [%{"slot" => "statusbar", "qml" => "ui/Clock.qml"}]}
      }
    )
  end

  step "{string} is running", %{args: [id]} = context do
    assert %{"status" => "running"} = Fixtures.entry(id)
    Map.put(context, :plugin, id)
  end

  step "its UI part is offered to clients", context do
    entry = Fixtures.entry(context.plugin)
    assert %{"runsCode" => false, "kinds" => []} = entry
    assert [%{"slot" => "statusbar", "qml" => qml}] = entry["contributes"]["slots"]
    {part, context} = file(context, context.plugin, qml)
    assert %{"encoding" => "utf8", "content" => "import QtQuick" <> _} = part
    context
  end

  # --- UI parts --------------------------------------------------------------------------

  step "the package {string} is enabled", %{args: [id]} = context do
    context |> Packages.ensure(id) |> enable(id) |> Map.put(:plugin, id)
  end

  step "the package {string} is disabled", %{args: [id]} = context do
    context |> Packages.ensure(id) |> Map.put(:plugin, id)
  end

  step "a client asks for the UI parts of {string}", %{args: [id]} = context do
    paths = Packages.qml_paths(Packages.manifest(id))

    {replies, context} =
      Enum.map_reduce(paths, context, fn path, context ->
        {reply, context} = World.call(context, "plugins.file", %{"id" => id, "path" => path})
        {{path, reply}, context}
      end)

    Map.merge(context, %{parts: replies, reply: elem(hd(replies), 1)})
  end

  step "it gets each QML file of the package with the package's version", context do
    revision = Fixtures.entry(context.plugin)["revision"]
    assert is_binary(revision)

    for {path, reply} <- context.parts do
      assert {:ok, %{"path" => ^path, "encoding" => "utf8", "revision" => ^revision} = part} =
               reply

      assert part["content"] == File.read!(Path.join(Packages.dir(context, context.plugin), path))
    end

    context
  end

  step "files outside the package's directory cannot be asked for", context do
    outside = Path.join([context.mc.home, "plugins", "outside.txt"])
    File.write!(outside, "not the plugin's")
    # A link in the package does not lead out of it either.
    File.ln_s!(outside, Path.join(Packages.dir(context, context.plugin), "ui/Outside.qml"))
    File.ln_s!(Path.dirname(outside), Path.join(Packages.dir(context, context.plugin), "up"))

    for path <- [
          "../outside.txt",
          "ui/../../outside.txt",
          "/etc/hostname",
          "ui/Outside.qml",
          "up/outside.txt"
        ],
        reduce: context do
      context ->
        {reply, context} =
          World.call(context, "plugins.file", %{"id" => context.plugin, "path" => path})

        assert {:error, _, %{"_tag" => "PluginFileNotFound"}} = reply
        context
    end
  end

  step "a hidden file of {string} changes and the MC rescans", %{args: [id]} = context do
    path = Path.join(Packages.dir(context, id), "ui/.shared/Colors.qml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "import QtQuick\nQtObject {}\n")
    context = Fixtures.rescan(context)
    before = Fixtures.entry(id)["revision"]
    File.write!(path, "import QtQuick\nQtObject { property color accent }\n")
    context |> Fixtures.rescan() |> Map.merge(%{plugin: id, revision_before: before})
  end

  step "{string} has a new revision", %{args: [id]} = context do
    assert %{"status" => "running", "revision" => revision} = Fixtures.entry(id)
    assert revision != context.revision_before
    context
  end

  step "a new version of {string} whose second MC file does not compile is placed in the plugins directory",
       %{args: [id]} = context do
    dir = Packages.dir(context, id)
    [source] = Path.wildcard(Path.join(dir, "mc/*.ex"))

    File.write!(
      source,
      String.replace(File.read!(source), ~s("number" => 12), ~s("number" => 13))
    )

    File.write!(Path.join(dir, "mc/zz_broken.ex"), """
    defmodule HalC2PluginFixture.Package.Broken do
      def broken, do: undefined_call()
    end
    """)

    context |> Fixtures.rescan() |> Map.put(:plugin, id)
  end

  step "a new version of {string} whose MC files hold two plugin modules is placed in the plugins directory",
       %{args: [id]} = context do
    dir = Packages.dir(context, id)
    [source] = Path.wildcard(Path.join(dir, "mc/*.ex"))

    File.write!(
      source,
      String.replace(File.read!(source), ~s("number" => 12), ~s("number" => 13))
    )

    File.write!(Path.join(dir, "mc/zz_second.ex"), """
    defmodule HalC2PluginFixture.Package.Second do
      @behaviour HalC2.Plugins.Extension
    end
    """)

    context |> Fixtures.rescan() |> Map.put(:plugin, id)
  end

  step "the reload is reported as failed because of {string}", %{args: [reason]} = context do
    assert Fixtures.entry(context.plugin)["reloadError"] =~ reason
    context
  end

  step "{string} answers as its old version", %{args: [id]} = context do
    assert %{"status" => "running"} = Fixtures.entry(id)
    {reply, context} = call(context, id, "reviews.list", %{})
    assert {:ok, %{"reviews" => [%{"number" => 12}]}} = reply
    context
  end

  step "the request is refused because the plugin is not running", context do
    assert {:error, message, %{"_tag" => "PluginNotRunning"}} = context.reply
    assert message =~ "not running"
    context
  end

  step "a client watches the plugin list", context do
    context = Packages.ensure(context, "code-review")
    client = World.client(context)
    client = Mc.sub(client, 7, %{"type" => "plugins", "environment" => context.mc.environment})
    {_, client} = Mc.await(client, &(&1["t"] == "plugins" and &1["id"] == 7))
    World.put_client(context, "watcher", client)
  end

  step "the client is told that {string} is running", %{args: [id]} = context do
    running? = fn frame ->
      frame["t"] == "plugins" and
        Enum.any?(frame["plugins"], &(&1["id"] == id and &1["status"] == "running"))
    end

    {_, client} = Mc.await(World.client(context, "watcher"), running?, 2_000)
    World.put_client(context, "watcher", client)
  end

  # --- settings --------------------------------------------------------------------------

  step "the package {string} declares a choice, a list, a switch, a long text and a secret",
       %{args: [id]} = context do
    context |> Packages.install(id) |> Map.put(:plugin, id)
  end

  step "the user opens its settings without having saved any", context do
    {plugins, context} = Fixtures.list(context, context.mc.environment)
    Map.put(context, :plugin_entry, Enum.find(plugins, &(&1["id"] == context.plugin)))
  end

  step "each field shows its declared default", context do
    %{"settingsSchema" => fields, "settings" => settings} = context.plugin_entry
    assert Enum.map(fields, & &1["type"]) == ~w(choice list boolean longText secret)

    for %{"key" => key, "default" => default} <- fields,
        do: assert(settings[key] == default, "#{key} shows #{inspect(settings[key])}")

    context
  end

  step "the secret shows only whether it is set", context do
    %{"settingsSchema" => fields, "settings" => settings} = context.plugin_entry
    assert %{"secret" => true} = Enum.find(fields, &(&1["key"] == "token"))
    refute Map.has_key?(settings, "token")

    {_, context} =
      World.call!(context, "plugins.saveSettings", %{
        "id" => context.plugin,
        "settings" => %{"token" => "s3cret"}
      })

    assert Fixtures.entry(context.plugin)["settings"]["token"] == "••••••"
    context
  end

  step "the package {string} declares the switch {string}", %{args: [id, key]} = context do
    context = Packages.install(context, id)

    {_, context} =
      World.call!(context, "plugins.saveSettings", %{"id" => id, "settings" => %{key => false}})

    Map.merge(context, %{plugin: id, settings_before: Fixtures.entry(id)["settings"]})
  end

  step "the user saves the text {string} for {string}", %{args: [text, key]} = context do
    {reply, context} =
      World.call(context, "plugins.saveSettings", %{
        "id" => context.plugin,
        "settings" => %{key => text}
      })

    Map.put(context, :reply, reply)
  end

  step "the save is refused naming {string}", %{args: [key]} = context do
    assert {:error, message, %{"_tag" => "PluginSettingsInvalid"}} = context.reply
    assert message =~ key
    context
  end

  # --- permissions -----------------------------------------------------------------------

  step "the package {string} asks to read pull requests, write pull request reviews and start threads",
       %{args: [id]} = context do
    context |> Packages.install(id) |> Map.put(:plugin, id)
  end

  step "the user lists the plugins", context do
    {plugins, context} = Fixtures.list(context, context.mc.environment)
    Map.put(context, :plugin_entry, Enum.find(plugins, &(&1["id"] == context.plugin)))
  end

  step "{string} shows each permission with the reason it gives", %{args: [id]} = context do
    assert context.plugin_entry["id"] == id

    assert Enum.map(context.plugin_entry["permissions"], &Map.take(&1, ["id", "reason"])) ==
             Enum.map(
               ~w(pullRequests:read pullRequests:write threads:create),
               &Packages.permission/1
             )

    context
  end

  step "none of them is granted", context do
    assert Enum.all?(context.plugin_entry["permissions"], &(&1["granted"] == false))
    context
  end

  step "the user enables {string} accepting its permissions", %{args: [id]} = context do
    context |> Packages.ensure(id) |> enable(id) |> Map.put(:plugin, id)
  end

  step "{string} is running with those permissions granted", %{args: [id]} = context do
    assert %{"status" => "running", "permissions" => permissions} = Fixtures.entry(id)
    assert Enum.all?(permissions, & &1["granted"])
    assert HalC2.Plugins.granted(id) == ~w(pullRequests:read pullRequests:write threads:create)
    context
  end

  step "the user enables {string} without accepting its permissions", %{args: [id]} = context do
    context = Packages.ensure(context, id)
    {reply, context} = World.call(context, "plugins.enable", %{"id" => id})
    Map.merge(context, %{reply: reply, plugin: id})
  end

  step "the MC refuses saying which permissions need approval", context do
    assert {:error, message, %{"_tag" => "PluginConsentRequired", "permissions" => missing}} =
             context.reply

    assert missing == ~w(pullRequests:read pullRequests:write threads:create)
    assert message =~ "start threads that run agents"
    context
  end

  step "a client enables {string} sending an object as the accepted permissions",
       %{args: [id]} = context do
    context = Packages.ensure(context, id)

    {reply, context} =
      World.call(context, "plugins.enable", %{"id" => id, "acceptPermissions" => %{}})

    Map.merge(context, %{reply: reply, plugin: id})
  end

  step "the MC refuses saying the accepted permissions are a list", context do
    assert {:error, message, _} = context.reply
    assert message =~ "acceptPermissions is a list"
    context
  end

  step "plugins can still be listed", context do
    {_, context} = World.call!(context, "plugins.list", %{})
    assert Fixtures.entry(context.plugin)
    context
  end

  step "{string} stays disabled", %{args: [id]} = context do
    assert %{"enabled" => false, "status" => "disabled"} = Fixtures.entry(id)
    context
  end

  step "the package {string} was granted only to read pull requests", %{args: [id]} = context do
    context
    |> Packages.install(id,
      manifest: %{"permissions" => [Packages.permission("pullRequests:read")]}
    )
    |> enable(id)
  end

  step "{string} tries to start a thread", %{args: [id]} = context do
    {reply, context} = call(context, id, "threads.start", thread_input(context))
    Map.merge(context, %{reply: reply, plugin: id})
  end

  step "the MC refuses the call naming the missing permission", context do
    assert {:error, message, %{"_tag" => "PluginCallFailed"}} = context.reply
    assert message =~ "threads:create"
    context
  end

  step "the refusal is recorded on {string}", %{args: [id]} = context do
    assert %{"denied" => ["threads:create"]} = Fixtures.entry(id)
    context
  end

  step "{string} is running with read access to pull requests", %{args: [id]} = context do
    context
    |> Packages.install(id,
      manifest: %{"permissions" => [Packages.permission("pullRequests:read")]}
    )
    |> enable(id)
    |> Map.put(:plugin, id)
  end

  step "a version that also asks to write pull request reviews replaces it", context do
    Packages.install(context, context.plugin,
      manifest: %{
        "version" => "1.1.0",
        "permissions" => [
          Packages.permission("pullRequests:read"),
          Packages.permission("pullRequests:write")
        ]
      }
    )
  end

  step "{string} is stopped and listed as waiting for approval of the new permission",
       %{args: [id]} = context do
    assert %{"status" => "awaitingConsent", "enabled" => true, "permissions" => permissions} =
             Fixtures.entry(id)

    assert [%{"id" => "pullRequests:write"}] = Enum.reject(permissions, & &1["granted"])
    context
  end

  step "it runs again once the user accepts it", context do
    {_, context} =
      World.call!(context, "plugins.enable", %{
        "id" => context.plugin,
        "acceptPermissions" => ["pullRequests:write"]
      })

    assert %{"status" => "running", "version" => "1.1.0"} = Fixtures.entry(context.plugin)
    context
  end

  step "{string} is running with read and write access to pull requests",
       %{args: [id]} = context do
    context
    |> Packages.install(id,
      manifest: %{
        "permissions" => [
          Packages.permission("pullRequests:read"),
          Packages.permission("pullRequests:write")
        ]
      }
    )
    |> enable(id)
    |> Map.put(:plugin, id)
  end

  step "a version that only asks to read pull requests replaces it", context do
    Packages.install(context, context.plugin,
      manifest: %{
        "version" => "1.1.0",
        "permissions" => [Packages.permission("pullRequests:read")]
      }
    )
  end

  step "{string} can no longer write pull request reviews", %{args: [id]} = context do
    assert %{"status" => "running", "version" => "1.1.0"} = Fixtures.entry(id)
    assert HalC2.Plugins.granted(id) == ["pullRequests:read"]
    refute HalC2.Plugins.Host.granted?(id, "pullRequests:write")
    context
  end

  step "a later version that asks to write them again waits for the user", context do
    context =
      Packages.install(context, context.plugin,
        manifest: %{
          "version" => "1.2.0",
          "permissions" => [
            Packages.permission("pullRequests:read"),
            Packages.permission("pullRequests:write")
          ]
        }
      )

    assert %{"status" => "awaitingConsent"} = Fixtures.entry(context.plugin)
    context
  end

  step "the package {string} has an MC part", %{args: [id]} = context do
    context |> Packages.install(id) |> Map.put(:plugin, id)
  end

  step "{string} is marked as running code with the MC's own access", %{args: [id]} = context do
    assert %{"id" => ^id, "runsCode" => true, "kinds" => ["extension"]} = context.plugin_entry
    context
  end

  # --- calls and topics ------------------------------------------------------------------

  step "the package {string} is running", %{args: [id]} = context do
    context |> Packages.ensure(id) |> enable(id) |> Map.put(:plugin, id)
  end

  step "its UI asks it for {string}", %{args: [method]} = context do
    {reply, context} = call(context, context.plugin, method)
    Map.put(context, :reply, reply)
  end

  step "the plugin's answer reaches the UI", context do
    assert {:ok, %{"reviews" => [%{"number" => 12}], "host" => "github"}} = context.reply
    context
  end

  step "the package {string} raises while answering {string}", %{args: [id, method]} = context do
    context |> Packages.install(id, raise: method) |> enable(id) |> Map.put(:plugin, id)
  end

  step "the UI gets the plugin's error", context do
    assert {:error, message, %{"_tag" => "PluginCallFailed"}} = context.reply
    assert message =~ "the review index is corrupt"
    context
  end

  step "the MC keeps serving other requests", context do
    assert %{"status" => "running"} = Fixtures.entry(context.plugin)
    {reply, context} = call(context, context.plugin, "notes.save", %{"ok" => true})
    assert {:ok, _} = reply
    context
  end

  step "two clients watch the {string} topic of {string}", %{args: [topic, id]} = context do
    context = context |> Packages.ensure(id) |> enable(id)

    for name <- ["first", "second"], reduce: Map.put(context, :plugin, id) do
      context -> watch(context, name, id, topic, nil)
    end
  end

  step "{string} publishes a new list of reviews", %{args: [id]} = context do
    {{:ok, _}, context} = call(context, id, "reviews.publish", [%{"number" => 13}])
    context
  end

  step "both clients get the new list", context do
    for name <- ["first", "second"], reduce: context do
      context -> await_topic(context, name, [%{"number" => 13}])
    end
  end

  step "{string} published a list of reviews", %{args: [id]} = context do
    context = context |> Packages.ensure(id) |> enable(id)
    {{:ok, _}, context} = call(context, id, "reviews.publish", [%{"number" => 14}])
    Map.put(context, :plugin, id)
  end

  step "a client starts watching the {string} topic of {string}",
       %{args: [topic, id]} = context do
    watch(context, "watcher", id, topic, :any)
  end

  step "it gets that list without waiting for the next change", context do
    assert context.first_value == [%{"number" => 14}]
    context
  end

  step "{string} saved a record in its data directory", %{args: [id]} = context do
    context = context |> Packages.ensure(id) |> enable(id)
    {{:ok, _}, context} = call(context, id, "notes.save", %{"reviewed" => [12, 13]})
    Map.put(context, :plugin, id)
  end

  step "{string} reads the same record back", %{args: [id]} = context do
    {reply, context} = call(context, id, "notes.read")
    assert {:ok, %{"reviewed" => [12, 13]}} = reply
    context
  end

  # --- plugin threads --------------------------------------------------------------------

  step "{string} is running with permission to start threads", %{args: [id]} = context do
    context |> Packages.ensure(id) |> enable(id) |> Map.put(:plugin, id)
  end

  step "{string} starts a {string} thread in a project", %{args: [id, kind]} = context do
    start_thread(context, id, kind, true)
  end

  step "{string} starts a {string} thread that is not listed", %{args: [id, kind]} = context do
    context |> Packages.ensure(id) |> enable(id) |> start_thread(id, kind, false)
  end

  step "{string} started a {string} thread", %{args: [id, kind]} = context do
    context |> Packages.ensure(id) |> enable(id) |> start_thread(id, kind, true)
  end

  step "the thread is marked as a {string} thread of {string}", %{args: [kind, id]} = context do
    assert %{"plugin" => %{"id" => ^id, "kind" => ^kind, "listed" => true}} =
             thread(context.plugin_thread)

    assert %{"plugin" => %{"id" => ^id, "kind" => ^kind}} =
             World.await_row(context.plugin_thread, & &1["plugin"])

    context
  end

  step "it was created by the system on behalf of a plugin", context do
    assert %{"createdBy" => "system", "creationSource" => "server", "plugin" => %{}} =
             thread(context.plugin_thread)

    context
  end

  step "the turn in that thread finishes", context do
    Fixtures.probe()
    finish_turn(context, "m1")
  end

  step "{string} is told the thread and how the turn ended", %{args: [id]} = context do
    thread_id = context.plugin_thread

    assert_receive {:plugin_event, ^id,
                    %{
                      "type" => "turn.finished",
                      "threadId" => ^thread_id,
                      "status" => "completed",
                      "plugin" => %{"id" => ^id, "kind" => "review"}
                    }},
                   2_000

    context
  end

  step "{string} is removed", %{args: [id]} = context do
    File.rm_rf!(Packages.dir(context, id))
    context = Fixtures.rescan(context)
    refute Fixtures.entry(id)
    context
  end

  step "the thread can still be opened, read and continued", context do
    assert %{"title" => "Review #12"} = thread(context.plugin_thread)
    context = finish_turn(context, "m2")
    assert length(Turns.runs(stream(context.plugin_thread))) == 1
    context
  end

  step "the thread is marked as not listed", context do
    assert %{"plugin" => %{"listed" => false}} = thread(context.plugin_thread)
    context
  end

  step "it can still be opened by its id", context do
    assert %{"plugin" => %{"listed" => false}} = World.await_row(context.plugin_thread, & &1)
    assert %{"title" => "Review #12"} = thread(context.plugin_thread)
    context
  end

  # --- helpers ---------------------------------------------------------------------------

  defp host_choice(default) do
    %{
      "key" => "host",
      "label" => "Host",
      "type" => "choice",
      "default" => default,
      "options" => [
        %{"value" => "github", "label" => "GitHub"},
        %{"value" => "gitlab", "label" => "GitLab", "disabled" => true}
      ]
    }
  end

  defp enable(context, id) do
    accepted = Enum.map(Fixtures.entry(id)["permissions"], & &1["id"])

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => id, "acceptPermissions" => accepted})

    assert %{"status" => "running"} = Fixtures.entry(id)
    context
  end

  defp file(context, id, path) do
    {result, context} = World.call!(context, "plugins.file", %{"id" => id, "path" => path})
    {result, context}
  end

  defp call(context, id, method, input \\ nil),
    do: World.call(context, "plugins.call", %{"id" => id, "method" => method, "input" => input})

  defp watch(context, name, id, topic, expected) do
    sub = System.unique_integer([:positive])

    shape = %{
      "type" => "plugin",
      "environment" => context.mc.environment,
      "id" => id,
      "topic" => topic
    }

    client = context |> World.client(name) |> Mc.sub(sub, shape)
    {frame, client} = Mc.await(client, &(&1["t"] == "plugin" and &1["id"] == sub), 2_000)
    if expected != :any, do: assert(frame["value"] == expected)

    context
    |> World.put_client(name, client)
    |> Map.put(:first_value, frame["value"])
  end

  defp await_topic(context, name, value) do
    {_, client} =
      Mc.await(
        World.client(context, name),
        &(&1["t"] == "plugin" and &1["value"] == value),
        2_000
      )

    World.put_client(context, name, client)
  end

  defp thread_input(context) do
    context =
      if context[:projects] in [nil, %{}], do: World.create_project(context, "api"), else: context

    %{
      "kind" => "review",
      "thread" => %{
        "threadId" => "th-review-#{System.unique_integer([:positive])}",
        "projectId" => World.project(context).id,
        "title" => "Review #12",
        "modelSelection" => %{"instanceId" => "codex", "model" => "fake/one"}
      }
    }
  end

  defp start_thread(context, id, kind, listed) do
    context =
      if context[:projects] in [nil, %{}], do: World.create_project(context, "api"), else: context

    input = thread_input(context) |> Map.put("kind", kind) |> Map.put("listed", listed)
    {{:ok, %{"threadId" => thread_id}}, context} = call(context, id, "threads.start", input)
    World.await_row(thread_id, & &1)
    Map.put(context, :plugin_thread, thread_id)
  end

  defp finish_turn(context, message_id) do
    context = Turns.providers(context)
    thread_id = context.plugin_thread
    {{:ok, _}, context} = World.dispatch(context, Turns.message(thread_id, message_id, "review"))

    World.await_stream(thread_id, fn state ->
      runs = Turns.runs(state)
      runs != [] and Enum.all?(runs, &(&1["status"] == "completed")) and runs
    end)

    context
  end

  defp stream(thread_id), do: HalC2.Streams.Server.state(HalC2.Streams.ensure(thread_id))

  defp thread(thread_id), do: HalC2.StreamState.get(stream(thread_id), "thread")[thread_id]
end
