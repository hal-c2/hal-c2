# Vendored crates

## mermaid-rs-renderer

[mermaid-rs-renderer](https://github.com/1jehuang/mermaid-rs-renderer) (mmdr) 0.3.1 as
published on crates.io (upstream commit `2f993bd79a55235eb59a34d807852276ba25bea7`), MIT
(`mermaid-rs-renderer/LICENSE`). `../Cargo.toml` swaps it in with `[patch.crates-io]`.

Only `src/`, `LICENSE` and `Cargo.toml` are kept. The manifest drops the published
examples, tests and benches, which are not vendored, and the release profile, which only a
workspace root may set.

Our changes on top of 0.3.1, each meant for upstream:

- `src/layout/label_placement.rs`: state diagram edge labels are no longer pinned where
  routing seeded them when that seed overlaps a label already placed, or covers its own
  self-loop, and they may grow the canvas like flowchart labels instead of being clamped
  into it.
- `src/layout/flowchart/subgraph_spacing.rs`: a node that belongs to a subgraph but not to
  a subgraph nested inside it is moved out of the nested box (before, only nodes in no
  subgraph were), and the move steps past other nodes instead of landing on them.

`git log -p -- native/mermaid/vendor` shows the diff. Drop the vendored copy and the patch
once a release carries these fixes.
