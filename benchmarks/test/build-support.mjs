import { build } from "esbuild";
// Deterministic concurrency barriers invoke unchanged production functions with real local bindings.
// Worker Queue delivery and API behavior are independently exercised in the other runtime tests.
await build({
  entryPoints: [
    "src/jobs.ts",
    "src/validation.ts",
    "src/sessions.ts",
    "src/objects.ts",
  ],
  outdir: "dist/support",
  outExtension: { ".js": ".mjs" },
  bundle: true,
  platform: "node",
  format: "esm",
});
