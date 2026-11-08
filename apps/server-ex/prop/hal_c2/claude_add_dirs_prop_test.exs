defmodule HalC2.ClaudeAddDirsPropTest do
  @moduledoc """
  The folders Claude's launch arguments add (`HalC2.Claude.Provider.add_dirs/1`):
  however `--add-dir` is spelled — variadic, repeated, or with `=` — and whatever
  other flags sit between the groups, the folders come out in the order the
  arguments named them, and no other argument is read as a folder.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Claude.Provider

  @dirs ~w(/work/apps /work/lib tools ./shared /work/project\  ../up)
  @noise ~w(--verbose --strict-mcp-config --thinking-display=summarized)

  property "every --add-dir spelling yields its folders in order" do
    forall groups <-
             list({oneof([:variadic, :repeated, :equals]), non_empty(list(elements(@dirs)))}) do
      {args, expected} =
        Enum.reduce(groups, {[], []}, fn {spelling, dirs}, {args, expected} ->
          noise = Enum.take_random(@noise, rem(length(args), 2))

          segment =
            case spelling do
              :variadic -> ["--add-dir" | dirs]
              :repeated -> Enum.flat_map(dirs, &["--add-dir", &1])
              :equals -> Enum.map(dirs, &"--add-dir=#{&1}")
            end

          {args ++ noise ++ segment, expected ++ dirs}
        end)

      Provider.add_dirs(args) == expected
    end
  end

  property "arguments that never name --add-dir add no folder" do
    forall args <- list(elements(@noise ++ @dirs)) do
      Provider.add_dirs(args) == []
    end
  end
end
