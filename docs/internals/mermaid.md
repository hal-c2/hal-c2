# Mermaid diagrams

The MC draws every Mermaid diagram a client shows: a `mermaid` code block in a page or a
reply, and a Markdown or `.mmd` file in the file viewer. A client sends the source to
`mermaid.render` and shows what comes back: an SVG on the desktop and the phone, text in
the terminal, or the reason there is no drawing. The service is
[`HalC2.Mermaid`](../../apps/server-ex/lib/hal_c2/mermaid.ex); the drawing is done by a
small Rust program, [`native/mermaid`](../../native/mermaid/src/main.rs), which the MC
runs once per diagram it has not drawn before.

## Why the MC draws them

- **One renderer.** Pages, replies and files on three clients must show the same
  picture and fail with the same reason. A renderer per client means three
  implementations to keep in step, in C++/QML (twice, with Android's toolchain) and
  in TypeScript.
- **No browser.** Mermaid's own renderer is JavaScript that measures text in a DOM. A
  headless browser or WebEngine is too heavy for any client, and the desktop takes no
  new TypeScript or Node.
- **Remote ready.** An SVG crosses LAN and Tailscale like any other reply. The MC keeps
  each result by the hash of its source, format and theme, and clients keep what they
  were sent, so a diagram is drawn and sent once, not on every scroll or reconnect.

Writing a Mermaid parser and layout in QML was the third option; it would be the
largest of the three and the one with the fewest diagram types.

## The renderer

[mermaid-rs-renderer](https://github.com/1jehuang/mermaid-rs-renderer) (mmdr) draws
the SVGs and [mmdflux](https://github.com/kevinswiber/mmdflux) the terminal text. Both
are pure Rust and MIT. mmdr draws more types and draws them better; mmdflux has a
strict parser that says on which line and column a mistake is, where mmdr reads a broken
flowchart leniently and drops what it could not read, so flowcharts are checked by
mmdflux before mmdr draws them.

The program allows only the types checked to draw legibly. block-beta is not one: mmdr
loses its column spans, so it answers that the type cannot be drawn yet rather than
drawing it wrong.

## Traps

- **Qt's SVG renderer is SVG Tiny 1.2.** It draws `hsl()` colours black and runs the
  lines of a multi-line label together, ignoring a `<tspan>`'s `x` and `dy`. The program
  writes hex colours and one `<text>` per line, so the same SVG draws in QtSvg and in
  Ljós (resvg). Flattening text to paths would avoid the second, at ten times the bytes.
- **Fonts.** mmdr measures text with the machine's fonts and keeps the face it chose
  under `XDG_CACHE_HOME/mmdr`. The MC points that at its own cache directory; the
  first drawing on a machine scans the fonts and takes seconds, later ones tens of
  milliseconds. A client lays the SVG out with its own fonts, so a label can sit a
  little off-centre where those differ.
- **Failures are not kept.** A missing helper, a crash or a drawing past the time limit
  answers `failed` and the next caller tries again; what the program said about a
  source, including a mistake, is kept.
