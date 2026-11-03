defmodule HalC2.Test.Release do
  @moduledoc """
  Real OTP releases on disk, for the release handler to upgrade the test VM between.

  A release is kernel, stdlib and SASL as the VM runs them, and the MC's code as one
  application, `hal_c2_bundle`, holding the modules a scenario changes, at the code
  the VM runs (the running release) or the code a bundle brings. It is not
  `hal_c2`: an upgrade moves that application's code path, which must not hide the
  rest of the MC's modules from the VM. A release root links the OTP applications
  in (`lib/kernel-<vsn>`, ...), as a release built with them carries them.
  """

  alias HalC2.Upgrade.Appup

  @compile {:no_warn_undefined, :systools}

  @app :hal_c2_bundle

  @doc "The Erlang runtime the VM runs, as a release names it."
  def erts, do: to_string(:erlang.system_info(:version))

  @doc """
  Writes release `vsn` under `dir`: `lib/hal_c2_bundle-<vsn>` with the beams already
  there and `modules` (`{module, beam}`) over them, and `releases/<vsn>` with its
  `hal_c2.rel` (as a mix release names it), `start.boot`, `sys` as `sys.config` and `manifest` as `upgrade.json`.
  """
  def write(dir, vsn, modules, manifest, sys \\ []) do
    ebin = ebin(dir, vsn)
    File.mkdir_p!(ebin)
    for {mod, beam} <- modules, do: File.write!(Path.join(ebin, "#{mod}.beam"), beam)

    mods =
      for file <- Path.wildcard(Path.join(ebin, "*.beam")), do: :"#{Path.basename(file, ".beam")}"

    Appup.write_term!(
      Path.join(ebin, "#{@app}.app"),
      {:application, @app,
       [
         description: ~c"the MC's code in upgrade tests",
         vsn: String.to_charlist(vsn),
         modules: mods,
         registered: [],
         applications: [:kernel, :stdlib]
       ]}
    )

    rel = Path.join([dir, "releases", vsn])
    File.mkdir_p!(rel)
    otp = for {app, app_vsn, _dir} <- otp(), do: {app, String.to_charlist(app_vsn)}

    Appup.write_term!(
      Path.join(rel, "hal_c2.rel"),
      {:release, {~c"hal_c2", String.to_charlist(vsn)}, {:erts, String.to_charlist(erts())},
       otp ++ [{@app, String.to_charlist(vsn)}]}
    )

    Appup.write_term!(Path.join(rel, "sys.config"), sys)
    File.write!(Path.join(rel, "upgrade.json"), JSON.encode!(manifest))

    path = [String.to_charlist(ebin) | for({_, _, lib} <- otp(), do: ~c"#{lib}/ebin")]

    case :systools.make_script(String.to_charlist(Path.join(rel, "hal_c2")), [
           :silent,
           :no_warn_sasl,
           :no_module_tests,
           path: path,
           outdir: String.to_charlist(rel)
         ]) do
      {:ok, _, _} -> :ok
      :ok -> :ok
      error -> raise "no boot script for #{vsn}: #{inspect(error)}"
    end

    # The release handler boots `start.boot`, which a mix release copies from its own.
    File.rename!(Path.join(rel, "hal_c2.boot"), Path.join(rel, "start.boot"))
    File.rename!(Path.join(rel, "hal_c2.script"), Path.join(rel, "start.script"))
  end

  @doc "Makes `root` a release root running `vsn` (`write/4`, with OTP linked in)."
  def root(root, vsn, manifest) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "bin"))

    for {app, app_vsn, lib} <- otp(),
        link = Path.join([root, "lib", "#{app}-#{app_vsn}"]),
        not File.exists?(link),
        do: File.ln_s!(lib, link)

    write(root, vsn, [], manifest)
    File.write!(Path.join([root, "releases", "start_erl.data"]), "#{erts()} #{vsn}\n")
    root
  end

  @doc "The beams of the MC's code in release `vsn` under `dir`, as `{module, beam}`."
  def modules(dir, vsn) do
    for file <- Path.wildcard(Path.join(ebin(dir, vsn), "*.beam")),
        do: {:"#{Path.basename(file, ".beam")}", File.read!(file)}
  end

  defp ebin(dir, vsn), do: Path.join([dir, "lib", "#{@app}-#{vsn}", "ebin"])

  # The OTP applications of a release, as `{app, vsn, directory}` of the running OTP.
  defp otp do
    :ok = HalC2.Upgrade.Release.load_sasl(to_string(:code.root_dir()))

    for app <- [:kernel, :stdlib, :sasl] do
      vsn = to_string(Application.spec(app, :vsn))
      {app, vsn, Path.join([to_string(:code.root_dir()), "lib", "#{app}-#{vsn}"])}
    end
  end
end
