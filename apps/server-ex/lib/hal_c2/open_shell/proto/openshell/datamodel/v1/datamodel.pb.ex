defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspacePhase do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "openshell.datamodel.v1.WorkspacePhase",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :WORKSPACE_PHASE_UNSPECIFIED, 0
  field :WORKSPACE_PHASE_ACTIVE, 1
  field :WORKSPACE_PHASE_TERMINATING, 2
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceSelector do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.WorkspaceSelector",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof :selection, 0

  field :workspace, 1, type: :string, oneof: 0

  field :all_workspaces, 2,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.AllWorkspaces,
    json_name: "allWorkspaces",
    oneof: 0
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.AllWorkspaces do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.AllWorkspaces",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.ObjectMeta.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.ObjectMeta.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.ObjectMeta",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :id, 1, type: :string
  field :name, 2, type: :string
  field :created_time, 103, type: Google.Protobuf.Timestamp, json_name: "createdTime"

  field :labels, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta.LabelsEntry,
    map: true

  field :resource_version, 5, type: :uint64, json_name: "resourceVersion"

  field :annotations, 6,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta.AnnotationsEntry,
    map: true

  field :workspace, 7, type: :string
  field :deletion_time, 108, type: Google.Protobuf.Timestamp, json_name: "deletionTime"
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceStatus do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.WorkspaceStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :phase, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspacePhase, enum: true
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Workspace do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.Workspace",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :status, 2, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.WorkspaceStatus
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.CredentialHandle.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.CredentialHandle.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.CredentialHandle do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.CredentialHandle",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :driver, 1, type: :string
  field :handle, 2, type: :string

  field :metadata, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.CredentialHandle.MetadataEntry,
    map: true
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.CredentialsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.Provider.CredentialsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.ConfigEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.Provider.ConfigEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.CredentialExpirationTimesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.Provider.CredentialExpirationTimesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Google.Protobuf.Timestamp
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.CredentialHandlesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.Provider.CredentialHandlesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.CredentialHandle
end

defmodule HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.datamodel.v1.Provider",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :metadata, 1, type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  field :type, 2, type: :string

  field :credentials, 3,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.CredentialsEntry,
    map: true,
    deprecated: false

  field :config, 4,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.ConfigEntry,
    map: true

  field :credential_expiration_times, 105,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.CredentialExpirationTimesEntry,
    json_name: "credentialExpirationTimes",
    map: true

  field :profile_workspace, 6, type: :string, json_name: "profileWorkspace"

  field :credential_handles, 7,
    repeated: true,
    type: HalC2.OpenShell.Proto.Openshell.Datamodel.V1.Provider.CredentialHandlesEntry,
    json_name: "credentialHandles",
    map: true
end
