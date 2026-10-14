defmodule HalC2.Muse do
  @moduledoc """
  Muse Code over the Muse Session Protocol (MSP): `muse serve` speaks JSON-RPC 2.0
  lines on stdio (`HalC2.JsonRpc`'s `:v2` dialect). Turns run in
  `HalC2.Muse.ThreadRuntime`.

  This module holds what the provider entry and the runtime share: the command
  line and environment of a host, its `initialize` handshake, command ids, the
  model catalog (`model/list`) with each model's reasoning efforts, and the
  approval mode for a thread's access mode.

  A host is either read-only (shell and writes off, no session log), for reading
  the catalog, or a full host that trusts the workspace. Sandboxing is fixed when
  the host starts, so a full-access thread runs a host without Muse's sandbox.
  """

  alias HalC2.JsonRpc.Connection

  # The `initialize` result's schema version this client speaks.
  @schema_version 1

  @effort_labels %{
    "none" => "None",
    "minimal" => "Minimal",
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "xhigh" => "Extra High",
    "max" => "Max",
    "ultra" => "Ultra"
  }
  @efforts ~w(none minimal low medium high xhigh max ultra)
  # When Muse does not report a model's efforts (custom models, `"unknown"`).
  @fallback_efforts ~w(low medium high xhigh max)
  # Muse's own CLI default.
  @fallback_effort "high"

  @doc """
  The command line and environment of a Muse host for `instance`. Options:
  `:read_only` (no shell, no writes, no session log) and `:runtime_mode` (a
  full-access thread's host runs without Muse's sandbox).

  The host keeps the user's `muse login` but never an inherited `META_API_KEY`,
  which would override it, and never updates itself under the MC.
  """
  def launch(instance, opts \\ []) do
    binary = HalC2.Acp.binary_path(instance) || "muse"

    serve =
      if opts[:read_only] do
        ["serve", "--disable-shell", "--disable-write", "--no-session-log"]
      else
        ["serve", "--trust-workspace"] ++
          if(opts[:runtime_mode] == "full-access", do: ["--disable-sandbox"], else: [])
      end

    # Exile adds to the MC's environment; `env -u` takes an inherited key away.
    unset =
      for {key, _} <- System.get_env(), String.upcase(key) == "META_API_KEY", do: key

    argv =
      if unset == [],
        do: [binary | serve],
        else: ["env"] ++ Enum.flat_map(unset, &["-u", &1]) ++ [binary | serve]

    env =
      Enum.reject(HalC2.Acp.instance_env(instance), fn {key, _} ->
        String.upcase(key) == "META_API_KEY"
      end) ++ [{"MUSE_NO_AUTO_UPDATE", "1"}]

    {:ok, argv, env}
  end

  @doc """
  Starts a host for `instance` in `cwd` and completes the handshake. Returns
  `{:ok, conn, granted}` (the capabilities Muse granted) or `{:error, reason}`.
  The caller is the connection's handler. Options as `launch/2`, plus `:log` (a
  thread id for `HalC2.ProviderLog`).
  """
  def connect(instance, cwd, opts \\ []) do
    {:ok, argv, env} = launch(instance, opts)

    with {:ok, conn} <-
           Connection.start_link(
             cmd: argv,
             handler: self(),
             cd: cwd,
             env: env,
             dialect: :v2,
             log: opts[:log]
           ) do
      case handshake(conn, opts[:read_only]) do
        {:ok, %{"schema" => %{"version" => @schema_version}} = init} ->
          Connection.notify(conn, "initialized", nil)
          {:ok, conn, init["grantedCapabilities"] || []}

        {:ok, %{"schema" => %{"version" => version}}} ->
          Connection.stop(conn)
          {:error, "Muse speaks session protocol #{inspect(version)}; HAL-C2 needs 1."}

        {:ok, _other} ->
          Connection.stop(conn)
          {:error, "Muse answered initialize without a schema version."}

        {:error, reason} ->
          Connection.stop(conn)
          {:error, reason}
      end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  # A host that does not answer in time is stopped, not left running under a caller
  # that traps its exit.
  defp handshake(conn, read_only) do
    Connection.call(conn, "initialize", initialize_params(read_only), 15_000)
  catch
    :exit, reason -> {:error, {:initialize, reason}}
  end

  @doc "`initialize`'s params: a read-only host asks for nothing, a full one for session MCP."
  def initialize_params(read_only \\ false) do
    %{
      "clientInfo" => %{
        # Muse wants a machine identifier: `^[a-z0-9_]+$`.
        "name" => "hal_c2",
        "title" => "HAL-C2",
        "version" => to_string(Application.spec(:hal_c2, :vsn) || "0.0.0")
      },
      "capabilities" => %{
        "requestedCapabilities" => if(read_only, do: [], else: ["sessionMcp"])
      }
    }
  end

  @doc "Muse's approval mode for a thread's access mode."
  def approval_mode("full-access"), do: "allowAll"
  def approval_mode(_mode), do: "promptUnmatched"

  @doc "A command id: a UUIDv7, which Muse requires and uses to deduplicate retries."
  def command_id do
    ms = System.system_time(:millisecond)
    <<a::12, b::62, _::6>> = :crypto.strong_rand_bytes(10)
    <<u::128>> = <<ms::48, 7::4, a::12, 2::2, b::62>>
    hex = u |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  @doc """
  The models of Muse's catalog, from a read-only host in `cwd`:
  `{:ok, models} | {:error, reason}`. An empty list means Muse is signed out.
  """
  def discover(instance, cwd) do
    with {:ok, conn, _granted} <- connect(instance, cwd, read_only: true) do
      try do
        case Connection.call(conn, "model/list", %{}, 15_000) do
          {:ok, catalog} -> models(catalog)
          {:error, reason} -> {:error, reason}
        end
      after
        Connection.stop(conn)
      end
    end
  end

  @doc "Provider models from a `model/list` result: Meta's, once each."
  def models(%{"providerId" => "meta", "models" => models}) when is_list(models) do
    models =
      for %{"modelId" => id, "providerId" => "meta"} = model <- models,
          is_binary(id) and id != "" do
        label = String.trim(model["displayLabel"] || "")

        %{
          "slug" => id,
          "name" => if(label == "", do: id, else: label),
          "isCustom" => false,
          "isDefault" => model["isDefault"] == true,
          "capabilities" => capabilities(model)
        }
      end

    {:ok, Enum.uniq_by(models, & &1["slug"])}
  end

  def models(%{"providerId" => _other}), do: {:error, "Muse returned another provider's catalog."}
  def models(_catalog), do: {:error, "Muse returned an unreadable model catalog."}

  @doc """
  A model's reasoning picker (`reasoningEffort`) from its `model/list` row; without
  one (a custom model), or when Muse does not know, the CLI's usual efforts.
  """
  def capabilities(model \\ %{}) do
    {efforts, preferred} =
      case model["variants"] do
        variants when is_list(variants) -> {variants, model["defaultReasoningEffort"]}
        _ -> {@fallback_efforts, @fallback_effort}
      end

    efforts = Enum.filter(efforts, &(&1 in @efforts))
    default = Enum.find(efforts, &(&1 == preferred)) || List.first(efforts)

    descriptions =
      for %{"tier" => tier, "description" => text} <- model["reasoningEffortVariants"] || [],
          is_binary(text) and text != "",
          into: %{},
          do: {tier, text}

    descriptors =
      if default do
        [
          %{
            "id" => "reasoningEffort",
            "label" => "Reasoning",
            "type" => "select",
            "currentValue" => default,
            "options" =>
              for effort <- efforts do
                %{"id" => effort, "label" => @effort_labels[effort]}
                |> then(&if(effort == default, do: Map.put(&1, "isDefault", true), else: &1))
                |> then(
                  &if(descriptions[effort],
                    do: Map.put(&1, "description", descriptions[effort]),
                    else: &1
                  )
                )
              end
          }
        ]
      else
        []
      end

    %{"optionDescriptors" => descriptors}
  end

  @doc "Whether `effort` is a reasoning effort Muse takes."
  def effort?(effort), do: effort in @efforts

  @doc """
  `effort` if the model whose `capabilities` these are offers it, else nil (Muse uses
  the model's default).
  """
  def effort(effort, capabilities) do
    options =
      for %{"id" => "reasoningEffort", "options" => options} <-
            capabilities["optionDescriptors"] || [],
          %{"id" => id} <- options,
          do: id

    if effort in options, do: effort
  end
end
