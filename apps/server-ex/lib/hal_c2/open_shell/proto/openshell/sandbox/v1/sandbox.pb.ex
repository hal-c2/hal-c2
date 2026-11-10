defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkTlsMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.NetworkTlsMode",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :NETWORK_TLS_MODE_UNSPECIFIED, 0
  field :NETWORK_TLS_MODE_SKIP, 1
  field :NETWORK_TLS_MODE_TERMINATE, 2
  field :NETWORK_TLS_MODE_PASSTHROUGH, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEnforcementMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.NetworkEnforcementMode",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :NETWORK_ENFORCEMENT_MODE_UNSPECIFIED, 0
  field :NETWORK_ENFORCEMENT_MODE_ENFORCE, 1
  field :NETWORK_ENFORCEMENT_MODE_AUDIT, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkAccessPreset do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.NetworkAccessPreset",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :NETWORK_ACCESS_PRESET_UNSPECIFIED, 0
  field :NETWORK_ACCESS_PRESET_READ_ONLY, 1
  field :NETWORK_ACCESS_PRESET_READ_WRITE, 2
  field :NETWORK_ACCESS_PRESET_FULL, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SettingScope do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.SettingScope",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SETTING_SCOPE_UNSPECIFIED, 0
  field :SETTING_SCOPE_SANDBOX, 1
  field :SETTING_SCOPE_GLOBAL, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.PolicySource do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.PolicySource",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :POLICY_SOURCE_UNSPECIFIED, 0
  field :POLICY_SOURCE_SANDBOX, 1
  field :POLICY_SOURCE_GLOBAL, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareBindingPolicy do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.SupervisorMiddlewareBindingPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SUPERVISOR_MIDDLEWARE_BINDING_POLICY_UNSPECIFIED, 0
  field :SUPERVISOR_MIDDLEWARE_BINDING_POLICY_DYNAMIC, 1
  field :SUPERVISOR_MIDDLEWARE_BINDING_POLICY_ALLOWLIST, 2
  field :SUPERVISOR_MIDDLEWARE_BINDING_POLICY_EXACT, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareBinding do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.sandbox.v1.SupervisorMiddlewareBinding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :SUPERVISOR_MIDDLEWARE_BINDING_UNSPECIFIED, 0
  field :SUPERVISOR_MIDDLEWARE_BINDING_HTTP_REQUEST_PRE_CREDENTIALS, 1
  field :SUPERVISOR_MIDDLEWARE_BINDING_HTTP_RESPONSE_PRE_RETURN, 2
  field :SUPERVISOR_MIDDLEWARE_BINDING_WEBSOCKET_MESSAGE_PRE_CREDENTIALS, 3
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy.NetworkPoliciesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SandboxPolicy.NetworkPoliciesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy.NetworkMiddlewaresEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SandboxPolicy.NetworkMiddlewaresEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkMiddlewareConfig
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SandboxPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :version, 1, type: :uint32
  field :filesystem, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.FilesystemPolicy
  field :landlock, 3, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.LandlockPolicy
  field :process, 4, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.ProcessPolicy

  field :network_policies, 5,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy.NetworkPoliciesEntry,
    json_name: "networkPolicies",
    map: true

  field :network_middlewares, 6,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy.NetworkMiddlewaresEntry,
    json_name: "networkMiddlewares",
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.FilesystemPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.FilesystemPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :include_workdir, 1, type: :bool, json_name: "includeWorkdir"
  field :read_only, 2, repeated: true, type: :string, json_name: "readOnly"
  field :read_write, 3, repeated: true, type: :string, json_name: "readWrite"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.LandlockPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.LandlockPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :compatibility, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.ProcessPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.ProcessPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :run_as_user, 1, type: :string, json_name: "runAsUser"
  field :run_as_group, 2, type: :string, json_name: "runAsGroup"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.NetworkPolicyRule",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string

  field :endpoints, 2,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEndpoint

  field :binaries, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkBinary
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkMiddlewareConfig do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.NetworkMiddlewareConfig",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :middleware, 2, type: :string
  field :config, 3, type: Google.Protobuf.Struct
  field :on_error, 4, type: :string, json_name: "onError"
  field :endpoints, 5, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.MiddlewareEndpointSelector
  field :order, 6, type: :int32
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.MiddlewareEndpointSelector do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.MiddlewareEndpointSelector",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :include, 1, repeated: true, type: :string
  field :exclude, 2, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkCredentialBinding do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.NetworkCredentialBinding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :provider, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEndpoint.GraphqlPersistedQueriesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.NetworkEndpoint.GraphqlPersistedQueriesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GraphqlOperation
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEndpoint do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.NetworkEndpoint",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :host, 1, type: :string
  field :port, 2, type: :uint32
  field :protocol, 3, type: :string
  field :tls, 4, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkTlsMode, enum: true

  field :enforcement, 5,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEnforcementMode,
    enum: true

  field :access, 6,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkAccessPreset,
    enum: true

  field :rules, 7, repeated: true, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Rule
  field :allowed_ips, 8, repeated: true, type: :string, json_name: "allowedIps"
  field :ports, 9, repeated: true, type: :uint32

  field :deny_rules, 10,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule,
    json_name: "denyRules"

  field :allow_encoded_slash, 11, type: :bool, json_name: "allowEncodedSlash"
  field :persisted_queries, 12, type: :string, json_name: "persistedQueries"

  field :graphql_persisted_queries, 13,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEndpoint.GraphqlPersistedQueriesEntry,
    json_name: "graphqlPersistedQueries",
    map: true

  field :graphql_max_body_bytes, 14, type: :uint32, json_name: "graphqlMaxBodyBytes"
  field :path, 15, type: :string
  field :websocket_credential_rewrite, 16, type: :bool, json_name: "websocketCredentialRewrite"

  field :request_body_credential_rewrite, 17,
    type: :bool,
    json_name: "requestBodyCredentialRewrite"

  field :advisor_proposed, 18, type: :bool, json_name: "advisorProposed"
  field :credential_signing, 19, type: :string, json_name: "credentialSigning"
  field :signing_service, 20, type: :string, json_name: "signingService"
  field :signing_region, 21, type: :string, json_name: "signingRegion"
  field :json_rpc_max_body_bytes, 22, type: :uint32, json_name: "jsonRpcMaxBodyBytes"
  field :mcp, 23, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.McpOptions

  field :credential_binding, 24,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkCredentialBinding,
    json_name: "credentialBinding"

  field :allow_uninspected_credentials, 25, type: :bool, json_name: "allowUninspectedCredentials"
  field :provider_credentialed, 26, type: :bool, json_name: "providerCredentialed"
  field :token_grant_owner, 27, type: :string, json_name: "tokenGrantOwner"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.McpOptions do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.McpOptions",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :strict_tool_names, 1, proto3_optional: true, type: :bool, json_name: "strictToolNames"

  field :allow_all_known_mcp_methods, 2,
    proto3_optional: true,
    type: :bool,
    json_name: "allowAllKnownMcpMethods"

  field :versions, 3, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GraphqlOperation do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GraphqlOperation",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :operation_type, 1, type: :string, json_name: "operationType"
  field :operation_name, 2, type: :string, json_name: "operationName"
  field :fields, 3, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule.QueryEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7DenyRule.QueryEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7QueryMatcher
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule.ParamsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7DenyRule.ParamsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7QueryMatcher
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7DenyRule",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :method, 1, type: :string
  field :path, 2, type: :string
  field :command, 3, type: :string

  field :query, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule.QueryEntry,
    map: true

  field :operation_type, 5, type: :string, json_name: "operationType"
  field :operation_name, 6, type: :string, json_name: "operationName"
  field :fields, 7, repeated: true, type: :string

  field :params, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7DenyRule.ParamsEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Rule do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7Rule",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :allow, 1, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Allow
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Allow.QueryEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7Allow.QueryEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7QueryMatcher
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Allow.ParamsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7Allow.ParamsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7QueryMatcher
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Allow do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7Allow",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :method, 1, type: :string
  field :path, 2, type: :string
  field :command, 3, type: :string

  field :query, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Allow.QueryEntry,
    map: true

  field :operation_type, 5, type: :string, json_name: "operationType"
  field :operation_name, 6, type: :string, json_name: "operationName"
  field :fields, 7, repeated: true, type: :string

  field :params, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7Allow.ParamsEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.L7QueryMatcher do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.L7QueryMatcher",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :glob, 1, type: :string
  field :any, 2, repeated: true, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkBinary do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.NetworkBinary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :path, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GetSandboxConfigRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :workspace_scope, 3,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector,
    json_name: "workspaceScope"

  field :name, 1, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetGatewayConfigRequest do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GetGatewayConfigRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetGatewayConfigResponse.SettingsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GetGatewayConfigResponse.SettingsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SettingValue
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetGatewayConfigResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GetGatewayConfigResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :settings, 1,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetGatewayConfigResponse.SettingsEntry,
    map: true

  field :settings_revision, 2, type: :uint64, json_name: "settingsRevision"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SettingValue do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SettingValue",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :value, 0

  field :string_value, 1, type: :string, json_name: "stringValue", oneof: 0
  field :bool_value, 2, type: :bool, json_name: "boolValue", oneof: 0
  field :int_value, 3, type: :int64, json_name: "intValue", oneof: 0
  field :bytes_value, 4, type: :bytes, json_name: "bytesValue", oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.EffectiveSetting do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.EffectiveSetting",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :value, 1, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SettingValue
  field :scope, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SettingScope, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxConfigSnapshot.SettingsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SandboxConfigSnapshot.SettingsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.EffectiveSetting
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxConfigSnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SandboxConfigSnapshot",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy, 1, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy
  field :version, 2, type: :uint32
  field :policy_hash, 3, type: :string, json_name: "policyHash"

  field :settings, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxConfigSnapshot.SettingsEntry,
    map: true

  field :config_revision, 5, type: :uint64, json_name: "configRevision"

  field :policy_source, 6,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.PolicySource,
    json_name: "policySource",
    enum: true

  field :global_policy_version, 7, type: :uint32, json_name: "globalPolicyVersion"
  field :provider_env_revision, 8, type: :uint64, json_name: "providerEnvRevision"

  field :supervisor_middleware_services, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareService,
    json_name: "supervisorMiddlewareServices"

  field :workspace, 10, type: :string

  field :policy_validation_failure_mode, 11,
    type: :string,
    json_name: "policyValidationFailureMode"

  field :extension_authentication_enabled, 12,
    type: :bool,
    json_name: "extensionAuthenticationEnabled"

  field :configuration_admitted, 13, type: :bool, json_name: "configurationAdmitted"
  field :provider_attachment_epoch, 14, type: :string, json_name: "providerAttachmentEpoch"
  field :configuration_instance_id, 15, type: :string, json_name: "configurationInstanceId"
  field :configuration_error, 16, type: :string, json_name: "configurationError"
  field :settings_revision, 17, type: :uint64, json_name: "settingsRevision"

  field :service_routes, 18,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxServiceRoute,
    json_name: "serviceRoutes"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigResponse.SettingsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GetSandboxConfigResponse.SettingsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.EffectiveSetting
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigResponse do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.GetSandboxConfigResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy, 1, type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxPolicy
  field :version, 2, type: :uint32
  field :policy_hash, 3, type: :string, json_name: "policyHash"

  field :settings, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.GetSandboxConfigResponse.SettingsEntry,
    map: true

  field :config_revision, 5, type: :uint64, json_name: "configRevision"

  field :policy_source, 6,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.PolicySource,
    json_name: "policySource",
    enum: true

  field :global_policy_version, 7, type: :uint32, json_name: "globalPolicyVersion"
  field :provider_env_revision, 8, type: :uint64, json_name: "providerEnvRevision"

  field :supervisor_middleware_services, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareService,
    json_name: "supervisorMiddlewareServices"

  field :workspace, 10, type: :string

  field :policy_validation_failure_mode, 11,
    type: :string,
    json_name: "policyValidationFailureMode"

  field :extension_authentication_enabled, 12,
    type: :bool,
    json_name: "extensionAuthenticationEnabled"

  field :provider_attachment_epoch, 14, type: :string, json_name: "providerAttachmentEpoch"
  field :configuration_admitted, 13, type: :bool, json_name: "configurationAdmitted"
  field :configuration_error, 16, type: :string, json_name: "configurationError"
  field :configuration_instance_id, 15, type: :string, json_name: "configurationInstanceId"
  field :settings_revision, 17, type: :uint64, json_name: "settingsRevision"

  field :service_routes, 18,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxServiceRoute,
    json_name: "serviceRoutes"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SandboxServiceRoute do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SandboxServiceRoute",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :endpoint_id, 1, type: :string, json_name: "endpointId"
  field :name, 2, type: :string
  field :target_port, 3, type: :uint32, json_name: "targetPort"
  field :authorization_mode, 4, type: :int32, json_name: "authorizationMode"
  field :resource_version, 5, type: :uint64, json_name: "resourceVersion"
end

defmodule HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareService do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.sandbox.v1.SupervisorMiddlewareService",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :grpc_endpoint, 2, type: :string, json_name: "grpcEndpoint"
  field :max_payload_bytes, 3, type: :uint64, json_name: "maxPayloadBytes"
  field :request_timeout, 104, type: Google.Protobuf.Duration, json_name: "requestTimeout"
  field :tls_ca_cert_pem, 5, type: :bytes, json_name: "tlsCaCertPem"
  field :audience, 6, type: :string
  field :allow_insecure_transport, 7, type: :bool, json_name: "allowInsecureTransport"

  field :binding_policy, 8,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareBindingPolicy,
    json_name: "bindingPolicy",
    enum: true

  field :bindings, 9,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Sandbox.V1.SupervisorMiddlewareBinding,
    enum: true
end
