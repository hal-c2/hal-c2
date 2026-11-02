import { describe, expect, it } from "bun:test";

import { thoughtPreview } from "./thoughtPreview.ts";

describe("thoughtPreview", () => {
  it("is the reasoning's words, on one line", () => {
    expect(thoughtPreview("The cart total needs\n\na tax line.", "Thought")).toBe(
      "The cart total needs a tax line.",
    );
  });

  it("drops Markdown and reads a picture as its description", () => {
    expect(
      thoughtPreview("## **Checking** the `cart` total\n\n![a chart](chart.png)", "Thought"),
    ).toBe("Checking the cart total a chart");
  });

  it("keeps a link's text and a list's items, and drops HTML", () => {
    expect(
      thoughtPreview(
        "- read [the docs](https://x.test)\n- <b>run</b> _tests_\n> quoted",
        "Thought",
      ),
    ).toBe("read the docs run tests quoted");
  });

  it("keeps fenced code but not its fences", () => {
    expect(thoughtPreview("Try:\n```sh\nbun test\n```", "Thought")).toBe("Try: bun test");
  });

  it("leaves snake_case and code spans alone", () => {
    expect(thoughtPreview("Checking `user_id_map` in my_module_name", "Thought")).toBe(
      "Checking user_id_map in my_module_name",
    );
    expect(thoughtPreview("It is _done_ and __done__", "Thought")).toBe("It is done and done");
    expect(thoughtPreview("Use `a*b*c` or `**kwargs`", "Thought")).toBe("Use a*b*c or **kwargs");
    expect(thoughtPreview("Quote ``a`b`` here", "Thought")).toBe("Quote a`b here");
  });

  it("falls back when there are no words", () => {
    expect(thoughtPreview("  \n<br>\n", "Thought")).toBe("Thought");
    expect(thoughtPreview("", "Thought")).toBe("Thought");
  });
});
