import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://hal-c2.example",
  server: {
    port: Number(process.env.PORT ?? 4173),
  },
});
