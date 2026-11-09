defmodule HalC2.OpenShell.Proto.Openshell.Options.V1.PbExtension do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.17.1"

  extend Google.Protobuf.MethodOptions, :authorization, 50000,
    optional: true,
    type: HalC2.OpenShell.Proto.Openshell.Options.V1.AuthorizationRule

  extend Google.Protobuf.FieldOptions, :secret, 50001, optional: true, type: :bool
end
