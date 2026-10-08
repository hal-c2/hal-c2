defmodule HalC2.PatchPropTest do
  @moduledoc """
  The laws of `HalC2.Patch`: composing two patches is applying them in turn, composition
  is associative, a diff leads from its start to its end, and the empty patch is the
  identity. The module holds no state, so these are plain `forall`s.
  """

  use ExUnit.Case, async: true
  use PropCheck

  import HalC2.Prop.PatchGenerators, only: [patch_raw: 0, update_raw: 0, valid_patch: 2]

  alias HalC2.Patch
  alias HalC2.Prop.Generators

  property "applying a composed patch is applying the two in turn",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall {e, r1, r2} <- {Generators.entity(), patch_raw(), patch_raw()} do
      {[p1, p2], e2} = chain(e, [r1, r2])
      Patch.apply(e, Patch.compose(p1, p2)) == e2
    end
  end

  property "composition is associative under apply",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall {e, r1, r2, r3} <-
             {Generators.entity(), patch_raw(), patch_raw(), patch_raw()} do
      {[p1, p2, p3], e3} = chain(e, [r1, r2, r3])
      left = Patch.compose(Patch.compose(p1, p2), p3)
      right = Patch.compose(p1, Patch.compose(p2, p3))

      Patch.apply(e, left) == Patch.apply(e, right) and Patch.apply(e, left) == e3
    end
  end

  property "a diff leads from its start to its end",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall e1 <- Generators.entity() do
      forall e2 <- Generators.entity() do
        Patch.apply(e1, no_op_or(Patch.diff(e1, e2))) == e2
      end
    end
  end

  property "a diff from an edited entity leads to the edit",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall e1 <- Generators.entity() do
      forall r <- update_raw() do
        e2 = Patch.apply(e1, valid_patch(e1, r))
        Patch.apply(e1, no_op_or(Patch.diff(e1, e2))) == e2
      end
    end
  end

  property "diffing an entity against itself is a no-op",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall e <- Generators.entity() do
      Patch.diff(e, e) == :unchanged and Patch.apply(e, %{}) == e
    end
  end

  property "the empty patch is an identity for compose on both sides",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall e <- Generators.entity() do
      forall r <- patch_raw() do
        p = valid_patch(e, r)
        expected = Patch.apply(e, p)
        left = Patch.compose(%{}, p)
        right = Patch.compose(p, %{})

        Patch.apply(e, left) == expected and Patch.apply(e, right) == expected and
          Map.get(left, "q") == Map.get(p, "q") and Map.get(right, "q") == Map.get(p, "q")
      end
    end
  end

  # Applies `p1`'s and `p2`'s chain from `e`, returning the patches and the final entity.
  defp chain(e, raws) do
    {patches, final} =
      Enum.map_reduce(raws, e, fn raw, current ->
        patch = valid_patch(current, raw)
        {patch, Patch.apply(current, patch)}
      end)

    {patches, final}
  end

  # `diff/2` says `:unchanged` for identical entities; applying nothing is the same thing.
  defp no_op_or(:unchanged), do: %{}
  defp no_op_or(patch), do: patch
end
