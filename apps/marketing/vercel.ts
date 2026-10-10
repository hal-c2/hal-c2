import type { VercelConfig } from "@vercel/config/v1";

export const config: VercelConfig = {
  git: {
    deploymentEnabled: false,
  },
  installCommand: "npm install -g vite-plus && vp install --filter '@hal-c2/marketing...'",
  buildCommand: "vp run --filter @hal-c2/marketing build",
  outputDirectory: "dist",
};
