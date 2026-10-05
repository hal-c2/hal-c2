defmodule HalC2.Upgrade.Code do
  @moduledoc """
  Installs a version that only changes HAL-C2's own code (`HalC2.Upgrade`).

  Compiled modules run on any platform and any patch of the Erlang runtime, so such
  a version does not bring a runtime: its release is the running one with HAL-C2's
  applications taken from the bundle. The Erlang runtime, the dependencies and their
  native libraries stay the ones this machine already has, now and at the next
  start, which is why a bundle built for another platform, or with another patch of
  Erlang, serves as well as this machine's own.
  """

  # Installed for the build machine's platform (`stage_cursor_acp` in mix.exs), so
  # they stay the running version's; the manifest's `packages` says when they change.
  @platform_packages "priv/cursor-acp/node_modules"

  @doc """
  Writes release `target` under `root` from the release `running` describes and the
  bundle's own applications. Directories already there are left as they are.
  """
  def install(bundle, root, running, target) do
    from = running["version"]
    to = target["version"]

    apps =
      for app <- target["code"], into: %{} do
        {String.to_atom(app), {running["applications"][app], target["applications"][app]}}
      end

    for {app, {old, new}} <- apps do
      staged(Path.join([root, "lib", "#{app}-#{new}"]), fn dir ->
        File.cp_r!(Path.join([bundle, "lib", "#{app}-#{new}"]), dir)
        packages = Path.join(dir, @platform_packages)
        File.rm_rf!(packages)
        kept = Path.join([root, "lib", "#{app}-#{old}", @platform_packages])
        if File.dir?(kept), do: File.cp_r!(kept, packages)
      end)
    end

    staged(Path.join([root, "releases", to]), fn dir ->
      File.cp_r!(Path.join([root, "releases", from]), dir)
      File.rm_rf!(Path.join(dir, "consolidated"))
      consolidated = Path.join([bundle, "releases", to, "consolidated"])
      if File.dir?(consolidated), do: File.cp_r!(consolidated, Path.join(dir, "consolidated"))

      for name <- ~w(start start_clean), File.exists?(Path.join(dir, name <> ".boot")) do
        specs = Map.new(apps, fn {app, {_old, new}} -> {app, spec(root, app, new)} end)

        script =
          Path.join(dir, name <> ".boot")
          |> File.read!()
          |> :erlang.binary_to_term()
          |> boot_script(from, to, apps, specs)

        File.write!(Path.join(dir, name <> ".boot"), :erlang.term_to_binary(script))
        write_term(Path.join(dir, name <> ".script"), script)
      end

      for rel <- Path.wildcard(Path.join(dir, "*.rel")) do
        {:ok, [{:release, {name, _}, erts, list}]} = :file.consult(rel)

        list =
          for entry <- list do
            case apps[elem(entry, 0)] do
              {_old, new} -> put_elem(entry, 1, String.to_charlist(new))
              nil -> entry
            end
          end

        write_term(rel, {:release, {name, String.to_charlist(to)}, erts, list})
      end

      # It names the runtime configuration in its own release directory.
      config = Path.join(dir, "sys.config")

      if File.exists?(config),
        do: File.write!(config, move(File.read!(config), from, to, apps))

      manifest =
        running
        |> Map.merge(Map.take(target, ~w(version code dependencies packages config)))
        |> Map.update!(
          "applications",
          &Map.merge(&1, Map.take(target["applications"], target["code"]))
        )

      File.write!(Path.join(dir, "upgrade.json"), JSON.encode!(manifest))
    end)

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  The boot script of release `to`: that of `from` with its own applications (`apps`,
  `%{app => {old version, new version}}`) loaded from their new directories with the
  modules and specification they have there (`specs`).
  """
  def boot_script({:script, {name, _from}, instructions}, from, to, apps, specs) do
    {instructions, _} =
      Enum.map_reduce(instructions, nil, fn
        {:path, paths}, _ ->
          paths = Enum.map(paths, &(&1 |> to_string() |> move(from, to, apps) |> to_charlist()))
          {{:path, paths}, loads(paths, apps)}

        # The modules of the application the path before it names.
        {:primLoad, _modules}, app when app != nil ->
          {:application, ^app, properties} = specs[app]
          {{:primLoad, Keyword.fetch!(properties, :modules)}, nil}

        {:apply, {:application, :load, [{:application, app, _}]}} = instruction, _ ->
          case specs[app] do
            nil -> {instruction, nil}
            spec -> {{:apply, {:application, :load, [spec]}}, nil}
          end

        instruction, _ ->
          {instruction, nil}
      end)

    {:script, {name, String.to_charlist(to)}, instructions}
  end

  # The application a path instruction is for, when it is one of ours: its
  # directory alone, after the consolidated protocols.
  defp loads(paths, apps) do
    case Enum.reject(paths, &String.ends_with?(to_string(&1), "/consolidated")) do
      [path] ->
        Enum.find_value(apps, fn {app, {_old, new}} ->
          if String.ends_with?(to_string(path), "/#{app}-#{new}/ebin"), do: app
        end)

      _ ->
        nil
    end
  end

  defp move(text, from, to, apps) do
    for {app, {old, new}} <- apps,
        reduce: String.replace(text, "/releases/#{from}/", "/releases/#{to}/") do
      text -> String.replace(text, "/#{app}-#{old}/", "/#{app}-#{new}/")
    end
  end

  defp spec(root, app, vsn) do
    path = Path.join([root, "lib", "#{app}-#{vsn}", "ebin", "#{app}.app"])
    {:ok, [spec]} = :file.consult(path)
    spec
  end

  defp write_term(path, term),
    do: File.write!(path, :io_lib.format("%% coding: utf-8~n~tp.~n", [term]))

  # Versioned directories never change once written; a missing one appears whole.
  defp staged(dir, fill) do
    unless File.exists?(dir) do
      partial = dir <> ".partial"
      File.rm_rf!(partial)
      File.mkdir_p!(Path.dirname(partial))
      fill.(partial)
      File.rename!(partial, dir)
    end
  end
end
