defmodule HalC2.Mcp.SchemaTest do
  use ExUnit.Case, async: true

  alias HalC2.Mcp.Schema

  @limit %{
    "type" => "object",
    "properties" => %{
      "limit" => %{
        "anyOf" => [
          %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          %{"type" => "null"}
        ]
      }
    },
    "additionalProperties" => true
  }

  test "accepts values inside the bounds, an omitted field and null" do
    assert Schema.validate(@limit, %{}) == :ok
    assert Schema.validate(@limit, %{"limit" => 20}) == :ok
    assert Schema.validate(@limit, %{"limit" => nil}) == :ok
  end

  test "refuses numbers outside the bounds" do
    assert {:error, message} = Schema.validate(@limit, %{"limit" => 0})
    assert message =~ "limit"
    assert {:error, _} = Schema.validate(@limit, %{"limit" => 101})
    # A value of a kind no branch names is the handler's to ignore or answer.
    assert Schema.validate(@limit, %{"limit" => "20"}) == :ok
    assert Schema.validate(@limit, %{"limit" => 2.5}) == :ok
  end

  test "checks arrays and string bounds, but not presence or vocabularies" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"type" => "string", "enum" => ["a", "b"]},
        "tags" => %{"type" => "array", "maxItems" => 2, "items" => %{"type" => "string"}},
        "text" => %{"type" => "string", "maxLength" => 3}
      },
      "required" => ["mode"],
      "additionalProperties" => false
    }

    assert Schema.validate(schema, %{"mode" => "a", "tags" => ["x"]}) == :ok
    # Omitted fields are the handler's business: several tools default them.
    assert Schema.validate(schema, %{}) == :ok
    assert Schema.validate(schema, %{"mode" => "a", "extra" => 1}) == :ok
    # A value outside an enum is the handler's to answer, in its own words.
    assert Schema.validate(schema, %{"mode" => "c"}) == :ok
    assert {:error, _} = Schema.validate(schema, %{"mode" => "a", "tags" => ["x", "y", "z"]})
    assert {:error, _} = Schema.validate(schema, %{"mode" => "a", "text" => "toolong"})
  end

  test "every advertised tool schema accepts its empty-arguments shape when nothing is required" do
    for %{"name" => name, "inputSchema" => schema} <- HalC2.Mcp.Tools.list(),
        (schema["required"] || []) == [] do
      assert Schema.validate(schema, %{}) == :ok, "#{name} should accept %{}"
    end
  end
end
