defmodule HalC2.OpenShell.Proto.Openshell.Options.V1.AuthorizationRule do
  @moduledoc false

  use Protobuf,
    full_name: "openshell.options.v1.AuthorizationRule",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :auth_mode, 1, type: :string, json_name: "authMode"
  field :workspace_role, 2, type: :string, json_name: "workspaceRole"
  field :global_role, 3, type: :string, json_name: "globalRole"
  field :scope, 4, type: :string
end
