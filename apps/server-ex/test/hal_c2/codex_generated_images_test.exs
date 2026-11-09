defmodule HalC2.CodexGeneratedImagesTest do
  # Upstream T3 Code's cases for the embeds a Codex reply gains for its
  # generated images (pingdotgg/t3code#19066).
  use ExUnit.Case, async: true

  alias HalC2.Codex.GeneratedImages

  defp append(text, paths) do
    result = GeneratedImages.append_embeds(text, paths)
    # Appending again changes nothing, so a late image can resend them all.
    assert GeneratedImages.append_embeds(result, paths) == result
    result
  end

  test "each saved image is appended once, in order" do
    assert append("Done.", ["/tmp/a.png", "/tmp/b.png", "/tmp/a.png"]) ==
             "Done.\n\n![](</tmp/a.png>)\n\n![](</tmp/b.png>)"
  end

  test "an image the reply already shows is not appended, however it is written" do
    text =
      String.trim_trailing(
        ~S"""
        ![A](</tmp/a b.png>) ![B](c:\Users\me\.codex\b.png) ![C][a\*b] ![D][unc]

        [a\*b]: c:\Users\me\.codex\c.png
        [unc]: <\\HOST\Share\d.png>

        ![E](file://host/share/e.png)
        """,
        "\n"
      )

    saved = [
      "/tmp/a b.png",
      ~S"C:\Users\Me\.codex\b.png",
      ~S"C:\Users\Me\.codex\c.png",
      ~S"\\host\share\d.png",
      ~S"\\HOST\SHARE\e.png",
      "/tmp/C.png"
    ]

    assert append(text, saved) == text <> "\n\n![](</tmp/C.png>)"
  end

  test "a link, inline code, a fence or an escaped image does not count as shown" do
    text =
      "[open](/tmp/a.png) `![](/tmp/a.png)`\n\n```md\n![](/tmp/a.png)\n```\n\\![](/tmp/a.png)"

    assert append(text, ["/tmp/a.png"]) == text <> "\n\n![](</tmp/a.png>)"
  end

  test "an unclosed fence, comment or raw HTML block is closed before the images" do
    assert append("Created.\n\n~~~js\nconsole.log(\"done\");", ["/tmp/a.png"]) ==
             "Created.\n\n~~~js\nconsole.log(\"done\");\n~~~\n\n![](</tmp/a.png>)"

    assert append("<!--\n![](</tmp/a.png>)", ["/tmp/a.png"]) ==
             "<!--\n![](</tmp/a.png>)\n-->\n\n![](</tmp/a.png>)"

    assert append("<pre>\nlog", ["/tmp/a.png"]) == "<pre>\nlog\n</pre>\n\n![](</tmp/a.png>)"
  end

  test "Windows paths and markdown's own characters are written portably" do
    assert append("", [
             ~S"C:\Users\me\a b#1.png",
             ~S"\\host\share\a.png",
             "/tmp/a#b?100%25&copy;\\!\n<x>.png"
           ]) ==
             "![](<C:/Users/me/a b%231.png>)\n\n![](<file://host/share/a.png>)\n\n" <>
               "![](</tmp/a%23b%3F100%2525%26copy;%5C!%0A\\<x\\>.png>)"
  end

  test "an embed's destination reads back as the path Codex saved" do
    for path <- [
          ~S"C:\Users\ana\.codex\images\fox.png",
          ~S"\\fileserver\share\images\fox.png",
          "/home/ana/.codex/a#b?100%25&copy;\\!\n<x>.png"
        ] do
      assert [_, destination] = Regex.run(~r/\A!\[\]\((.*)\)\z/s, GeneratedImages.embed(path))
      assert GeneratedImages.host_path(destination) == path
    end
  end
end
