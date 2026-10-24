defmodule HalC2.PullRequests.OpenedTest do
  use ExUnit.Case, async: true

  alias HalC2.PullRequests.Opened

  @url "https://github.com/acme/shop/pull/43"

  test "a create command's pull request is the address it printed on a line of its own" do
    printed = "\nCreating pull request for feature/tax into main in acme/shop\n\n#{@url}\n"

    for input <- [
          "gh pr create --fill",
          "git push -u origin HEAD && gh pr create --title Tax --body ''",
          "bash -lc 'gh pr new --draft'",
          "glab mr create --fill",
          "tea pulls create --head feature/tax",
          "hub pull-request -m Tax"
        ],
        do: assert(Opened.urls(input, printed) == [@url], input)

    # Coloured, with Windows line ends, printed twice, and the one already open.
    assert Opened.urls("gh pr create", "\e[0;32m#{@url}\e[0m\r\n#{@url}\r\n") == [@url]

    assert Opened.urls(
             "gh pr create",
             "a pull request for branch \"feature/tax\" into branch \"main\" already exists:\n#{@url}\n"
           ) == [@url]
  end

  test "a command that only reads pull requests, or mentions one in passing, gives none" do
    for input <- [
          "gh pr view 43",
          "gh pr list --json url",
          "gh pr checks 43",
          "echo gh pr creates"
        ],
        do: assert(Opened.urls(input, "#{@url}\n") == [], input)

    assert Opened.urls("gh pr create", "see #{@url} for the old one\n") == []
    assert Opened.urls("gh pr create", "https://github.com/acme/shop/issues/43\n") == []
    assert Opened.urls(nil, @url) == []
  end
end
