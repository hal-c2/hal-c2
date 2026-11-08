defmodule HalC2.OpenShell.Config do
  @moduledoc """
  The gateway's `gateway.toml`, and the environment and arguments it runs with.
  The service unit (`HalC2.OpenShell.Service`), the foreground dev run
  (`mix hal_c2.openshell run`) and the install's preflight all start it from here,
  so all three run the same gateway.

  What it fixes, whatever the gateway's defaults or the user's environment say:

    * TLS on, with client certificates required, only from the CA that signed the
      MC's own (not the one that signed the gateway's certificate); no
      unauthenticated users, no operator identities (`OPENSHELL_DISABLE_TLS` and
      `OPENSHELL_ENABLE_OPERATOR_AUTH` are pinned false in its environment).
    * Loopback only.
    * One compute driver, the runtime socket `HalC2.OpenShell.Platform` chose,
      the images `HalC2.OpenShell.Manifest` pins, no caller-supplied driver JSON
      and no host bind mounts.
    * A sandbox PID ceiling of #{512}, below OpenShell's 2048.
    * Telemetry off, and no OTLP or OCSF export.
  """

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Manifest

  @pids_limit 512

  # Every variable that would send the gateway's telemetry, traces or audit
  # events somewhere, or loosen what the configuration fixes.
  @unset ~w(
    OPENSHELL_TELEMETRY_ENDPOINT
    OPENSHELL_OTLP_ENDPOINT OPENSHELL_OTLP_PROTOCOL OPENSHELL_OTLP_CA_FILE
    OPENSHELL_OTLP_CERT_FILE OPENSHELL_OTLP_KEY_FILE OPENSHELL_OTLP_AGENT_ENDPOINT
    OPENSHELL_OTLP_AGENT_PROTOCOL OPENSHELL_OTLP_OCSF_ENDPOINT OPENSHELL_OTLP_OCSF_PROTOCOL
    OPENSHELL_OTLP_OCSF_SCHEMA_VERSION OPENSHELL_OCSF_JSON OPENSHELL_OCSF_LOG_DIR
    OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT
    OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_CERTIFICATE
    OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER
    OPENSHELL_GATEWAY_CONFIG OPENSHELL_DB_URL OPENSHELL_COMPUTE_DRIVER
    OPENSHELL_TLS_CERT OPENSHELL_TLS_KEY OPENSHELL_TLS_CLIENT_CA
    OPENSHELL_OIDC_ISSUER OPENSHELL_OIDC_AUDIENCE OPENSHELL_LOCAL_TLS_DIR
  )

  def pids_limit, do: @pids_limit

  @doc "Variables the gateway must not inherit."
  def unset_environment, do: @unset

  @doc """
  The gateway's environment as `{name, value}`: telemetry and the auth escape
  hatches pinned off, and XDG directories of its own, so it shares nothing with
  an OpenShell the user runs themselves.
  """
  def environment do
    home = Path.join(OpenShell.root(), "home")

    [
      {"OPENSHELL_TELEMETRY_ENABLED", "false"},
      {"OPENSHELL_DISABLE_TLS", "false"},
      {"OPENSHELL_ENABLE_OPERATOR_AUTH", "false"},
      {"XDG_CONFIG_HOME", Path.join(home, "config")},
      {"XDG_DATA_HOME", Path.join(home, "data")},
      {"XDG_STATE_HOME", Path.join(home, "state")},
      {"XDG_CACHE_HOME", Path.join(home, "cache")}
    ]
  end

  @doc "The gateway's arguments, after the binary."
  def args do
    ["--config", OpenShell.config_path(), "--db-url", "sqlite:#{OpenShell.db_path()}?mode=rwc"]
  end

  @doc """
  `gateway.toml` for a gateway on `port` with `driver` ("podman" or "docker") over
  `socket`.
  """
  def render(%{port: port, driver: driver, socket: socket}) when driver in ["podman", "docker"] do
    pki = OpenShell.pki_dir()
    images = Manifest.images()

    """
    # Written by HAL-C2 (HalC2.OpenShell.Config); `hal-c2-service openshell install` rewrites it.
    [openshell]
    version = 2

    [openshell.gateway]
    name = "hal-c2"
    bind_address = #{toml("127.0.0.1:#{port}")}
    compute_driver = #{toml(driver)}
    disable_tls = false
    guest_tls_ca = #{toml(Path.join(pki, "ca.crt"))}

    [openshell.gateway.tls]
    cert_path = #{toml(Path.join([pki, "server", "tls.crt"]))}
    key_path = #{toml(Path.join([pki, "server", "tls.key"]))}
    client_ca_path = #{toml(OpenShell.client_ca_path())}

    [openshell.gateway.gateway_jwt]
    signing_key_path = #{toml(Path.join([pki, "jwt", "signing.pem"]))}
    public_key_path = #{toml(Path.join([pki, "jwt", "public.pem"]))}
    kid_path = #{toml(Path.join([pki, "jwt", "kid"]))}
    gateway_id = "hal-c2"

    [openshell.gateway.auth]
    allow_unauthenticated_users = false

    [openshell.gateway.mtls_auth]
    enabled = true
    operator_enabled = false

    [openshell.drivers.#{driver}]
    socket_path = #{toml(socket)}
    default_image = #{toml(images.default_workload)}
    sandbox_runtime_image = #{toml(images.sandbox_runtime)}
    supervisor_image = #{toml(images.supervisor)}
    image_pull_policy = "if_not_present"
    allow_driver_config = false
    enable_bind_mounts = false
    sandbox_pids_limit = #{@pids_limit}
    """
  end

  # A TOML basic string.
  defp toml(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(~r/[\x00-\x1f\x7f]/, fn <<c>> ->
        "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
      end)

    ~s("#{escaped}")
  end
end
