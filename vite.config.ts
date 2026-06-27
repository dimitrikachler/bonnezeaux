import { defineConfig } from "vite";

// GitHub Pages serves a project site from /<repo>/, so Vite needs that as its
// base or every asset 404s. GITHUB_REPOSITORY is "owner/repo" in the Actions
// build; locally it's unset -> base "/". Do not hardcode the repo name.
const repo = process.env.GITHUB_REPOSITORY?.split("/")[1];
const base = repo ? `/${repo}/` : "/";

export default defineConfig({
  base,
  server: { host: true },
});
