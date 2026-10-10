import "vite-plus/test/config";
import { defineConfig } from "vite-plus";
import * as NodeURL from "node:url";

/** Import restrictions every file keeps. */
const RESTRICTED_IMPORT_PATHS = [
  {
    name: "@hal-c2/client-runtime",
    message:
      "Import from an explicit @hal-c2/client-runtime/* subpath. The package has no root export.",
  },
];

export default defineConfig({
  test: {
    environment: "node",
    exclude: [
      "**/.repos/**",
      "**/.hal-c2/**",
      "**/node_modules/**",
      "**/dist/**",
      "**/.{idea,git,cache,output,temp}/**",
    ],
    hookTimeout: 60_000,
    testTimeout: 60_000,
    setupFiles: [
      NodeURL.fileURLToPath(
        new URL("./packages/shared/src/testing/longTempDir.ts", import.meta.url),
      ),
    ],
  },
  staged: {
    // Formatter only for now — no lint or typecheck on commit.
    "*": "vp fmt --no-error-on-unmatched-pattern",
  },
  fmt: {
    ignorePatterns: [
      ".repos/**",
      // Macroscope's glob-per-line ignore grammar, not Markdown: formatting
      // it rewrites `*` as `_` and joins lines.
      ".macroscope/ignore.md",
      ".alchemy",
      "dist",
      "node_modules",
      "pnpm-lock.yaml",
      "*.tsbuildinfo",
      // Generated QML-dialect JS (`.pragma library`), see scripts/gen-icons.mjs.
      "apps/desktop-qt/qml/HalC2/Bricks/js/lucide.js",
      // QML-dialect JS (`.pragma library`) the formatter cannot parse.
      "apps/desktop-qt/qml/HalC2/Bricks/js/modelPicker.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/panelTabs.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/terminalLinks.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/providerIcons.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/settingsPages.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/settingsRows.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/centreViews.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/changedFilesTree.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/scheduledTasks.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/markdown.js",
      "apps/desktop-qt/qml/HalC2/Bricks/js/usageChart.js",
      // Exported Lottie animation, kept as the tool wrote it.
      "apps/desktop-qt/examples/dashboard/cat-playing.json",
      "*.icon/**",
    ],
    sortPackageJson: {},
    overrides: [
      {
        files: [".devcontainer/devcontainer.json"],
        options: {
          trailingComma: "none",
        },
      },
    ],
  },
  lint: {
    ignorePatterns: [
      ".repos",
      ".repos/**",
      "dist",
      "node_modules",
      "pnpm-lock.yaml",
      "*.tsbuildinfo",
      // QML-dialect JS (`.pragma library`) the parser cannot read.
      "apps/desktop-qt/qml/HalC2/Bricks/js/**",
    ],
    plugins: ["eslint", "oxc", "react", "unicorn", "typescript"],
    jsPlugins: ["./oxlint-plugin-hal-c2/index.ts"],
    categories: {
      correctness: "warn",
      suspicious: "warn",
      perf: "warn",
    },
    rules: {
      "unicorn/no-array-sort": "off",
      "unicorn/consistent-function-scoping": "off",
      "oxc/no-map-spread": "off",
      "react-in-jsx-scope": "off",
      "react-hooks/exhaustive-deps": "off",
      "eslint/no-shadow": "off",
      "eslint/no-await-in-loop": "off",
      "eslint/no-underscore-dangle": "off",
      "typescript/consistent-return": "off",
      "typescript/no-base-to-string": "off",
      "typescript/no-duplicate-type-constituents": "off",
      "typescript/no-floating-promises": "off",
      "typescript/no-implied-eval": "off",
      "typescript/no-meaningless-void-operator": "off",
      "typescript/no-redundant-type-constituents": "off",
      "typescript/no-unnecessary-boolean-literal-compare": "off",
      "typescript/no-unnecessary-type-conversion": "off",
      "typescript/no-unnecessary-type-arguments": "off",
      "typescript/no-unnecessary-type-assertion": "off",
      "typescript/no-unnecessary-type-parameters": "off",
      "typescript/no-unsafe-type-assertion": "off",
      "typescript/await-thenable": "off",
      "typescript/require-array-sort-compare": "off",
      "typescript/restrict-template-expressions": "off",
      "typescript/unbound-method": "off",
      "eslint/no-restricted-imports": ["error", { paths: RESTRICTED_IMPORT_PATHS }],
      "hal-c2/no-global-process-runtime": "error",
      "hal-c2/no-inline-schema-compile": "warn",
      "hal-c2/no-manual-effect-runtime-in-tests": "error",
      "hal-c2/namespace-node-imports": "error",
    },
    overrides: [
      {
        // The one place that reads the host platform to seed the injected references.
        files: ["packages/shared/src/hostProcess.ts"],
        rules: { "hal-c2/no-global-process-runtime": "off" },
      },
    ],
    options: {
      reportUnusedDisableDirectives: "error",
      // Revisit once Oxlint's tsgolint path can integrate with @effect/tsgo diagnostics.
      typeAware: false,
      typeCheck: false,
    },
  },
});
