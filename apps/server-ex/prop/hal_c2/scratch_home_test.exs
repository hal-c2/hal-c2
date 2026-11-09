defmodule HalC2.ScratchHomeTest do
  @moduledoc """
  A scratch home sits inside the checkout, and git finds the checkout from it unless told
  not to; a git action under test would then commit and push the developer's work.
  """

  use ExUnit.Case, async: false

  alias HalC2.Vcs

  test "a scratch home is no git repository, though the checkout around it is one" do
    home = HalC2.Prop.scratch_home("scratch-home")
    refute Vcs.local_status(home)["isRepo"]
  end

  test "a scratch repository is its own repository, with its origin inside the scratch home" do
    {home, repo} = HalC2.Prop.scratch_repo("scratch-repo")
    assert Vcs.local_status(repo)["isRepo"]

    {top, 0} = System.cmd("git", ~w(rev-parse --show-toplevel), cd: repo)
    assert String.trim(top) == repo
    {origin, 0} = System.cmd("git", ~w(remote get-url origin), cd: repo)
    assert String.trim(origin) == Path.join(home, "origin.git")
  end
end
