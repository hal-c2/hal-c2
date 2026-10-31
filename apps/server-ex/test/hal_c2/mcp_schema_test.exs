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

  test "a discriminator property picks the object branch whose bounds apply" do
    schema = %{
      "anyOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "enum" => ["interval"]},
            "everyMs" => %{"type" => "integer", "minimum" => 60_000}
          },
          "additionalProperties" => true
        },
        %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "enum" => ["fixed_time"]},
            "weekdays" => %{
              "type" => "array",
              "items" => %{"type" => "integer", "minimum" => 0, "maximum" => 6}
            }
          },
          "additionalProperties" => true
        }
      ]
    }

    assert Schema.validate(schema, %{"type" => "interval", "everyMs" => 60_000}) == :ok
    assert {:error, _} = Schema.validate(schema, %{"type" => "interval", "everyMs" => 1_000})
    assert Schema.validate(schema, %{"type" => "fixed_time", "weekdays" => [1]}) == :ok
    assert {:error, _} = Schema.validate(schema, %{"type" => "fixed_time", "weekdays" => [9]})
  end

  test "the advertised schedule_task schema refuses a sub-minute interval" do
    %{"inputSchema" => schema} =
      Enum.find(HalC2.Mcp.Tools.list(), &(&1["name"] == "schedule_task"))

    good = %{"prompt" => "x", "schedule" => %{"type" => "interval", "everyMs" => 3_600_000}}
    bad = %{"prompt" => "x", "schedule" => %{"type" => "interval", "everyMs" => 1_000}}

    assert Schema.validate(schema, good) == :ok
    assert {:error, _} = Schema.validate(schema, bad)
  end

  test "every advertised tool schema accepts its empty-arguments shape when nothing is required" do
    for %{"name" => name, "inputSchema" => schema} <- HalC2.Mcp.Tools.list(),
        (schema["required"] || []) == [] do
      assert Schema.validate(schema, %{}) == :ok, "#{name} should accept %{}"
    end
  end
end
