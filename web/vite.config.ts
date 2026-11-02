import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * Dev-only wiring to the Swift sidecar.
 *
 * WHY A PROXY AND NOT A DIRECT fetch — this is the one non-obvious fact about
 * browser mode. The v3 server has **zero CORS**: no Access-Control-* headers, no
 * Origin handling (v4/recon/server-contract.md §9 measured exactly this). A page
 * served from 127.0.0.1:5173 that calls http://127.0.0.1:52728/api/... is a
 * cross-origin request, so the browser will send it and then refuse to let the
 * page read the answer. docs/ipc-contract.md §5 describes browser mode as a
 * direct fetch with VITE_SIDECAR_TOKEN; that cannot work against this server, and
 * the alternative fix (adding CORS to the Swift server) would mean editing v1,
 * which is forbidden.
 *
 * So browser mode goes through Vite's dev proxy:
 *
 *     page  ->  /api/...          (same origin, no CORS involved)
 *     proxy ->  http://127.0.0.1:<port>/api/...   + Authorization: Bearer <token>
 *
 * Two things fall out of this, both good:
 *   - the token never reaches the browser at all (not in JS, not in memory, not
 *     in localStorage) — a stronger guarantee than the contract asked for;
 *   - the release path is unchanged: Tauri mode never uses any of this.
 *
 * The token is read once at config load from v4/.dev/web.env (written by
 * v4/scripts/sidecar-dev.sh). Restarting the sidecar rewrites that file with a
 * new port, so restart the dev server too — the page prints the URL it expects.
 */
// Default: the developer's v4/.dev sidecar. LAGOON_WEB_ENV points the same dev
// server at another env file — used by scripts/synth-sidecar.sh to drive the
// write UI against a seeded synthetic store (README "写路径怎么验").
// LAGOON_WEB_ENV is interpreted relative to the REPOSITORY ROOT (not to v4/web,
// and not to the shell's cwd, which npm sets to the package directory).
const repoRoot = fileURLToPath(new URL("../../", import.meta.url));
const DEV_ENV_FILE = process.env.LAGOON_WEB_ENV
  ? repoRoot + process.env.LAGOON_WEB_ENV
  : fileURLToPath(new URL("../.dev/web.env", import.meta.url));
const VIRTUAL_ID = "virtual:sidecar-env";
const RESOLVED_VIRTUAL_ID = "\u0000" + VIRTUAL_ID;

function parseEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return out;
}

function readDevEnv(): { url: string; token: string } {
  if (!existsSync(DEV_ENV_FILE)) return { url: "", token: "" };
  const env = parseEnvFile(readFileSync(DEV_ENV_FILE, "utf8"));
  return { url: env.VITE_SIDECAR_URL ?? "", token: env.VITE_SIDECAR_TOKEN ?? "" };
}

export function sidecarEnvPlugin(url: string, hasToken: boolean): Plugin {
  return {
    name: "lagoon-sidecar-env",
    resolveId(id) {
      return id === VIRTUAL_ID ? RESOLVED_VIRTUAL_ID : null;
    },
    load(id) {
      if (id !== RESOLVED_VIRTUAL_ID) return null;
      // The client only needs to *describe* the transport (boot diagnostics).
      // It never receives the token, and in a production build it receives
      // nothing at all: release mode is the Tauri IPC proxy.
      return [
        "export const sidecarUrl = " + JSON.stringify(url) + ";",
        "export const hasSidecar = " + JSON.stringify(url.length > 0 && hasToken) + ";",
        "export const sidecarEnvSource = " + JSON.stringify(url ? "web.env" : "none") + ";",
      ].join("\n");
    },
  };
}

export default defineConfig(({ command }) => {
  // Builds must not read the dev credentials at all: the release path is the
  // Tauri IPC proxy, and a shipped bundle should not even know which port the
  // developer's sidecar was on.
  const dev = command === "serve" ? readDevEnv() : { url: "", token: "" };
  const proxyTarget = dev.url || undefined;
  const proxyHeaders: Record<string, string> = dev.token
    ? { Authorization: "Bearer " + dev.token }
    : {};

  return {
  plugins: [react(), sidecarEnvPlugin(dev.url, dev.token.length > 0)],
  server: {
    port: 5173,
    // Loopback only: the proxy target is loopback, and a token-bearing dev
    // server on a LAN interface is a token-bearing dev server on a LAN interface.
    host: "127.0.0.1",
    strictPort: false,
    proxy: proxyTarget
      ? {
          "/api": {
            target: proxyTarget,
            changeOrigin: true,
            headers: proxyHeaders,
          },
          "/healthz": {
            target: proxyTarget,
            changeOrigin: true,
            headers: proxyHeaders,
          },
        }
      : undefined,
  },
  preview: { port: 4173 },
  build: { outDir: "dist", sourcemap: false },
  };
});
