defmodule HalC2.OpenShell.Proto.Openshell.V1.ExtensionKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ExtensionKind",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :EXTENSION_KIND_UNSPECIFIED, 0
  field :EXTENSION_KIND_COMPUTE_DRIVER, 1
  field :EXTENSION_KIND_CREDENTIAL_DRIVER, 2
  field :EXTENSION_KIND_GATEWAY_INTERCEPTOR, 3
  field :EXTENSION_KIND_SUPERVISOR_MIDDLEWARE, 4
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxPhase do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.SandboxPhase",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SANDBOX_PHASE_UNSPECIFIED, 0
  field :SANDBOX_PHASE_PROVISIONING, 1
  field :SANDBOX_PHASE_READY, 2
  field :SANDBOX_PHASE_ERROR, 3
  field :SANDBOX_PHASE_DELETING, 4
  field :SANDBOX_PHASE_UNKNOWN, 5
  field :SANDBOX_PHASE_STOPPING, 6
  field :SANDBOX_PHASE_STOPPED, 7
  field :SANDBOX_PHASE_STARTING, 8
  field :SANDBOX_PHASE_COMPLETED, 9
  field :SANDBOX_PHASE_SUSPENDING, 11
  field :SANDBOX_PHASE_SUSPENDED, 12
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderMutationKind",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_MUTATION_KIND_UNSPECIFIED, 0
  field :PROVIDER_MUTATION_KIND_ATTACH, 1
  field :PROVIDER_MUTATION_KIND_DETACH, 2
  field :PROVIDER_MUTATION_KIND_UPDATE, 3
  field :PROVIDER_MUTATION_KIND_OBSERVE, 4
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderReadinessState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_READINESS_STATE_UNSPECIFIED, 0
  field :PROVIDER_READINESS_STATE_PERSISTED, 1
  field :PROVIDER_READINESS_STATE_PENDING, 2
  field :PROVIDER_READINESS_STATE_READY, 3
  field :PROVIDER_READINESS_STATE_WITHHELD, 4
  field :PROVIDER_READINESS_STATE_REVOKED, 5
  field :PROVIDER_READINESS_STATE_FAILED, 6
  field :PROVIDER_READINESS_STATE_SUPERSEDED, 7
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderReadinessReason",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_READINESS_REASON_UNSPECIFIED, 0
  field :PROVIDER_READINESS_REASON_WAITING_FOR_SUPERVISOR, 1
  field :PROVIDER_READINESS_REASON_WAITING_FOR_CREDENTIALS, 2
  field :PROVIDER_READINESS_REASON_WAITING_FOR_POLICY, 3
  field :PROVIDER_READINESS_REASON_WAITING_FOR_PROCESS, 4
  field :PROVIDER_READINESS_REASON_UNSUPPORTED_SUPERVISOR, 5
  field :PROVIDER_READINESS_REASON_CREDENTIALS_WITHHELD, 6
  field :PROVIDER_READINESS_REASON_CREDENTIAL_INSTALL_FAILED, 7
  field :PROVIDER_READINESS_REASON_POLICY_ACTIVATION_FAILED, 8
  field :PROVIDER_READINESS_REASON_PROCESS_INSTALL_FAILED, 9
  field :PROVIDER_READINESS_REASON_SUPERVISOR_DISCONNECTED, 10
  field :PROVIDER_READINESS_REASON_SUPERVISOR_LEASE_EXPIRED, 11
  field :PROVIDER_READINESS_REASON_DESIRED_STATE_CHANGED, 12
  field :PROVIDER_READINESS_REASON_CREDENTIAL_EXPIRED, 13
  field :PROVIDER_READINESS_REASON_LOCAL_POLICY, 14
  field :PROVIDER_READINESS_REASON_SNAPSHOT_MISMATCH, 15
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigComponent do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ConfigComponent",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CONFIG_COMPONENT_UNSPECIFIED, 0
  field :CONFIG_COMPONENT_SANDBOX_CONFIG, 1
  field :CONFIG_COMPONENT_PROVIDER_ENVIRONMENT, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigApplyOutcome do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ConfigApplyOutcome",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CONFIG_APPLY_OUTCOME_UNSPECIFIED, 0
  field :CONFIG_APPLY_OUTCOME_APPLIED, 1
  field :CONFIG_APPLY_OUTCOME_IGNORED_DUPLICATE, 2
  field :CONFIG_APPLY_OUTCOME_IGNORED_STALE, 3
  field :CONFIG_APPLY_OUTCOME_RETAINED_LOCAL_OVERRIDE, 4
  field :CONFIG_APPLY_OUTCOME_DEGRADED, 5
  field :CONFIG_APPLY_OUTCOME_FAILED_RETAINED_LAST_KNOWN_GOOD, 6
  field :CONFIG_APPLY_OUTCOME_FAILED_CLOSED, 7
  field :CONFIG_APPLY_OUTCOME_UNSUPPORTED, 8
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdateOperationState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ConfigUpdateOperationState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CONFIG_UPDATE_OPERATION_STATE_UNSPECIFIED, 0
  field :CONFIG_UPDATE_OPERATION_STATE_PENDING, 1
  field :CONFIG_UPDATE_OPERATION_STATE_APPLIED, 2
  field :CONFIG_UPDATE_OPERATION_STATE_INACTIVE, 3
  field :CONFIG_UPDATE_OPERATION_STATE_FAILED, 4
  field :CONFIG_UPDATE_OPERATION_STATE_SUPERSEDED, 5
  field :CONFIG_UPDATE_OPERATION_STATE_CANCELLED, 6
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrantType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderCredentialTokenGrantType",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_CREDENTIAL_TOKEN_GRANT_TYPE_UNSPECIFIED, 0
  field :PROVIDER_CREDENTIAL_TOKEN_GRANT_TYPE_CLIENT_CREDENTIALS, 1
  field :PROVIDER_CREDENTIAL_TOKEN_GRANT_TYPE_TOKEN_EXCHANGE, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStrategy do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderCredentialRefreshStrategy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_UNSPECIFIED, 0
  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_STATIC, 1
  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_EXTERNAL, 2
  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_OAUTH2_REFRESH_TOKEN, 3
  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_OAUTH2_CLIENT_CREDENTIALS, 4
  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_GOOGLE_SERVICE_ACCOUNT_JWT, 5
  field :PROVIDER_CREDENTIAL_REFRESH_STRATEGY_AWS_STS_ASSUME_ROLE, 6
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCategory do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderProfileCategory",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_PROFILE_CATEGORY_UNSPECIFIED, 0
  field :PROVIDER_PROFILE_CATEGORY_OTHER, 1
  field :PROVIDER_PROFILE_CATEGORY_INFERENCE, 2
  field :PROVIDER_PROFILE_CATEGORY_AGENT, 3
  field :PROVIDER_PROFILE_CATEGORY_SOURCE_CONTROL, 4
  field :PROVIDER_PROFILE_CATEGORY_MESSAGING, 5
  field :PROVIDER_PROFILE_CATEGORY_DATA, 6
  field :PROVIDER_PROFILE_CATEGORY_KNOWLEDGE, 7
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentValueClassification do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderEnvironmentValueClassification",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_ENVIRONMENT_VALUE_CLASSIFICATION_UNSPECIFIED, 0
  field :PROVIDER_ENVIRONMENT_VALUE_CLASSIFICATION_NON_SECRET, 1
  field :PROVIDER_ENVIRONMENT_VALUE_CLASSIFICATION_STATIC_CREDENTIAL, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigurationAdmissionState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ConfigurationAdmissionState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CONFIGURATION_ADMISSION_STATE_UNSPECIFIED, 0
  field :CONFIGURATION_ADMISSION_STATE_PENDING, 1
  field :CONFIGURATION_ADMISSION_STATE_ACCEPTED, 2
  field :CONFIGURATION_ADMISSION_STATE_REJECTED, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PolicyStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.PolicyStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :POLICY_STATUS_UNSPECIFIED, 0
  field :POLICY_STATUS_PENDING, 1
  field :POLICY_STATUS_LOADED, 2
  field :POLICY_STATUS_FAILED, 3
  field :POLICY_STATUS_SUPERSEDED, 4
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ServiceStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ServiceStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SERVICE_STATUS_UNSPECIFIED, 0
  field :SERVICE_STATUS_HEALTHY, 1
  field :SERVICE_STATUS_DEGRADED, 2
  field :SERVICE_STATUS_UNHEALTHY, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.WorkspaceRole do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.WorkspaceRole",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :WORKSPACE_ROLE_UNSPECIFIED, 0
  field :WORKSPACE_ROLE_USER, 1
  field :WORKSPACE_ROLE_ADMIN, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshRecoveryAction do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ProviderCredentialRefreshRecoveryAction",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :PROVIDER_CREDENTIAL_REFRESH_RECOVERY_ACTION_UNSPECIFIED, 0
  field :PROVIDER_CREDENTIAL_REFRESH_RECOVERY_ACTION_RETRY, 1
  field :PROVIDER_CREDENTIAL_REFRESH_RECOVERY_ACTION_REAUTHORIZE, 2
  field :PROVIDER_CREDENTIAL_REFRESH_RECOVERY_ACTION_FIX_CONFIGURATION, 3
  field :PROVIDER_CREDENTIAL_REFRESH_RECOVERY_ACTION_INVESTIGATE, 4
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxRestartPolicy do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.SandboxRestartPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SANDBOX_RESTART_POLICY_UNSPECIFIED, 0
  field :SANDBOX_RESTART_POLICY_NEVER, 1
  field :SANDBOX_RESTART_POLICY_ON_FAILURE, 2
  field :SANDBOX_RESTART_POLICY_ALWAYS, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.DeletionOutcome",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :DELETION_OUTCOME_UNSPECIFIED, 0
  field :DELETION_OUTCOME_COMPLETED, 1
  field :DELETION_OUTCOME_ACCEPTED, 2
  field :DELETION_OUTCOME_ALREADY_ABSENT, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EndpointResult do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.EndpointResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :ENDPOINT_RESULT_UNSPECIFIED, 0
  field :ENDPOINT_RESULT_NO_OBSERVED_EXCHANGE, 1
  field :ENDPOINT_RESULT_HTTP_RESPONSE_RECEIVED, 2
  field :ENDPOINT_RESULT_POLICY_DENIED, 3
  field :ENDPOINT_RESULT_CREDENTIAL_UNAVAILABLE, 4
  field :ENDPOINT_RESULT_TLS_FAILED, 5
  field :ENDPOINT_RESULT_TRANSPORT_FAILED, 6
  field :ENDPOINT_RESULT_UPSTREAM_REJECTED, 7
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ServiceAuthorizationMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.ServiceAuthorizationMode",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SERVICE_AUTHORIZATION_MODE_UNSPECIFIED, 0
  field :SERVICE_AUTHORIZATION_MODE_STRIP, 1
  field :SERVICE_AUTHORIZATION_MODE_BEARER_PASSTHROUGH, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EndpointFailureDomain do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.v1.EndpointFailureDomain",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :ENDPOINT_FAILURE_DOMAIN_UNSPECIFIED, 0
  field :ENDPOINT_FAILURE_DOMAIN_TOKEN_GRANT, 1
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.IssueSandboxTokenRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.IssueSandboxTokenRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.IssueSandboxTokenResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.IssueSandboxTokenResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :token, 1, type: :string, deprecated: false
  field :expiration_time, 102, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RefreshSandboxTokenRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RefreshSandboxTokenRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :extension_service_names, 1,
    repeated: true,
    type: :string,
    json_name: "extensionServiceNames"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RefreshSandboxTokenResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RefreshSandboxTokenResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :token, 1, type: :string, deprecated: false
  field :expiration_time, 102, type: Google.Protobuf.Timestamp, json_name: "expirationTime"

  field :extension_credentials, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ExtensionServiceCredential,
    json_name: "extensionCredentials"

  field :sandbox_token, 4, type: :string, json_name: "sandboxToken", deprecated: false

  field :sandbox_expiration_time, 105,
    type: Google.Protobuf.Timestamp,
    json_name: "sandboxExpirationTime"

  field :session_id, 6, type: :string, json_name: "sessionId"
  field :credential_epoch, 7, type: :uint64, json_name: "credentialEpoch"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.HealthRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.HealthRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.HealthResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.HealthResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :status, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ServiceStatus, enum: true
  field :version, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetCurrentUserRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetCurrentUserRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetCurrentUserResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetCurrentUserResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :subject, 1, type: :string
  field :display_name, 2, type: :string, json_name: "displayName"
  field :roles, 3, repeated: true, type: :string
  field :scopes, 4, repeated: true, type: :string
  field :identity_provider, 5, type: :string, json_name: "identityProvider"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetGatewayInfoRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetGatewayInfoRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetGatewayInfoResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetGatewayInfoResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :status, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ServiceStatus, enum: true
  field :gateway_version, 2, type: :string, json_name: "gatewayVersion"

  field :compute_drivers, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ComputeDriverInfo,
    json_name: "computeDrivers"

  field :extensions, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.NegotiatedExtensionInfo
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.NegotiatedExtensionInfo do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.NegotiatedExtensionInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :kind, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ExtensionKind, enum: true
  field :configured_name, 2, type: :string, json_name: "configuredName"
  field :implementation_name, 3, type: :string, json_name: "implementationName"
  field :implementation_version, 4, type: :string, json_name: "implementationVersion"
  field :protocol_major, 5, type: :uint32, json_name: "protocolMajor"
  field :protocol_minor, 6, type: :uint32, json_name: "protocolMinor"

  field :supported_capabilities, 7,
    repeated: true,
    type: :string,
    json_name: "supportedCapabilities"

  field :required_capabilities, 8,
    repeated: true,
    type: :string,
    json_name: "requiredCapabilities"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ComputeDriverInfo do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ComputeDriverInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :capabilities, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ComputeDriverCapabilities
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ComputeDriverCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ComputeDriverCapabilities",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :driver_name, 1, type: :string, json_name: "driverName"
  field :driver_version, 2, type: :string, json_name: "driverVersion"

  field :resource_capabilities, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.ResourceCapabilities,
    json_name: "resourceCapabilities"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ResourceCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ResourceCapabilities",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :cpu, 1, type: HalC2.OpenShell.Proto.Openshell.V1.CpuResourceCapabilities
  field :memory, 2, type: HalC2.OpenShell.Proto.Openshell.V1.MemoryResourceCapabilities
  field :gpu, 3, type: HalC2.OpenShell.Proto.Openshell.V1.GpuResourceCapabilities
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CpuResourceCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CpuResourceCapabilities",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :limit_supported, 1, type: :bool, json_name: "limitSupported"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.MemoryResourceCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.MemoryResourceCapabilities",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :limit_supported, 1, type: :bool, json_name: "limitSupported"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GpuResourceCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GpuResourceCapabilities",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :default_selection_supported, 1, type: :bool, json_name: "defaultSelectionSupported"
  field :count_selection_supported, 2, type: :bool, json_name: "countSelectionSupported"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.Sandbox do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.Sandbox",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :spec, 2, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxSpec
  field :status, 3, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxStatus
  field :host_key_fingerprint, 6, type: :string, json_name: "hostKeyFingerprint"

  field :created_from_workload_template, 20,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplateProvenance,
    json_name: "createdFromWorkloadTemplate"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxSpec.EnvironmentEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxSpec.EnvironmentEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxSpec do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxSpec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :log_level, 1, type: :string, json_name: "logLevel"

  field :environment, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxSpec.EnvironmentEntry,
    map: true

  field :template, 6, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate
  field :policy, 7, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy
  field :providers, 8, repeated: true, type: :string

  field :resource_requirements, 9,
    type: HalC2.OpenShell.Proto.Openshell.V1.ResourceRequirements,
    json_name: "resourceRequirements"

  field :command, 12, repeated: true, type: :string
  field :tty, 13, type: :bool
  field :provider_attachment_epoch, 14, type: :string, json_name: "providerAttachmentEpoch"

  field :restart_policy, 15,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxRestartPolicy,
    json_name: "restartPolicy",
    enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ResourceRequirements do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ResourceRequirements",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :gpu, 1, type: HalC2.OpenShell.Proto.Openshell.V1.GpuResourceRequirements
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GpuResourceRequirements do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GpuResourceRequirements",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :count, 1, proto3_optional: true, type: :uint32
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxTemplate.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxTemplate.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate.EnvironmentEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxTemplate.EnvironmentEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxTemplate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :image, 1, type: :string
  field :runtime_class_name, 2, type: :string, json_name: "runtimeClassName"
  field :agent_socket, 3, type: :string, json_name: "agentSocket"

  field :labels, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate.LabelsEntry,
    map: true

  field :annotations, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate.AnnotationsEntry,
    map: true

  field :environment, 6,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplate.EnvironmentEntry,
    map: true

  field :resources, 7, type: Google.Protobuf.Struct
  field :user_namespaces, 10, proto3_optional: true, type: :bool, json_name: "userNamespaces"
  field :driver_config, 11, type: Google.Protobuf.Struct, json_name: "driverConfig"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplate do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxWorkloadTemplate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :spec, 2, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplateSpec
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplateSpec do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxWorkloadTemplateSpec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workload, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadConfig
  field :driver_config, 2, type: Google.Protobuf.Struct, json_name: "driverConfig"

  field :desired_service_level, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxServiceLevel,
    json_name: "desiredServiceLevel"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadConfig.EnvironmentEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxWorkloadConfig.EnvironmentEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadConfig do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxWorkloadConfig",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :image, 1, type: :string

  field :environment, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadConfig.EnvironmentEntry,
    map: true

  field :resources, 3, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxResources
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxResources do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxResources",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :cpu, 1, type: :string
  field :memory, 2, type: :string
  field :gpu, 3, type: HalC2.OpenShell.Proto.Openshell.V1.GpuResourceRequirements
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxServiceLevel do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxServiceLevel",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :startup, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxStartup
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxStartup do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxStartup",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :ready_within, 1, type: Google.Protobuf.Duration, json_name: "readyWithin"
  field :max_burst, 2, type: :uint32, json_name: "maxBurst"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplateProvenance do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxWorkloadTemplateProvenance",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :resource_version, 2, type: :string, json_name: "resourceVersion"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxStatus do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :agent_pod, 2, type: :string, json_name: "agentPod"
  field :agent_fd, 3, type: :string, json_name: "agentFd"
  field :sandbox_fd, 4, type: :string, json_name: "sandboxFd"
  field :conditions, 5, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxCondition
  field :phase, 6, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxPhase, enum: true
  field :current_policy_version, 7, type: :uint32, json_name: "currentPolicyVersion"
  field :main_process_instance_id, 8, type: :string, json_name: "mainProcessInstanceId"
  field :exit_code, 9, proto3_optional: true, type: :int32, json_name: "exitCode"

  field :endpoint_statuses, 10,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.EndpointStatus,
    json_name: "endpointStatuses"

  field :configuration_admission, 11,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxConfigurationAdmission,
    json_name: "configurationAdmission"

  field :configuration_activated, 12,
    proto3_optional: true,
    type: :bool,
    json_name: "configurationActivated"

  field :provisioning, 13, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxProvisioning
  field :restart_count, 14, type: :uint32, json_name: "restartCount"
  field :next_restart_time, 15, type: Google.Protobuf.Timestamp, json_name: "nextRestartTime"

  field :main_process_started_time, 16,
    type: Google.Protobuf.Timestamp,
    json_name: "mainProcessStartedTime"

  field :last_token_grant_failure, 17,
    type: HalC2.OpenShell.Proto.Openshell.V1.TokenGrantFailureObservation,
    json_name: "lastTokenGrantFailure"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxCondition do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxCondition",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :type, 1, type: :string
  field :status, 2, type: :string
  field :reason, 3, type: :string
  field :message, 4, type: :string
  field :transition_time, 105, type: Google.Protobuf.Timestamp, json_name: "transitionTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PlatformEvent.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PlatformEvent.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PlatformEvent do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PlatformEvent",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :event_time, 101, type: Google.Protobuf.Timestamp, json_name: "eventTime"
  field :source, 2, type: :string
  field :type, 3, type: :string
  field :reason, 4, type: :string
  field :message, 5, type: :string

  field :metadata, 6,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.PlatformEvent.MetadataEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxRequest.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateSandboxRequest.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxRequest.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateSandboxRequest.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 7,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :spec, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxSpec
  field :name, 2, type: :string

  field :labels, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxRequest.LabelsEntry,
    map: true

  field :annotations, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxRequest.AnnotationsEntry,
    map: true

  field :await_main_process_attachment, 5, type: :bool, json_name: "awaitMainProcessAttachment"
  field :workload_template, 6, type: :string, json_name: "workloadTemplate"
  field :request_id, 8, type: :string, json_name: "requestId"

  field :service_exposures, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxServiceExposure,
    json_name: "serviceExposures"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 1,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 2, type: :string
  field :image, 3, proto3_optional: true, type: :string
  field :command, 6, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxCommandUpdate
  field :environment, 7, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxMapUpdate
  field :labels, 8, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxMapUpdate
  field :annotations, 9, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxMapUpdate
  field :expected_resource_version, 4, type: :uint64, json_name: "expectedResourceVersion"
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxCommandUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxCommandUpdate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :argv, 1, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxMapUpdate.ValuesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxMapUpdate.ValuesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxMapUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxMapUpdate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :values, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxMapUpdate.ValuesEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxTemplateRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateSandboxTemplateRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :template, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplate
  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxTemplateRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxTemplateRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxTemplatesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxTemplatesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 1, type: :int32, json_name: "pageSize"
  field :page_token, 2, type: :string, json_name: "pageToken"
  field :label_selector, 3, type: :string, json_name: "labelSelector"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxTemplateRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteSandboxTemplateRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
  field :allow_missing, 3, type: :bool, json_name: "allowMissing"
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplateResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxTemplateResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :template, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplate
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxTemplatesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxTemplatesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :templates, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxWorkloadTemplate

  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxTemplateResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteSandboxTemplateResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.BeginRootfsTarStagingRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.BeginRootfsTarStagingRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :file_name, 1, type: :string, json_name: "fileName"
  field :size_bytes, 2, type: :uint64, json_name: "sizeBytes"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.BeginRootfsTarStagingResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.BeginRootfsTarStagingResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :staging_token, 1, type: :string, json_name: "stagingToken"
  field :upload_path, 2, type: :string, json_name: "uploadPath"
  field :max_bytes, 3, type: :uint64, json_name: "maxBytes"
  field :expiration_time, 104, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 1, type: :int32, json_name: "pageSize"
  field :page_token, 2, type: :string, json_name: "pageToken"
  field :label_selector, 3, type: :string, json_name: "labelSelector"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxProvidersRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxProvidersRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :page_size, 3, type: :int32, json_name: "pageSize"
  field :page_token, 4, type: :string, json_name: "pageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AttachSandboxProviderRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AttachSandboxProviderRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :provider, 2, type: :string
  field :expected_resource_version, 3, type: :uint64, json_name: "expectedResourceVersion"
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DetachSandboxProviderRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DetachSandboxProviderRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :provider, 2, type: :string
  field :expected_resource_version, 3, type: :uint64, json_name: "expectedResourceVersion"
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
  field :allow_missing, 3, type: :bool, json_name: "allowMissing"
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.StopSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.StopSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.StartSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.StartSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SuspendSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SuspendSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ResumeSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ResumeSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
  field :restart_if_restore_fails, 3, type: :bool, json_name: "restartIfRestoreFails"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse.ServiceUrlsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxResponse.ServiceUrlsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox, 1, type: HalC2.OpenShell.Proto.Openshell.V1.Sandbox

  field :service_urls, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse.ServiceUrlsEntry,
    json_name: "serviceUrls",
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandboxes, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.Sandbox
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxProvidersResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxProvidersResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :providers, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AttachSandboxProviderResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AttachSandboxProviderResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox, 1, type: HalC2.OpenShell.Proto.Openshell.V1.Sandbox
  field :attached, 2, type: :bool
  field :receipt, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationReceipt
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DetachSandboxProviderResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DetachSandboxProviderResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox, 1, type: HalC2.OpenShell.Proto.Openshell.V1.Sandbox
  field :detached, 2, type: :bool
  field :receipt, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationReceipt
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderDesiredIdentity do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderDesiredIdentity",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :sandbox, 2, type: :string
  field :attachment_epoch, 3, type: :string, json_name: "attachmentEpoch"
  field :provider_id, 4, type: :string, json_name: "providerId"
  field :provider_resource_version, 5, type: :uint64, json_name: "providerResourceVersion"
  field :provider_env_revision, 6, type: :uint64, json_name: "providerEnvRevision"
  field :config_revision, 7, type: :uint64, json_name: "configRevision"
  field :policy_hash, 8, type: :string, json_name: "policyHash"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigSnapshotRevision do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigSnapshotRevision",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :component, 0

  field :sandbox_config, 1,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxConfigRevision,
    json_name: "sandboxConfig",
    oneof: 0

  field :provider_environment, 2, type: :uint64, json_name: "providerEnvironment", oneof: 0

  field :provider_target, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderDesiredIdentity,
    json_name: "providerTarget",
    oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxConfigRevision do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxConfigRevision",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :config_revision, 1, type: :uint64, json_name: "configRevision"
  field :policy_version, 2, type: :uint32, json_name: "policyVersion"

  field :policy_source, 3,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.PolicySource,
    json_name: "policySource",
    enum: true

  field :global_policy_version, 4, type: :uint32, json_name: "globalPolicyVersion"
  field :settings_revision, 5, type: :uint64, json_name: "settingsRevision"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdateOperation do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigUpdateOperation",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :operation_id, 1, type: :string, json_name: "operationId"
  field :sandbox_id, 2, type: :string, json_name: "sandboxId"
  field :component, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigComponent, enum: true

  field :target_revision, 4,
    type: HalC2.OpenShell.Proto.Openshell.V1.ConfigSnapshotRevision,
    json_name: "targetRevision"

  field :state, 5, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdateOperationState, enum: true
  field :outcome, 6, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigApplyOutcome, enum: true
  field :sanitized_error, 7, type: :string, json_name: "sanitizedError"
  field :created_time, 108, type: Google.Protobuf.Timestamp, json_name: "createdTime"
  field :updated_time, 109, type: Google.Protobuf.Timestamp, json_name: "updatedTime"
  field :completed_time, 110, type: Google.Protobuf.Timestamp, json_name: "completedTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationReceipt do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderMutationReceipt",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :receipt_id, 1, type: :string, json_name: "receiptId"
  field :mutation_id, 2, type: :string, json_name: "mutationId"
  field :provider, 3, type: :string
  field :workspace, 4, type: :string
  field :kind, 5, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationKind, enum: true
  field :desired, 6, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderDesiredIdentity
  field :persisted_time, 107, type: Google.Protobuf.Timestamp, json_name: "persistedTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessObservation do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderReadinessObservation",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :sequence, 2, type: :uint64
  field :attachment_epoch, 3, type: :string, json_name: "attachmentEpoch"
  field :provider_env_revision, 4, type: :uint64, json_name: "providerEnvRevision"
  field :config_revision, 5, type: :uint64, json_name: "configRevision"
  field :policy_hash, 6, type: :string, json_name: "policyHash"
  field :credentials_installed, 7, type: :bool, json_name: "credentialsInstalled"
  field :policy_active, 8, type: :bool, json_name: "policyActive"
  field :launch_environment_installed, 9, type: :bool, json_name: "launchEnvironmentInstalled"
  field :process_instance_id, 10, type: :string, json_name: "processInstanceId"
  field :reason, 11, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessReason, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessStatus do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderReadinessStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :receipt, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationReceipt
  field :state, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessState, enum: true
  field :reason, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessReason, enum: true
  field :observed, 4, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessObservation
  field :network_instance_id, 5, type: :string, json_name: "networkInstanceId"
  field :observed_time, 106, type: Google.Protobuf.Timestamp, json_name: "observedTime"
  field :evaluated_time, 107, type: Google.Protobuf.Timestamp, json_name: "evaluatedTime"
  field :operation, 8, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdateOperation
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderStatusRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :provider, 2, type: :string
  field :receipt_id, 3, type: :string, json_name: "receiptId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderStatusResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :status, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessStatus
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportProviderReadinessRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportProviderReadinessRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :observation, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessObservation
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportProviderReadinessResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportProviderReadinessResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :accepted_sequence, 1, type: :uint64, json_name: "acceptedSequence"
  field :report_interval, 102, type: Google.Protobuf.Duration, json_name: "reportInterval"
  field :observation_ttl, 103, type: Google.Protobuf.Duration, json_name: "observationTtl"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteSandboxResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
  field :sandbox_id, 3, type: :string, json_name: "sandboxId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateSshSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateSshSessionRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateSshSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateSshSessionResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :token, 2, type: :string, deprecated: false
  field :gateway_host, 3, type: :string, json_name: "gatewayHost"
  field :gateway_port, 4, type: :uint32, json_name: "gatewayPort"
  field :gateway_scheme, 5, type: :string, json_name: "gatewayScheme"
  field :host_key_fingerprint, 7, type: :string, json_name: "hostKeyFingerprint"
  field :expiration_time, 108, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExposeServiceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExposeServiceRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 5,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 2, type: :string
  field :target_port, 3, type: :uint32, json_name: "targetPort"
  field :domain, 4, type: :bool
  field :sandbox, 1, type: :string
  field :request_id, 6, type: :string, json_name: "requestId"

  field :authorization_mode, 7,
    type: HalC2.OpenShell.Proto.Openshell.V1.ServiceAuthorizationMode,
    json_name: "authorizationMode",
    enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetServiceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetServiceRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 2, type: :string
  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListServicesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListServicesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 2, type: :int32, json_name: "pageSize"
  field :page_token, 3, type: :string, json_name: "pageToken"
  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListServicesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListServicesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :services, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ServiceEndpointResponse

  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteServiceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteServiceRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 2, type: :string
  field :sandbox, 1, type: :string
  field :allow_missing, 4, type: :bool, json_name: "allowMissing"
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteServiceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteServiceResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ServiceEndpoint do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ServiceEndpoint",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :sandbox_id, 2, type: :string, json_name: "sandboxId"
  field :sandbox, 3, type: :string
  field :name, 4, type: :string
  field :target_port, 5, type: :uint32, json_name: "targetPort"
  field :domain, 6, type: :bool

  field :authorization_mode, 7,
    type: HalC2.OpenShell.Proto.Openshell.V1.ServiceAuthorizationMode,
    json_name: "authorizationMode",
    enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ServiceEndpointResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ServiceEndpointResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :endpoint, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ServiceEndpoint
  field :url, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RevokeSshSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RevokeSshSessionRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :token, 1, type: :string, deprecated: false
  field :allow_missing, 2, type: :bool, json_name: "allowMissing"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RevokeSshSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RevokeSshSessionResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxRequest.EnvironmentEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxRequest.EnvironmentEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 12,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :command, 2, repeated: true, type: :string
  field :workdir, 3, type: :string

  field :environment, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxRequest.EnvironmentEntry,
    map: true

  field :execution_timeout, 105, type: Google.Protobuf.Duration, json_name: "executionTimeout"
  field :stdin, 6, type: :bytes
  field :tty, 7, type: :bool
  field :cols, 8, type: :uint32
  field :rows, 9, type: :uint32
  field :no_login_shell, 10, type: :bool, json_name: "noLoginShell"
  field :request_id, 11, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxStdout do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxStdout",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :data, 1, type: :bytes
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxStderr do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxStderr",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :data, 1, type: :bytes
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxExit do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxExit",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :exit_code, 1, type: :int32, json_name: "exitCode"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxEvent do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxEvent",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :stdout, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxStdout, oneof: 0
  field :stderr, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxStderr, oneof: 0
  field :exit, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxExit, oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.TcpForwardInit do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.TcpForwardInit",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :target, 0

  field :sandbox, 1, type: :string
  field :workspace, 3, type: :string
  field :service_id, 4, type: :string, json_name: "serviceId"
  field :ssh, 5, type: HalC2.OpenShell.Proto.Openshell.V1.SshRelayTarget, oneof: 0
  field :tcp, 6, type: HalC2.OpenShell.Proto.Openshell.V1.TcpRelayTarget, oneof: 0
  field :authorization_token, 7, type: :string, json_name: "authorizationToken", deprecated: false
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.TcpForwardFrame do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.TcpForwardFrame",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :init, 1, type: HalC2.OpenShell.Proto.Openshell.V1.TcpForwardInit, oneof: 0
  field :data, 2, type: :bytes, oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxInput do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxInput",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :start, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxRequest, oneof: 0
  field :stdin, 2, type: :bytes, oneof: 0
  field :resize, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxWindowResize, oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxWindowResize do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExecSandboxWindowResize",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :cols, 1, type: :uint32
  field :rows, 2, type: :uint32
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SshSession do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SshSession",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :sandbox_id, 2, type: :string, json_name: "sandboxId"
  field :token, 3, type: :string, deprecated: false
  field :expiration_time, 104, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
  field :revoked, 5, type: :bool
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.WatchSandboxRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.WatchSandboxRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 11,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :follow_status, 2, type: :bool, json_name: "followStatus"
  field :follow_logs, 3, type: :bool, json_name: "followLogs"
  field :follow_events, 4, type: :bool, json_name: "followEvents"
  field :log_tail_lines, 5, type: :uint32, json_name: "logTailLines"
  field :event_tail, 6, type: :uint32, json_name: "eventTail"
  field :stop_on_terminal, 7, type: :bool, json_name: "stopOnTerminal"
  field :since_time, 108, type: Google.Protobuf.Timestamp, json_name: "sinceTime"
  field :log_sources, 9, repeated: true, type: :string, json_name: "logSources"
  field :log_min_level, 10, type: :string, json_name: "logMinLevel"
  field :resume_after_cursor, 12, type: :string, json_name: "resumeAfterCursor"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxStreamEvent do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxStreamEvent",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :sandbox, 1, type: HalC2.OpenShell.Proto.Openshell.V1.Sandbox, oneof: 0
  field :log, 2, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxLogLine, oneof: 0
  field :event, 3, type: HalC2.OpenShell.Proto.Openshell.V1.PlatformEvent, oneof: 0
  field :warning, 4, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxStreamWarning, oneof: 0

  field :draft_policy_update, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.DraftPolicyUpdate,
    json_name: "draftPolicyUpdate",
    oneof: 0

  field :cursor, 6, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxLogLine.FieldsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxLogLine.FieldsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxLogLine do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxLogLine",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :event_time, 102, type: Google.Protobuf.Timestamp, json_name: "eventTime"
  field :level, 3, type: :string
  field :target, 4, type: :string
  field :message, 5, type: :string
  field :source, 6, type: :string

  field :fields, 7,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxLogLine.FieldsEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxStreamWarning do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxStreamWarning",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :message, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateProviderRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateProviderRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :provider, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider
  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderCredentialsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderCredentialsRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 1,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 2, type: :string
  field :credential_keys, 3, repeated: true, type: :string, json_name: "credentialKeys"

  field :minimum_remaining_lifetime, 4,
    type: Google.Protobuf.Duration,
    json_name: "minimumRemainingLifetime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialValue do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialValue",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :value, 1, type: :string, deprecated: false
  field :expiration_time, 2, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderCredentialsResponse.CredentialsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderCredentialsResponse.CredentialsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialValue
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderCredentialsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderCredentialsResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :credentials, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.GetProviderCredentialsResponse.CredentialsEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListProvidersRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListProvidersRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 1, type: :int32, json_name: "pageSize"
  field :page_token, 2, type: :string, json_name: "pageToken"
  field :label_selector, 4, type: :string, json_name: "labelSelector"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderRequest.CredentialExpirationTimesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateProviderRequest.CredentialExpirationTimesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Google.Protobuf.Timestamp
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateProviderRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :provider, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider

  field :credential_expiration_times, 102,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderRequest.CredentialExpirationTimesEntry,
    json_name: "credentialExpirationTimes",
    map: true

  field :clear_credential_expiration_keys, 103,
    repeated: true,
    type: :string,
    json_name: "clearCredentialExpirationKeys"

  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteProviderRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
  field :allow_missing, 4, type: :bool, json_name: "allowMissing"
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :provider, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider

  field :target_receipts, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderMutationReceipt,
    json_name: "targetReceipts"

  field :mutation_id, 3, type: :string, json_name: "mutationId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListProvidersResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListProvidersResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :providers, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListProviderProfilesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListProviderProfilesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 1, type: :int32, json_name: "pageSize"
  field :page_token, 2, type: :string, json_name: "pageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderProfileRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderProfileRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :id, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileImportItem do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfileImportItem",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :profile, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile
  field :source, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileDiagnostic do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfileDiagnostic",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :source, 1, type: :string
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :field, 3, type: :string
  field :message, 4, type: :string
  field :severity, 5, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrantAudienceOverride do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialTokenGrantAudienceOverride",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :host, 1, type: :string
  field :port, 2, type: :uint32
  field :path, 3, type: :string
  field :audience, 4, type: :string
  field :scopes, 5, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrantSubjectToken do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialTokenGrantSubjectToken",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :source, 1, type: :string
  field :credential, 2, type: :string
  field :subject_token_type, 3, type: :string, json_name: "subjectTokenType"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrant do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialTokenGrant",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :token_endpoint, 1, type: :string, json_name: "tokenEndpoint"
  field :audience, 2, type: :string
  field :jwt_svid_audience, 6, type: :string, json_name: "jwtSvidAudience"
  field :scopes, 3, repeated: true, type: :string
  field :cache_ttl, 104, type: Google.Protobuf.Duration, json_name: "cacheTtl"

  field :audience_overrides, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrantAudienceOverride,
    json_name: "audienceOverrides"

  field :client_assertion_type, 7, type: :string, json_name: "clientAssertionType"

  field :grant_type, 8,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrantType,
    json_name: "grantType",
    enum: true

  field :subject_token, 9,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrantSubjectToken,
    json_name: "subjectToken"

  field :requested_token_type, 10, type: :string, json_name: "requestedTokenType"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCredential do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfileCredential",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :description, 2, type: :string
  field :env_vars, 3, repeated: true, type: :string, json_name: "envVars"
  field :required, 4, type: :bool
  field :auth_style, 5, type: :string, json_name: "authStyle"
  field :header_name, 6, type: :string, json_name: "headerName"
  field :query_param, 7, type: :string, json_name: "queryParam"
  field :refresh, 8, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefresh
  field :path_template, 9, type: :string, json_name: "pathTemplate"

  field :token_grant, 10,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialTokenGrant,
    json_name: "tokenGrant"

  field :token_grant_owners, 11, repeated: true, type: :string, json_name: "tokenGrantOwners"
  field :stable_placeholder, 12, type: :bool, json_name: "stablePlaceholder"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshMaterial do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialRefreshMaterial",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :description, 2, type: :string
  field :required, 3, type: :bool
  field :secret, 4, type: :bool
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshOutput do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialRefreshOutput",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :output, 1, type: :string
  field :credential, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefresh do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialRefresh",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :strategy, 1,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStrategy,
    enum: true

  field :token_url, 2, type: :string, json_name: "tokenUrl"
  field :scopes, 3, repeated: true, type: :string
  field :refresh_before, 104, type: Google.Protobuf.Duration, json_name: "refreshBefore"
  field :max_lifetime, 105, type: Google.Protobuf.Duration, json_name: "maxLifetime"

  field :material, 6,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshMaterial

  field :additional_outputs, 7,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshOutput,
    json_name: "additionalOutputs"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStatus do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderCredentialRefreshStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :provider, 1, type: :string
  field :provider_id, 2, type: :string, json_name: "providerId"
  field :credential_key, 3, type: :string, json_name: "credentialKey"

  field :strategy, 4,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStrategy,
    enum: true

  field :status, 5, type: :string
  field :expiration_time, 106, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
  field :next_refresh_time, 107, type: Google.Protobuf.Timestamp, json_name: "nextRefreshTime"
  field :last_refresh_time, 108, type: Google.Protobuf.Timestamp, json_name: "lastRefreshTime"
  field :last_error, 9, type: :string, json_name: "lastError"

  field :recovery_action, 10,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshRecoveryAction,
    json_name: "recoveryAction",
    enum: true

  field :failure_code, 11, type: :string, json_name: "failureCode"
  field :provider_error_subtype, 12, type: :string, json_name: "providerErrorSubtype"
  field :last_error_time, 113, type: Google.Protobuf.Timestamp, json_name: "lastErrorTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileDiscovery do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfileDiscovery",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :credentials, 1, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderRefreshStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderRefreshStatusRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :provider, 1, type: :string
  field :credential_key, 2, type: :string, json_name: "credentialKey"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetProviderRefreshStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetProviderRefreshStatusResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :credentials, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStatus
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigureProviderRefreshRequest.MaterialEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigureProviderRefreshRequest.MaterialEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigureProviderRefreshRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigureProviderRefreshRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 7,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :provider, 1, type: :string
  field :credential_key, 2, type: :string, json_name: "credentialKey"

  field :strategy, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStrategy,
    enum: true

  field :material, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ConfigureProviderRefreshRequest.MaterialEntry,
    map: true,
    deprecated: false

  field :secret_material_keys, 5, repeated: true, type: :string, json_name: "secretMaterialKeys"
  field :expiration_time, 106, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
  field :request_id, 8, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigureProviderRefreshResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigureProviderRefreshResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :status, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStatus
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RotateProviderCredentialRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RotateProviderCredentialRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :provider, 1, type: :string
  field :credential_key, 2, type: :string, json_name: "credentialKey"
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RotateProviderCredentialResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RotateProviderCredentialResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :status, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshStatus
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderRefreshRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteProviderRefreshRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :provider, 1, type: :string
  field :credential_key, 2, type: :string, json_name: "credentialKey"
  field :allow_missing, 5, type: :bool, json_name: "allowMissing"
  field :request_id, 6, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderRefreshResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteProviderRefreshResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfile.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfile",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :id, 1, type: :string
  field :display_name, 2, type: :string, json_name: "displayName"
  field :description, 3, type: :string
  field :category, 4, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCategory, enum: true

  field :credentials, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCredential

  field :endpoints, 6,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEndpoint

  field :binaries, 7,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkBinary

  field :inference_capable, 8, type: :bool, json_name: "inferenceCapable"
  field :discovery, 9, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileDiscovery
  field :resource_version, 10, type: :uint64, json_name: "resourceVersion"

  field :annotations, 11,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile.AnnotationsEntry,
    map: true

  field :source, 12, type: :string
  field :scope, 13, type: :string
  field :files, 14, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileFile
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileFile do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfileFile",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :path, 1, type: :string
  field :content, 2, type: :string
  field :env_var, 3, type: :string, json_name: "envVar"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderProfileResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :profile, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListProviderProfilesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListProviderProfilesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :profiles, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ImportProviderProfilesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ImportProviderProfilesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :profiles, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileImportItem

  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ImportProviderProfilesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ImportProviderProfilesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :diagnostics, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileDiagnostic

  field :profiles, 2, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile
  field :imported, 3, type: :bool
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderProfilesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateProviderProfilesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :profile, 1, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileImportItem
  field :expected_resource_version, 2, type: :uint64, json_name: "expectedResourceVersion"
  field :id, 3, type: :string
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderProfilesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateProviderProfilesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :diagnostics, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileDiagnostic

  field :profile, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile
  field :updated, 3, type: :bool
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.LintProviderProfilesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.LintProviderProfilesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :profiles, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileImportItem
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.LintProviderProfilesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.LintProviderProfilesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :diagnostics, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileDiagnostic

  field :valid, 2, type: :bool
  field :supports_stable_placeholder, 3, type: :bool, json_name: "supportsStablePlaceholder"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteProviderResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderProfileRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteProviderProfileRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :id, 1, type: :string
  field :allow_missing, 3, type: :bool, json_name: "allowMissing"
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderProfileResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteProviderProfileResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderEnvironmentRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"

  field :supports_static_credential_bindings, 2,
    type: :bool,
    json_name: "supportsStaticCredentialBindings"

  field :supports_stable_placeholder_environment_keys, 3,
    type: :bool,
    json_name: "supportsStablePlaceholderEnvironmentKeys"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.StaticCredentialEndpointBinding do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.StaticCredentialEndpointBinding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :host, 1, type: :string
  field :port, 2, type: :uint32
  field :path, 3, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.StaticCredentialBinding do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.StaticCredentialBinding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :endpoints, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.StaticCredentialEndpointBinding

  field :credential_identity, 2, type: :string, json_name: "credentialIdentity"
  field :workload_credential_handle, 3, type: :string, json_name: "workloadCredentialHandle"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.EnvironmentEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderEnvironmentResponse.EnvironmentEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.CredentialExpirationTimesEntry do
  @moduledoc false

  use Protobuf,
    full_name:
      "openshell.v1.GetSandboxProviderEnvironmentResponse.CredentialExpirationTimesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Google.Protobuf.Timestamp
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.DynamicCredentialsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderEnvironmentResponse.DynamicCredentialsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCredential
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.StaticCredentialBindingsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderEnvironmentResponse.StaticCredentialBindingsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.V1.StaticCredentialBinding
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.FilesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderEnvironmentResponse.FilesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxProviderEnvironmentResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :environment, 1,
    repeated: true,
    type:
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.EnvironmentEntry,
    map: true,
    deprecated: false

  field :provider_env_revision, 2, type: :uint64, json_name: "providerEnvRevision"

  field :credential_expiration_times, 103,
    repeated: true,
    type:
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.CredentialExpirationTimesEntry,
    json_name: "credentialExpirationTimes",
    map: true

  field :dynamic_credentials, 4,
    repeated: true,
    type:
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.DynamicCredentialsEntry,
    json_name: "dynamicCredentials",
    map: true

  field :static_credential_bindings, 5,
    repeated: true,
    type:
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.StaticCredentialBindingsEntry,
    json_name: "staticCredentialBindings",
    map: true

  field :non_secret_environment_keys, 6,
    repeated: true,
    type: :string,
    json_name: "nonSecretEnvironmentKeys"

  field :provider_attachment_epoch, 7, type: :string, json_name: "providerAttachmentEpoch"
  field :policy_hash, 8, type: :string, json_name: "policyHash"

  field :readiness_reason, 9,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessReason,
    json_name: "readinessReason",
    enum: true

  field :files, 10,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse.FilesEntry,
    map: true

  field :stable_placeholder_environment_keys, 11,
    repeated: true,
    type: :string,
    json_name: "stablePlaceholderEnvironmentKeys"

  field :supports_stable_placeholder_environment_keys, 12,
    type: :bool,
    json_name: "supportsStablePlaceholderEnvironmentKeys"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentValue do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderEnvironmentValue",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string, deprecated: false

  field :classification, 4,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentValueClassification,
    enum: true

  field :static_credential_binding, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.StaticCredentialBinding,
    json_name: "staticCredentialBinding"

  field :expiration_time, 3, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
  field :stable_placeholder, 6, type: :bool, json_name: "stablePlaceholder"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentSnapshot.DynamicCredentialsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderEnvironmentSnapshot.DynamicCredentialsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCredential
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentSnapshot.FilesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderEnvironmentSnapshot.FilesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentSnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ProviderEnvironmentSnapshot",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :provider_env_revision, 1, type: :uint64, json_name: "providerEnvRevision"

  field :values, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentValue

  field :dynamic_credentials, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentSnapshot.DynamicCredentialsEntry,
    json_name: "dynamicCredentials",
    map: true

  field :provider_attachment_epoch, 4, type: :string, json_name: "providerAttachmentEpoch"
  field :policy_hash, 5, type: :string, json_name: "policyHash"

  field :readiness_reason, 6,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderReadinessReason,
    json_name: "readinessReason",
    enum: true

  field :files, 7,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentSnapshot.FilesEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExchangeProviderSubjectTokenRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExchangeProviderSubjectTokenRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :provider, 2, type: :string
  field :credential_key, 3, type: :string, json_name: "credentialKey"
  field :supervisor_jwt_svid, 4, type: :string, json_name: "supervisorJwtSvid", deprecated: false
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExchangeProviderSubjectTokenResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExchangeProviderSubjectTokenResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :access_token, 1, type: :string, json_name: "accessToken", deprecated: false
  field :expires_after, 102, type: Google.Protobuf.Duration, json_name: "expiresAfter"
  field :token_type, 3, type: :string, json_name: "tokenType"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigRequest.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateConfigRequest.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateConfigRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 10,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :policy, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy
  field :setting_key, 3, type: :string, json_name: "settingKey"

  field :setting_value, 4,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SettingValue,
    json_name: "settingValue"

  field :delete_setting, 5, type: :bool, json_name: "deleteSetting"
  field :global, 6, type: :bool

  field :merge_operations, 7,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.PolicyMergeOperation,
    json_name: "mergeOperations"

  field :expected_resource_version, 8, type: :uint64, json_name: "expectedResourceVersion"

  field :annotations, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigRequest.AnnotationsEntry,
    map: true

  field :sandbox, 1, type: :string
  field :request_id, 11, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PolicyMergeOperation do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PolicyMergeOperation",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :operation, 0

  field :add_rule, 1,
    type: HalC2.OpenShell.Proto.Openshell.V1.AddNetworkRule,
    json_name: "addRule",
    oneof: 0

  field :remove_endpoint, 2,
    type: HalC2.OpenShell.Proto.Openshell.V1.RemoveNetworkEndpoint,
    json_name: "removeEndpoint",
    oneof: 0

  field :remove_rule, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.RemoveNetworkRule,
    json_name: "removeRule",
    oneof: 0

  field :add_deny_rules, 4,
    type: HalC2.OpenShell.Proto.Openshell.V1.AddDenyRules,
    json_name: "addDenyRules",
    oneof: 0

  field :add_allow_rules, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.AddAllowRules,
    json_name: "addAllowRules",
    oneof: 0

  field :remove_binary, 6,
    type: HalC2.OpenShell.Proto.Openshell.V1.RemoveNetworkBinary,
    json_name: "removeBinary",
    oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AddNetworkRule do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AddNetworkRule",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :rule_name, 1, type: :string, json_name: "ruleName"
  field :rule, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RemoveNetworkEndpoint do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RemoveNetworkEndpoint",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :rule_name, 1, type: :string, json_name: "ruleName"
  field :host, 2, type: :string
  field :port, 3, type: :uint32
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RemoveNetworkRule do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RemoveNetworkRule",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :rule_name, 1, type: :string, json_name: "ruleName"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.L7RuleTarget do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.L7RuleTarget",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :rule_name, 1, type: :string, json_name: "ruleName"
  field :host, 2, type: :string
  field :ports, 3, repeated: true, type: :uint32
  field :path, 4, proto3_optional: true, type: :string

  field :binaries, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkBinary

  field :any_binary, 6, type: :bool, json_name: "anyBinary"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AddDenyRules do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AddDenyRules",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :deny_rules, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule,
    json_name: "denyRules"

  field :target, 4, type: HalC2.OpenShell.Proto.Openshell.V1.L7RuleTarget
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AddAllowRules do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AddAllowRules",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :rules, 3, repeated: true, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Rule
  field :target, 4, type: HalC2.OpenShell.Proto.Openshell.V1.L7RuleTarget
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RemoveNetworkBinary do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RemoveNetworkBinary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :rule_name, 1, type: :string, json_name: "ruleName"
  field :binary_path, 2, type: :string, json_name: "binaryPath"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigResponse.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateConfigResponse.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UpdateConfigResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :version, 1, type: :uint32
  field :policy_hash, 2, type: :string, json_name: "policyHash"
  field :settings_revision, 3, type: :uint64, json_name: "settingsRevision"
  field :deleted, 4, type: :bool

  field :annotations, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigResponse.AnnotationsEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxPolicyStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxPolicyStatusRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :version, 2, type: :uint32
  field :global, 3, type: :bool
  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxPolicyStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxPolicyStatusResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :revision, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxPolicyRevision
  field :active_version, 2, type: :uint32, json_name: "activeVersion"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxPoliciesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxPoliciesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 5,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 2, type: :int32, json_name: "pageSize"
  field :page_token, 3, type: :string, json_name: "pageToken"
  field :global, 4, type: :bool
  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListSandboxPoliciesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListSandboxPoliciesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :revisions, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxPolicyRevision

  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportPolicyStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportPolicyStatusRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :version, 2, type: :uint32
  field :status, 3, type: HalC2.OpenShell.Proto.Openshell.V1.PolicyStatus, enum: true
  field :load_error, 4, type: :string, json_name: "loadError"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportPolicyStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportPolicyStatusResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxConfigurationAdmission do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxConfigurationAdmission",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :instance_id, 1, type: :string, json_name: "instanceId"

  field :state, 2,
    type: HalC2.OpenShell.Proto.Openshell.V1.ConfigurationAdmissionState,
    enum: true

  field :policy_version, 3, type: :uint32, json_name: "policyVersion"
  field :policy_hash, 4, type: :string, json_name: "policyHash"
  field :config_revision, 5, type: :uint64, json_name: "configRevision"
  field :provider_env_revision, 6, type: :uint64, json_name: "providerEnvRevision"
  field :error, 7, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportSandboxConfigurationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportSandboxConfigurationRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :admission, 2, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxConfigurationAdmission
  field :expected_instance_id, 3, type: :string, json_name: "expectedInstanceId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportSandboxConfigurationResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportSandboxConfigurationResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxPolicyRevision.ProvenanceEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxPolicyRevision.ProvenanceEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxPolicyRevision do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxPolicyRevision",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :version, 1, type: :uint32
  field :policy_hash, 2, type: :string, json_name: "policyHash"
  field :status, 3, type: HalC2.OpenShell.Proto.Openshell.V1.PolicyStatus, enum: true
  field :load_error, 4, type: :string, json_name: "loadError"
  field :created_time, 105, type: Google.Protobuf.Timestamp, json_name: "createdTime"
  field :loaded_time, 106, type: Google.Protobuf.Timestamp, json_name: "loadedTime"
  field :policy, 7, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy

  field :provenance, 8,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.SandboxPolicyRevision.ProvenanceEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxLogsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxLogsRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 6,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :lines, 2, type: :uint32
  field :since_time, 103, type: Google.Protobuf.Timestamp, json_name: "sinceTime"
  field :sources, 4, repeated: true, type: :string
  field :min_level, 5, type: :string, json_name: "minLevel"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PushSandboxLogsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PushSandboxLogsRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :logs, 2, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxLogLine
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PushSandboxLogsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PushSandboxLogsResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetSandboxLogsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetSandboxLogsResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :logs, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxLogLine
  field :buffer_total, 2, type: :uint32, json_name: "bufferTotal"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SupervisorMessage do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SupervisorMessage",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :hello, 1, type: HalC2.OpenShell.Proto.Openshell.V1.SupervisorHello, oneof: 0
  field :heartbeat, 2, type: HalC2.OpenShell.Proto.Openshell.V1.SupervisorHeartbeat, oneof: 0

  field :relay_open_result, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.RelayOpenResult,
    json_name: "relayOpenResult",
    oneof: 0

  field :relay_close, 4,
    type: HalC2.OpenShell.Proto.Openshell.V1.RelayClose,
    json_name: "relayClose",
    oneof: 0

  field :config_update_result, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdateResult,
    json_name: "configUpdateResult",
    oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GatewayMessage do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GatewayMessage",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :session_accepted, 1,
    type: HalC2.OpenShell.Proto.Openshell.V1.SessionAccepted,
    json_name: "sessionAccepted",
    oneof: 0

  field :session_rejected, 2,
    type: HalC2.OpenShell.Proto.Openshell.V1.SessionRejected,
    json_name: "sessionRejected",
    oneof: 0

  field :heartbeat, 3, type: HalC2.OpenShell.Proto.Openshell.V1.GatewayHeartbeat, oneof: 0

  field :relay_open, 4,
    type: HalC2.OpenShell.Proto.Openshell.V1.RelayOpen,
    json_name: "relayOpen",
    oneof: 0

  field :relay_close, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.RelayClose,
    json_name: "relayClose",
    oneof: 0

  field :session_redirect, 6,
    type: HalC2.OpenShell.Proto.Openshell.V1.SessionRedirect,
    json_name: "sessionRedirect",
    oneof: 0

  field :config_update, 7,
    type: HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdate,
    json_name: "configUpdate",
    oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SupervisorHello do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SupervisorHello",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :instance_id, 2, type: :string, json_name: "instanceId"
  field :connection_epoch, 3, type: :uint64, json_name: "connectionEpoch"
  field :supports_provider_readiness, 4, type: :bool, json_name: "supportsProviderReadiness"
  field :redirected, 5, type: :bool
  field :supports_session_redirect, 6, type: :bool, json_name: "supportsSessionRedirect"
  field :supports_config_push, 7, type: :bool, json_name: "supportsConfigPush"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SessionAccepted do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SessionAccepted",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :bootstrap, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdate
  field :config_push_enabled, 4, type: :bool, json_name: "configPushEnabled"
  field :heartbeat_interval, 102, type: Google.Protobuf.Duration, json_name: "heartbeatInterval"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigUpdate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :update_id, 1, type: :string, json_name: "updateId"

  field :sandbox_config, 2,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxConfigSnapshot,
    json_name: "sandboxConfig"

  field :provider_environment, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderEnvironmentSnapshot,
    json_name: "providerEnvironment"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigApplyFailure do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigApplyFailure",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :code, 1, type: :string
  field :message, 2, type: :string
  field :retryable, 3, type: :bool
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ConfigUpdateResult do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ConfigUpdateResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :update_id, 1, type: :string, json_name: "updateId"
  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigApplyOutcome, enum: true
  field :failure, 3, type: HalC2.OpenShell.Proto.Openshell.V1.ConfigApplyFailure
  field :admission, 4, type: HalC2.OpenShell.Proto.Openshell.V1.SandboxConfigurationAdmission

  field :policy_load, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.PolicyLoadResult,
    json_name: "policyLoad"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PolicyLoadResult do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PolicyLoadResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :version, 1, type: :uint32
  field :loaded, 2, type: :bool
  field :error, 3, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SessionRejected do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SessionRejected",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :reason, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SessionRedirect do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SessionRedirect",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :peer_endpoint, 1, type: :string, json_name: "peerEndpoint"
  field :owner_replica_id, 2, type: :string, json_name: "ownerReplicaId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SupervisorHeartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SupervisorHeartbeat",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GatewayHeartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GatewayHeartbeat",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportMainProcessExitRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportMainProcessExitRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :instance_id, 2, type: :string, json_name: "instanceId"
  field :exit_code, 3, type: :int32, json_name: "exitCode"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportMainProcessExitResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportMainProcessExitResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.FinalizeMainProcessExitRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.FinalizeMainProcessExitRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :instance_id, 2, type: :string, json_name: "instanceId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.FinalizeMainProcessExitResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.FinalizeMainProcessExitResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RelayOpen do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RelayOpen",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :target, 0

  field :channel_id, 1, type: :string, json_name: "channelId"
  field :ssh, 2, type: HalC2.OpenShell.Proto.Openshell.V1.SshRelayTarget, oneof: 0
  field :tcp, 3, type: HalC2.OpenShell.Proto.Openshell.V1.TcpRelayTarget, oneof: 0
  field :service_id, 5, type: :string, json_name: "serviceId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SshRelayTarget do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SshRelayTarget",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.TcpRelayTarget do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.TcpRelayTarget",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :host, 1, type: :string
  field :port, 2, type: :uint32
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RelayInit do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RelayInit",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :channel_id, 1, type: :string, json_name: "channelId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RelayFrame do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RelayFrame",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :init, 1, type: HalC2.OpenShell.Proto.Openshell.V1.RelayInit, oneof: 0
  field :data, 2, type: :bytes, oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PeerRelayInit do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PeerRelayInit",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :relay_open, 2, type: HalC2.OpenShell.Proto.Openshell.V1.RelayOpen, json_name: "relayOpen"
  field :requester_replica_id, 3, type: :string, json_name: "requesterReplicaId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PeerRelayFrame do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PeerRelayFrame",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :payload, 0

  field :init, 1, type: HalC2.OpenShell.Proto.Openshell.V1.PeerRelayInit, oneof: 0
  field :data, 2, type: :bytes, oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PeerConfigSandboxTarget do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PeerConfigSandboxTarget",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :session_id, 2, type: :string, json_name: "sessionId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PeerConfigProviderTarget do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PeerConfigProviderTarget",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace, 1, type: :string
  field :name, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PeerNotifyConfigUpdateRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PeerNotifyConfigUpdateRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :scope, 0

  field :sandbox, 1, type: HalC2.OpenShell.Proto.Openshell.V1.PeerConfigSandboxTarget, oneof: 0
  field :workspace, 2, type: :string, oneof: 0
  field :all_connected, 3, type: :bool, json_name: "allConnected", oneof: 0
  field :provider, 4, type: HalC2.OpenShell.Proto.Openshell.V1.PeerConfigProviderTarget, oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PeerNotifyConfigUpdateResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PeerNotifyConfigUpdateResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :stale_owner, 1, type: :bool, json_name: "staleOwner"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RelayOpenResult do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RelayOpenResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :channel_id, 1, type: :string, json_name: "channelId"
  field :success, 2, type: :bool
  field :error, 3, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RelayClose do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RelayClose",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :channel_id, 1, type: :string, json_name: "channelId"
  field :reason, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.L7RequestSample do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.L7RequestSample",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :method, 1, type: :string
  field :path, 2, type: :string
  field :decision, 3, type: :string
  field :count, 4, type: :uint32
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DenialSummary do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DenialSummary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :host, 2, type: :string
  field :port, 3, type: :uint32
  field :binary, 4, type: :string
  field :ancestors, 5, repeated: true, type: :string
  field :deny_reason, 6, type: :string, json_name: "denyReason"
  field :first_seen_time, 107, type: Google.Protobuf.Timestamp, json_name: "firstSeenTime"
  field :last_seen_time, 108, type: Google.Protobuf.Timestamp, json_name: "lastSeenTime"
  field :count, 9, type: :uint32
  field :suppressed_count, 10, type: :uint32, json_name: "suppressedCount"
  field :total_count, 11, type: :uint32, json_name: "totalCount"
  field :sample_cmdlines, 12, repeated: true, type: :string, json_name: "sampleCmdlines"
  field :binary_sha256, 13, type: :string, json_name: "binarySha256"
  field :persistent, 14, type: :bool
  field :denial_stage, 15, type: :string, json_name: "denialStage"

  field :l7_request_samples, 16,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.L7RequestSample,
    json_name: "l7RequestSamples"

  field :l7_inspection_active, 17, type: :bool, json_name: "l7InspectionActive"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DenialGroupCount do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DenialGroupCount",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :deny_group, 1, type: :string, json_name: "denyGroup"
  field :denied_count, 2, type: :uint32, json_name: "deniedCount"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.NetworkActivitySummary do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.NetworkActivitySummary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :network_activity_count, 1, type: :uint32, json_name: "networkActivityCount"
  field :denied_action_count, 2, type: :uint32, json_name: "deniedActionCount"

  field :denials_by_group, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.DenialGroupCount,
    json_name: "denialsByGroup"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.PolicyChunk do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.PolicyChunk",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :id, 1, type: :string
  field :status, 2, type: :string
  field :rule_name, 3, type: :string, json_name: "ruleName"

  field :proposed_rule, 4,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule,
    json_name: "proposedRule"

  field :rationale, 5, type: :string
  field :security_notes, 6, type: :string, json_name: "securityNotes"
  field :confidence, 7, type: :float
  field :denial_summary_ids, 8, repeated: true, type: :string, json_name: "denialSummaryIds"
  field :created_time, 109, type: Google.Protobuf.Timestamp, json_name: "createdTime"
  field :decided_time, 110, type: Google.Protobuf.Timestamp, json_name: "decidedTime"
  field :stage, 11, type: :string
  field :supersedes_chunk_id, 12, type: :string, json_name: "supersedesChunkId"
  field :hit_count, 13, type: :int32, json_name: "hitCount"
  field :first_seen_time, 114, type: Google.Protobuf.Timestamp, json_name: "firstSeenTime"
  field :last_seen_time, 115, type: Google.Protobuf.Timestamp, json_name: "lastSeenTime"
  field :binary, 16, type: :string
  field :validation_result, 17, type: :string, json_name: "validationResult"
  field :rejection_reason, 18, type: :string, json_name: "rejectionReason"
  field :application_error, 19, type: :string, json_name: "applicationError"
  field :review_token, 20, type: :string, json_name: "reviewToken"
  field :current_effective_policy_hash, 21, type: :string, json_name: "currentEffectivePolicyHash"

  field :candidate_effective_policy_hash, 22,
    type: :string,
    json_name: "candidateEffectivePolicyHash"

  field :current_effective_policy, 23,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy,
    json_name: "currentEffectivePolicy"

  field :candidate_effective_policy, 24,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy,
    json_name: "candidateEffectivePolicy"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DraftPolicyUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DraftPolicyUpdate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :draft_version, 1, type: :uint64, json_name: "draftVersion"
  field :new_chunks, 2, type: :uint32, json_name: "newChunks"
  field :total_pending, 3, type: :uint32, json_name: "totalPending"
  field :summary, 4, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SubmitPolicyAnalysisRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SubmitPolicyAnalysisRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 6,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :summaries, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.DenialSummary

  field :proposed_chunks, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.PolicyChunk,
    json_name: "proposedChunks"

  field :analysis_mode, 3, type: :string, json_name: "analysisMode"
  field :name, 4, type: :string

  field :network_activity_summaries, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.NetworkActivitySummary,
    json_name: "networkActivitySummaries"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SubmitPolicyAnalysisResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SubmitPolicyAnalysisResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :accepted_chunks, 1, type: :uint32, json_name: "acceptedChunks"
  field :rejected_chunks, 2, type: :uint32, json_name: "rejectedChunks"
  field :rejection_reasons, 3, repeated: true, type: :string, json_name: "rejectionReasons"
  field :accepted_chunk_ids, 4, repeated: true, type: :string, json_name: "acceptedChunkIds"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetDraftPolicyRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetDraftPolicyRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :status_filter, 2, type: :string, json_name: "statusFilter"
  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetDraftPolicyResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetDraftPolicyResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :chunks, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.PolicyChunk
  field :rolling_summary, 2, type: :string, json_name: "rollingSummary"
  field :draft_version, 3, type: :uint64, json_name: "draftVersion"
  field :last_analyzed_time, 104, type: Google.Protobuf.Timestamp, json_name: "lastAnalyzedTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ApproveDraftChunkRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ApproveDraftChunkRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :chunk_id, 2, type: :string, json_name: "chunkId"
  field :review_token, 4, type: :string, json_name: "reviewToken"
  field :sandbox, 1, type: :string
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ApproveDraftChunkResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ApproveDraftChunkResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy_version, 1, type: :uint32, json_name: "policyVersion"
  field :policy_hash, 2, type: :string, json_name: "policyHash"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RejectDraftChunkRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RejectDraftChunkRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :chunk_id, 2, type: :string, json_name: "chunkId"
  field :reason, 3, type: :string
  field :sandbox, 1, type: :string
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RejectDraftChunkResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RejectDraftChunkResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DraftChunkApproval do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DraftChunkApproval",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :chunk_id, 1, type: :string, json_name: "chunkId"
  field :review_token, 2, type: :string, json_name: "reviewToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ApproveAllDraftChunksRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ApproveAllDraftChunksRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :include_security_flagged, 2, type: :bool, json_name: "includeSecurityFlagged"
  field :approvals, 3, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.DraftChunkApproval
  field :sandbox, 1, type: :string
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ApproveAllDraftChunksResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ApproveAllDraftChunksResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy_version, 1, type: :uint32, json_name: "policyVersion"
  field :policy_hash, 2, type: :string, json_name: "policyHash"
  field :chunks_approved, 3, type: :uint32, json_name: "chunksApproved"
  field :chunks_skipped, 4, type: :uint32, json_name: "chunksSkipped"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EditDraftChunkRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.EditDraftChunkRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 4,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :chunk_id, 2, type: :string, json_name: "chunkId"

  field :proposed_rule, 3,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule,
    json_name: "proposedRule"

  field :sandbox, 1, type: :string
  field :request_id, 5, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EditDraftChunkResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.EditDraftChunkResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UndoDraftChunkRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UndoDraftChunkRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :chunk_id, 2, type: :string, json_name: "chunkId"
  field :sandbox, 1, type: :string
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.UndoDraftChunkResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.UndoDraftChunkResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy_version, 1, type: :uint32, json_name: "policyVersion"
  field :policy_hash, 2, type: :string, json_name: "policyHash"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ClearDraftChunksRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ClearDraftChunksRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ClearDraftChunksResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ClearDraftChunksResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :chunks_cleared, 1, type: :uint32, json_name: "chunksCleared"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetDraftHistoryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetDraftHistoryRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :sandbox, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DraftHistoryEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DraftHistoryEntry",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :event_time, 101, type: Google.Protobuf.Timestamp, json_name: "eventTime"
  field :event_type, 2, type: :string, json_name: "eventType"
  field :description, 3, type: :string
  field :chunk_id, 4, type: :string, json_name: "chunkId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetDraftHistoryResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetDraftHistoryResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :entries, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.DraftHistoryEntry
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateWorkspaceRequest.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateWorkspaceRequest.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateWorkspaceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateWorkspaceRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string

  field :labels, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.CreateWorkspaceRequest.LabelsEntry,
    map: true

  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.CreateWorkspaceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.CreateWorkspaceResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Workspace
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetWorkspaceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetWorkspaceRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.GetWorkspaceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.GetWorkspaceResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Workspace
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListWorkspacesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListWorkspacesRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :page_size, 1, type: :int32, json_name: "pageSize"
  field :page_token, 2, type: :string, json_name: "pageToken"
  field :label_selector, 3, type: :string, json_name: "labelSelector"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListWorkspacesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListWorkspacesResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspaces, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Workspace

  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteWorkspaceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteWorkspaceRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :allow_missing, 2, type: :bool, json_name: "allowMissing"
  field :request_id, 3, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.DeleteWorkspaceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.DeleteWorkspaceResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.WorkspaceMember do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.WorkspaceMember",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :principal_subject, 2, type: :string, json_name: "principalSubject"
  field :role, 3, type: HalC2.OpenShell.Proto.Openshell.V1.WorkspaceRole, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AddWorkspaceMemberRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AddWorkspaceMemberRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 1,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :principal_subject, 2, type: :string, json_name: "principalSubject"
  field :role, 3, type: HalC2.OpenShell.Proto.Openshell.V1.WorkspaceRole, enum: true
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.AddWorkspaceMemberResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.AddWorkspaceMemberResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :member, 1, type: HalC2.OpenShell.Proto.Openshell.V1.WorkspaceMember
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RemoveWorkspaceMemberRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RemoveWorkspaceMemberRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 1,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :principal_subject, 2, type: :string, json_name: "principalSubject"
  field :allow_missing, 3, type: :bool, json_name: "allowMissing"
  field :request_id, 4, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.RemoveWorkspaceMemberResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.RemoveWorkspaceMemberResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :outcome, 2, type: HalC2.OpenShell.Proto.Openshell.V1.DeletionOutcome, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListWorkspaceMembersRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListWorkspaceMembersRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 1,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :page_size, 2, type: :int32, json_name: "pageSize"
  field :page_token, 3, type: :string, json_name: "pageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ListWorkspaceMembersResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ListWorkspaceMembersResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :members, 1, repeated: true, type: HalC2.OpenShell.Proto.Openshell.V1.WorkspaceMember
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ExtensionServiceCredential do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ExtensionServiceCredential",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :token, 2, type: :string, deprecated: false
  field :expiration_time, 103, type: Google.Protobuf.Timestamp, json_name: "expirationTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EndpointObservation do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.EndpointObservation",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :endpoint_id, 1, type: :string, json_name: "endpointId"
  field :result, 2, type: HalC2.OpenShell.Proto.Openshell.V1.EndpointResult, enum: true
  field :failure, 3, type: HalC2.OpenShell.Proto.Openshell.V1.EndpointFailure
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportEndpointStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportEndpointStatusRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :sandbox_id, 1, type: :string, json_name: "sandboxId"
  field :policy_hash, 2, type: :string, json_name: "policyHash"
  field :provider_env_revision, 3, type: :uint64, json_name: "providerEnvRevision"

  field :observations, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.V1.EndpointObservation

  field :observed_endpoint_ids, 5, repeated: true, type: :string, json_name: "observedEndpointIds"
  field :supervisor_session_id, 6, type: :string, json_name: "supervisorSessionId"
  field :report_sequence, 7, type: :uint64, json_name: "reportSequence"

  field :token_grant_status, 8,
    type: HalC2.OpenShell.Proto.Openshell.V1.TokenGrantStatus,
    json_name: "tokenGrantStatus"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.TokenGrantStatus do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.TokenGrantStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :last_failure, 1,
    type: HalC2.OpenShell.Proto.Openshell.V1.TokenGrantFailureObservation,
    json_name: "lastFailure"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.TokenGrantFailureObservation do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.TokenGrantFailureObservation",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :destination_host, 1, type: :string, json_name: "destinationHost"
  field :destination_port, 2, type: :uint32, json_name: "destinationPort"
  field :failure, 3, type: HalC2.OpenShell.Proto.Openshell.V1.EndpointFailure
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.ReportEndpointStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.ReportEndpointStatusResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EndpointStatus do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.EndpointStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :endpoint_id, 1, type: :string, json_name: "endpointId"
  field :host, 2, type: :string
  field :ports, 3, repeated: true, type: :uint32
  field :path, 4, type: :string

  field :last_result, 5,
    type: HalC2.OpenShell.Proto.Openshell.V1.EndpointResult,
    json_name: "lastResult",
    enum: true

  field :last_reported_time, 106, type: Google.Protobuf.Timestamp, json_name: "lastReportedTime"

  field :last_failure, 7,
    type: HalC2.OpenShell.Proto.Openshell.V1.EndpointFailure,
    json_name: "lastFailure"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxProvisioning do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxProvisioning",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :attempt_id, 1, type: :string, json_name: "attemptId"
  field :configuration_change_id, 2, type: :string, json_name: "configurationChangeId"

  field :configuration_change_time, 3,
    type: Google.Protobuf.Timestamp,
    json_name: "configurationChangeTime"

  field :first_rejection_time, 4, type: Google.Protobuf.Timestamp, json_name: "firstRejectionTime"
  field :deadline, 5, type: Google.Protobuf.Timestamp
  field :timeout_time, 6, type: Google.Protobuf.Timestamp, json_name: "timeoutTime"

  field :cleanup_completed_time, 7,
    type: Google.Protobuf.Timestamp,
    json_name: "cleanupCompletedTime"

  field :cleanup_error, 8, type: :string, json_name: "cleanupError"
  field :cleanup_retry_time, 9, type: Google.Protobuf.Timestamp, json_name: "cleanupRetryTime"
  field :attachment_change_id, 10, type: :string, json_name: "attachmentChangeId"

  field :attachment_change_time, 11,
    type: Google.Protobuf.Timestamp,
    json_name: "attachmentChangeTime"

  field :preparation_deadline, 12,
    type: Google.Protobuf.Timestamp,
    json_name: "preparationDeadline"

  field :admission_start_time, 13,
    type: Google.Protobuf.Timestamp,
    json_name: "admissionStartTime"

  field :driver_operation_pending, 14, type: :bool, json_name: "driverOperationPending"
  field :driver_operation_id, 15, type: :string, json_name: "driverOperationId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxServiceExposure do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.SandboxServiceExposure",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :service, 1, type: :string
  field :target_port, 2, type: :uint32, json_name: "targetPort"

  field :authorization_mode, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.ServiceAuthorizationMode,
    json_name: "authorizationMode",
    enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.EndpointFailure do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.v1.EndpointFailure",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :domain, 1, type: HalC2.OpenShell.Proto.Openshell.V1.EndpointFailureDomain, enum: true
  field :code, 2, type: :string

  field :recovery_action, 3,
    type: HalC2.OpenShell.Proto.Openshell.V1.ProviderCredentialRefreshRecoveryAction,
    json_name: "recoveryAction",
    enum: true

  field :provider, 4, type: :string
  field :credential_key, 5, type: :string, json_name: "credentialKey"
  field :stage, 6, type: :string

  field :upstream_http_status, 7,
    proto3_optional: true,
    type: :uint32,
    json_name: "upstreamHttpStatus"

  field :request_id, 8, type: :string, json_name: "requestId"
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.OpenShell.Service do
  @moduledoc false

  use GRPC.Service, name: "openshell.v1.OpenShell", protoc_gen_elixir_version: "0.17.1"

  rpc :Health,
      HalC2.OpenShell.Proto.Openshell.V1.HealthRequest,
      HalC2.OpenShell.Proto.Openshell.V1.HealthResponse

  rpc :GetCurrentUser,
      HalC2.OpenShell.Proto.Openshell.V1.GetCurrentUserRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetCurrentUserResponse

  rpc :GetGatewayInfo,
      HalC2.OpenShell.Proto.Openshell.V1.GetGatewayInfoRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetGatewayInfoResponse

  rpc :CreateSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse

  rpc :BeginRootfsTarStaging,
      HalC2.OpenShell.Proto.Openshell.V1.BeginRootfsTarStagingRequest,
      HalC2.OpenShell.Proto.Openshell.V1.BeginRootfsTarStagingResponse

  rpc :GetSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse

  rpc :ListSandboxes,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxesResponse

  rpc :CreateSandboxTemplate,
      HalC2.OpenShell.Proto.Openshell.V1.CreateSandboxTemplateRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplateResponse

  rpc :GetSandboxTemplate,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxTemplateRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxTemplateResponse

  rpc :ListSandboxTemplates,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxTemplatesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxTemplatesResponse

  rpc :DeleteSandboxTemplate,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxTemplateRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxTemplateResponse

  rpc :ListSandboxProviders,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxProvidersRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxProvidersResponse

  rpc :AttachSandboxProvider,
      HalC2.OpenShell.Proto.Openshell.V1.AttachSandboxProviderRequest,
      HalC2.OpenShell.Proto.Openshell.V1.AttachSandboxProviderResponse

  rpc :DetachSandboxProvider,
      HalC2.OpenShell.Proto.Openshell.V1.DetachSandboxProviderRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DetachSandboxProviderResponse

  rpc :GetSandboxProviderStatus,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderStatusResponse

  rpc :DeleteSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteSandboxResponse

  rpc :StopSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.StopSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse

  rpc :StartSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.StartSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse

  rpc :SuspendSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.SuspendSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse

  rpc :ResumeSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.ResumeSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse

  rpc :CreateSshSession,
      HalC2.OpenShell.Proto.Openshell.V1.CreateSshSessionRequest,
      HalC2.OpenShell.Proto.Openshell.V1.CreateSshSessionResponse

  rpc :ExposeService,
      HalC2.OpenShell.Proto.Openshell.V1.ExposeServiceRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ServiceEndpointResponse

  rpc :GetService,
      HalC2.OpenShell.Proto.Openshell.V1.GetServiceRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ServiceEndpointResponse

  rpc :ListServices,
      HalC2.OpenShell.Proto.Openshell.V1.ListServicesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListServicesResponse

  rpc :DeleteService,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteServiceRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteServiceResponse

  rpc :RevokeSshSession,
      HalC2.OpenShell.Proto.Openshell.V1.RevokeSshSessionRequest,
      HalC2.OpenShell.Proto.Openshell.V1.RevokeSshSessionResponse

  rpc :ExecSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxRequest,
      stream(HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxEvent)

  rpc :ForwardTcp,
      stream(HalC2.OpenShell.Proto.Openshell.V1.TcpForwardFrame),
      stream(HalC2.OpenShell.Proto.Openshell.V1.TcpForwardFrame)

  rpc :ExecSandboxInteractive,
      stream(HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxInput),
      stream(HalC2.OpenShell.Proto.Openshell.V1.ExecSandboxEvent)

  rpc :CreateProvider,
      HalC2.OpenShell.Proto.Openshell.V1.CreateProviderRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ProviderResponse

  rpc :GetProvider,
      HalC2.OpenShell.Proto.Openshell.V1.GetProviderRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ProviderResponse

  rpc :GetProviderCredentials,
      HalC2.OpenShell.Proto.Openshell.V1.GetProviderCredentialsRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetProviderCredentialsResponse

  rpc :ListProviders,
      HalC2.OpenShell.Proto.Openshell.V1.ListProvidersRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListProvidersResponse

  rpc :ListProviderProfiles,
      HalC2.OpenShell.Proto.Openshell.V1.ListProviderProfilesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListProviderProfilesResponse

  rpc :GetProviderProfile,
      HalC2.OpenShell.Proto.Openshell.V1.GetProviderProfileRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileResponse

  rpc :ImportProviderProfiles,
      HalC2.OpenShell.Proto.Openshell.V1.ImportProviderProfilesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ImportProviderProfilesResponse

  rpc :UpdateProviderProfiles,
      HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderProfilesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderProfilesResponse

  rpc :LintProviderProfiles,
      HalC2.OpenShell.Proto.Openshell.V1.LintProviderProfilesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.LintProviderProfilesResponse

  rpc :UpdateProvider,
      HalC2.OpenShell.Proto.Openshell.V1.UpdateProviderRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ProviderResponse

  rpc :GetProviderRefreshStatus,
      HalC2.OpenShell.Proto.Openshell.V1.GetProviderRefreshStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetProviderRefreshStatusResponse

  rpc :ConfigureProviderRefresh,
      HalC2.OpenShell.Proto.Openshell.V1.ConfigureProviderRefreshRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ConfigureProviderRefreshResponse

  rpc :RotateProviderCredential,
      HalC2.OpenShell.Proto.Openshell.V1.RotateProviderCredentialRequest,
      HalC2.OpenShell.Proto.Openshell.V1.RotateProviderCredentialResponse

  rpc :DeleteProviderRefresh,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderRefreshRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderRefreshResponse

  rpc :DeleteProvider,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderResponse

  rpc :DeleteProviderProfile,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderProfileRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteProviderProfileResponse

  rpc :GetSandboxConfig,
      HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigRequest,
      HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigResponse

  rpc :GetGatewayConfig,
      HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetGatewayConfigRequest,
      HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetGatewayConfigResponse

  rpc :UpdateConfig,
      HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigRequest,
      HalC2.OpenShell.Proto.Openshell.V1.UpdateConfigResponse

  rpc :GetSandboxPolicyStatus,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxPolicyStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxPolicyStatusResponse

  rpc :ListSandboxPolicies,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxPoliciesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListSandboxPoliciesResponse

  rpc :ReportPolicyStatus,
      HalC2.OpenShell.Proto.Openshell.V1.ReportPolicyStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportPolicyStatusResponse

  rpc :ReportEndpointStatus,
      HalC2.OpenShell.Proto.Openshell.V1.ReportEndpointStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportEndpointStatusResponse

  rpc :ReportProviderReadiness,
      HalC2.OpenShell.Proto.Openshell.V1.ReportProviderReadinessRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportProviderReadinessResponse

  rpc :ReportSandboxConfiguration,
      HalC2.OpenShell.Proto.Openshell.V1.ReportSandboxConfigurationRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportSandboxConfigurationResponse

  rpc :GetSandboxProviderEnvironment,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderEnvironmentResponse

  rpc :ExchangeProviderSubjectToken,
      HalC2.OpenShell.Proto.Openshell.V1.ExchangeProviderSubjectTokenRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ExchangeProviderSubjectTokenResponse

  rpc :GetSandboxLogs,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxLogsRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxLogsResponse

  rpc :PushSandboxLogs,
      stream(HalC2.OpenShell.Proto.Openshell.V1.PushSandboxLogsRequest),
      HalC2.OpenShell.Proto.Openshell.V1.PushSandboxLogsResponse

  rpc :ConnectSupervisor,
      stream(HalC2.OpenShell.Proto.Openshell.V1.SupervisorMessage),
      stream(HalC2.OpenShell.Proto.Openshell.V1.GatewayMessage)

  rpc :ReportMainProcessExit,
      HalC2.OpenShell.Proto.Openshell.V1.ReportMainProcessExitRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportMainProcessExitResponse

  rpc :FinalizeMainProcessExit,
      HalC2.OpenShell.Proto.Openshell.V1.FinalizeMainProcessExitRequest,
      HalC2.OpenShell.Proto.Openshell.V1.FinalizeMainProcessExitResponse

  rpc :RelayStream,
      stream(HalC2.OpenShell.Proto.Openshell.V1.RelayFrame),
      stream(HalC2.OpenShell.Proto.Openshell.V1.RelayFrame)

  rpc :PeerRelay,
      stream(HalC2.OpenShell.Proto.Openshell.V1.PeerRelayFrame),
      stream(HalC2.OpenShell.Proto.Openshell.V1.PeerRelayFrame)

  rpc :PeerReportProviderReadiness,
      HalC2.OpenShell.Proto.Openshell.V1.ReportProviderReadinessRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportProviderReadinessResponse

  rpc :PeerReportEndpointStatus,
      HalC2.OpenShell.Proto.Openshell.V1.ReportEndpointStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ReportEndpointStatusResponse

  rpc :PeerGetSandboxProviderStatus,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderStatusRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetSandboxProviderStatusResponse

  rpc :PeerNotifyConfigUpdate,
      HalC2.OpenShell.Proto.Openshell.V1.PeerNotifyConfigUpdateRequest,
      HalC2.OpenShell.Proto.Openshell.V1.PeerNotifyConfigUpdateResponse

  rpc :WatchSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.WatchSandboxRequest,
      stream(HalC2.OpenShell.Proto.Openshell.V1.SandboxStreamEvent)

  rpc :SubmitPolicyAnalysis,
      HalC2.OpenShell.Proto.Openshell.V1.SubmitPolicyAnalysisRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SubmitPolicyAnalysisResponse

  rpc :GetDraftPolicy,
      HalC2.OpenShell.Proto.Openshell.V1.GetDraftPolicyRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetDraftPolicyResponse

  rpc :ApproveDraftChunk,
      HalC2.OpenShell.Proto.Openshell.V1.ApproveDraftChunkRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ApproveDraftChunkResponse

  rpc :RejectDraftChunk,
      HalC2.OpenShell.Proto.Openshell.V1.RejectDraftChunkRequest,
      HalC2.OpenShell.Proto.Openshell.V1.RejectDraftChunkResponse

  rpc :ApproveAllDraftChunks,
      HalC2.OpenShell.Proto.Openshell.V1.ApproveAllDraftChunksRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ApproveAllDraftChunksResponse

  rpc :EditDraftChunk,
      HalC2.OpenShell.Proto.Openshell.V1.EditDraftChunkRequest,
      HalC2.OpenShell.Proto.Openshell.V1.EditDraftChunkResponse

  rpc :UndoDraftChunk,
      HalC2.OpenShell.Proto.Openshell.V1.UndoDraftChunkRequest,
      HalC2.OpenShell.Proto.Openshell.V1.UndoDraftChunkResponse

  rpc :ClearDraftChunks,
      HalC2.OpenShell.Proto.Openshell.V1.ClearDraftChunksRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ClearDraftChunksResponse

  rpc :GetDraftHistory,
      HalC2.OpenShell.Proto.Openshell.V1.GetDraftHistoryRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetDraftHistoryResponse

  rpc :IssueSandboxToken,
      HalC2.OpenShell.Proto.Openshell.V1.IssueSandboxTokenRequest,
      HalC2.OpenShell.Proto.Openshell.V1.IssueSandboxTokenResponse

  rpc :RefreshSandboxToken,
      HalC2.OpenShell.Proto.Openshell.V1.RefreshSandboxTokenRequest,
      HalC2.OpenShell.Proto.Openshell.V1.RefreshSandboxTokenResponse

  rpc :CreateWorkspace,
      HalC2.OpenShell.Proto.Openshell.V1.CreateWorkspaceRequest,
      HalC2.OpenShell.Proto.Openshell.V1.CreateWorkspaceResponse

  rpc :GetWorkspace,
      HalC2.OpenShell.Proto.Openshell.V1.GetWorkspaceRequest,
      HalC2.OpenShell.Proto.Openshell.V1.GetWorkspaceResponse

  rpc :ListWorkspaces,
      HalC2.OpenShell.Proto.Openshell.V1.ListWorkspacesRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListWorkspacesResponse

  rpc :DeleteWorkspace,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteWorkspaceRequest,
      HalC2.OpenShell.Proto.Openshell.V1.DeleteWorkspaceResponse

  rpc :AddWorkspaceMember,
      HalC2.OpenShell.Proto.Openshell.V1.AddWorkspaceMemberRequest,
      HalC2.OpenShell.Proto.Openshell.V1.AddWorkspaceMemberResponse

  rpc :RemoveWorkspaceMember,
      HalC2.OpenShell.Proto.Openshell.V1.RemoveWorkspaceMemberRequest,
      HalC2.OpenShell.Proto.Openshell.V1.RemoveWorkspaceMemberResponse

  rpc :ListWorkspaceMembers,
      HalC2.OpenShell.Proto.Openshell.V1.ListWorkspaceMembersRequest,
      HalC2.OpenShell.Proto.Openshell.V1.ListWorkspaceMembersResponse
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.OpenShell.Stub do
  @moduledoc false

  use GRPC.Stub, service: HalC2.OpenShell.Proto.Openshell.V1.OpenShell.Service
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxUpdates.Service do
  @moduledoc false

  use GRPC.Service, name: "openshell.v1.SandboxUpdates", protoc_gen_elixir_version: "0.17.1"

  rpc :UpdateSandbox,
      HalC2.OpenShell.Proto.Openshell.V1.UpdateSandboxRequest,
      HalC2.OpenShell.Proto.Openshell.V1.SandboxResponse
end

defmodule HalC2.OpenShell.Proto.Openshell.V1.SandboxUpdates.Stub do
  @moduledoc false

  use GRPC.Stub, service: HalC2.OpenShell.Proto.Openshell.V1.SandboxUpdates.Service
end
