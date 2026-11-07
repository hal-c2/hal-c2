defmodule HalC2.ProviderSecrets do
  @moduledoc """
  Sensitive provider environment variables (`providerInstances[id].environment` entries
  with `"sensitive": true`) live in the secret store, not the settings document. An
  earlier install kept them under the same `provider-env-<id>-<name>` secret names, so
  a home it wrote reads the same.

  On every write `seal/2` moves a sensitive value out and leaves
  `%{"value" => "", "valueRedacted" => true}` in its place; a client that sends a
  redacted entry back means "keep what is stored". A redacted entry whose name has
  nothing stored (a renamed variable) is saved empty and unredacted, never as a secret
  that is not there. A variable made plain, emptied or dropped forgets its secret.
  `value/2` reads one back for the agent's environment.

  An external OpenCode server's `serverPassword` (in `providers.opencode` or an
  instance's `config`) is sealed the same way by `seal_server_passwords/2`, leaving
  `"••••••"` in its place; sending the marker back keeps it, and
  `server_password/2` reads it back.
  """

  @marker "••••••"

  @doc """
  The settings to store for `next`, given the stored `current`, and whether a secret
  changed (which the stored document alone cannot show).
  """
  def seal(next, current) do
    instances = next["providerInstances"]

    {sealed, {changed, kept}} =
      if is_map(instances) do
        Enum.map_reduce(instances, {false, MapSet.new()}, fn {id, instance}, acc ->
          seal_instance(id, instance, current, acc)
        end)
      else
        {[], {false, MapSet.new()}}
      end

    # Secrets of variables that are gone, or no longer sensitive.
    changed =
      for {id, %{} = instance} <- current["providerInstances"] || %{},
          %{"name" => name, "sensitive" => true} <- List.wrap(instance["environment"]),
          is_binary(name),
          not MapSet.member?(kept, {id, name}),
          reduce: changed do
        changed -> remove(id, name) or changed
      end

    settings =
      if is_map(instances), do: Map.put(next, "providerInstances", Map.new(sealed)), else: next

    {settings, changed}
  end

  @doc "A sealed variable's value, or \"\"."
  def value(instance, name) do
    case File.read(path(instance, name)) do
      {:ok, value} -> value
      _ -> ""
    end
  end

  @doc "An instance's variables as `{name, value}` pairs, sealed ones read back."
  def environment(instance, entry) do
    for %{"name" => name} = variable <- List.wrap(entry["environment"]), is_binary(name) do
      if variable["sensitive"] == true and variable["valueRedacted"] == true,
        do: {name, value(instance, name)},
        else: {name, variable["value"]}
    end
    |> Enum.filter(fn {_name, value} -> is_binary(value) end)
  end

  @doc """
  Moves plain OpenCode server passwords in `next` into the secret store and forgets
  those `next` clears or drops. Returns the settings to store and whether a password
  changed.
  """
  def seal_server_passwords(next, current) do
    scopes = password_scopes(next)

    {settings, changed} =
      Enum.reduce(scopes, {next, false}, fn {scope, keys}, {settings, changed} ->
        case get_in(settings, keys) do
          @marker ->
            # Nothing stored under this scope: no password to keep.
            if File.exists?(password_path(scope)),
              do: {settings, changed},
              else: {drop_in(settings, keys), changed}

          value when is_binary(value) and value != "" ->
            write_file(password_path(scope), value)
            {put_in(settings, keys, @marker), true}

          _ ->
            {settings, remove_file(password_path(scope)) or changed}
        end
      end)

    kept = MapSet.new(scopes, &elem(&1, 0))

    changed =
      for {scope, _keys} <- password_scopes(current),
          not MapSet.member?(kept, scope),
          reduce: changed,
          do: (changed -> remove_file(password_path(scope)) or changed)

    {settings, changed}
  end

  @doc """
  The password a server setting stands for: the stored one for the marker, the value
  itself otherwise, nil when blank. `scope` is `{:provider, driver}` or
  `{:instance, id}`.
  """
  # The scope is URL-safe base64 in a fixed name under the data directory's secrets.
  # sobelow_skip ["Traversal.FileModule"]
  def server_password(scope, @marker) do
    case File.read(password_path(scope)) do
      {:ok, value} when value != "" -> value
      _ -> nil
    end
  end

  def server_password(_scope, value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def server_password(_scope, _value), do: nil

  # Where a server password can be set: the OpenCode driver's settings and every
  # OpenCode instance's config.
  defp password_scopes(settings) do
    provider =
      if is_map(get_in(settings, ["providers", "opencode"])),
        do: [{{:provider, "opencode"}, ["providers", "opencode", "serverPassword"]}],
        else: []

    instances =
      for {id, %{"driver" => "opencode", "config" => %{}}} <-
            settings["providerInstances"] || %{},
          is_binary(id),
          do: {{:instance, id}, ["providerInstances", id, "config", "serverPassword"]}

    provider ++ instances
  rescue
    _ -> []
  end

  defp drop_in(settings, keys) do
    {parent, [key]} = Enum.split(keys, -1)
    update_in(settings, parent, &Map.delete(&1, key))
  end

  defp seal_instance(id, %{"environment" => environment} = instance, current, {changed, kept})
       when is_list(environment) do
    {environment, acc} =
      Enum.map_reduce(environment, {changed, kept}, fn variable, {changed, kept} ->
        seal_variable(id, variable, previous(current, id), changed, kept)
      end)

    {{id, Map.put(instance, "environment", environment)}, acc}
  end

  defp seal_instance(id, instance, _current, acc), do: {{id, instance}, acc}

  defp seal_variable(
         id,
         %{"name" => name, "sensitive" => true} = variable,
         previous,
         changed,
         kept
       )
       when is_binary(name) do
    kept = MapSet.put(kept, {id, name})
    value = if is_binary(variable["value"]), do: variable["value"], else: ""

    cond do
      # Kept as stored, unless an older write left the value in plain text.
      variable["valueRedacted"] == true ->
        case previous[name] do
          %{"valueRedacted" => true} ->
            {Map.put(variable, "value", ""), {changed, kept}}

          %{"value" => inline} when is_binary(inline) and inline != "" ->
            write(id, name, inline)
            {redacted(variable), {true, kept}}

          # Nothing is stored under this name (a renamed row, say): no secret to keep,
          # so the entry says so rather than claiming one.
          _ ->
            {unset(variable), {remove(id, name) or changed, kept}}
        end

      value != "" ->
        write(id, name, value)
        {redacted(variable), {true, kept}}

      true ->
        {unset(variable), {remove(id, name) or changed, kept}}
    end
  end

  defp seal_variable(id, %{"name" => name} = variable, _previous, changed, kept)
       when is_binary(name) do
    {Map.delete(variable, "valueRedacted"), {remove(id, name) or changed, kept}}
  end

  defp seal_variable(_id, variable, _previous, changed, kept), do: {variable, {changed, kept}}

  defp unset(variable), do: variable |> Map.put("value", "") |> Map.delete("valueRedacted")

  defp redacted(variable), do: variable |> Map.put("value", "") |> Map.put("valueRedacted", true)

  # The stored instance's variables by name, the last of a name winning.
  defp previous(current, id) do
    for %{"name" => name} = variable <-
          List.wrap(get_in(current, ["providerInstances", id, "environment"])),
        into: %{},
        do: {name, variable}
  rescue
    _ -> %{}
  end

  defp write(id, name, value), do: write_file(path(id, name), value)

  defp write_file(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    tmp = path <> ".tmp"
    File.write!(tmp, value)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  defp remove(id, name), do: remove_file(path(id, name))

  defp remove_file(path), do: File.rm(path) == :ok

  defp password_path(scope) do
    name =
      case scope do
        {:provider, driver} -> "provider-#{driver}"
        {:instance, id} -> "instance-#{id}"
      end

    Path.join([
      HalC2.Paths.data_dir(),
      "secrets",
      "server-password-#{Base.url_encode64(name, padding: false)}.bin"
    ])
  end

  defp path(id, name) do
    encode = &Base.url_encode64(&1, padding: false)

    Path.join([
      HalC2.Paths.data_dir(),
      "secrets",
      "provider-env-#{encode.(id)}-#{encode.(name)}.bin"
    ])
  end
end
