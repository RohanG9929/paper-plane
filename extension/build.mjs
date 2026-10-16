// Builds the extension into dist/, the folder Chrome and Brave load
// (chrome://extensions → Developer mode → Load unpacked).
import { build } from "esbuild";
import { cp, rm } from "node:fs/promises";

await rm("dist", { recursive: true, force: true });
const common = { bundle: true, target: "chrome116", outdir: "dist", logLevel: "warning", legalComments: "none" };
// The service worker and the popup are modules; a content script can't be one.
await build({ ...common, entryPoints: ["src/background.ts", "src/popup.ts"], format: "esm" });
await build({ ...common, entryPoints: ["src/content.ts"], format: "iife" });
await cp("static", "dist", { recursive: true });
