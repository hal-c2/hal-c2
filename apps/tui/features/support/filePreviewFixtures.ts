// Files the viewer shows rendered (files/file-viewer-and-editing.feature):
// their contents, words only the rendering shows as written, and text only
// the source has.
export interface PreviewFile {
  readonly contents: string;
  /** On screen while rendered. */
  readonly rendered: ReadonlyArray<string>;
  /** On screen only while the source is shown. */
  readonly source: ReadonlyArray<string>;
}

export const PREVIEW_FILES: Record<string, PreviewFile> = {
  "README.md": {
    contents: "# shop\n\nA **small** storefront.\n\n- carts\n- checkout\n",
    rendered: ["shop", "A small storefront."],
    source: ["# shop", "A **small** storefront."],
  },
  "data/orders.csv": {
    contents: 'id,customer,total\n1,"Lovelace, Ada",40\n2,Grace Hopper,15\n',
    rendered: ["├──", "│Lovelace, Ada "],
    source: ['1,"Lovelace, Ada",40'],
  },
  "public/index.html": {
    contents:
      "<!doctype html>\n<html>\n  <head><title>Shop</title><style>p { color: red }</style></head>\n  <body>\n    <h1>Welcome to the shop</h1>\n    <p>Fresh <b>carts</b> daily.</p>\n  </body>\n</html>\n",
    rendered: ["Welcome to the shop", "Fresh carts daily."],
    source: ["<h1>Welcome to the shop</h1>", "<p>Fresh <b>carts</b> daily.</p>"],
  },
};
