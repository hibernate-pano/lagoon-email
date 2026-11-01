/// <reference types="vite/client" />

declare module "virtual:sidecar-env" {
  /** Base URL of the local sidecar, for the boot screen's diagnostics line. */
  export const sidecarUrl: string;
  /** True when the dev proxy has both a URL and a token. Never the token itself. */
  export const hasSidecar: boolean;
  /** Where the values came from, so the diagnostics line can say "none". */
  export const sidecarEnvSource: "web.env" | "none";
}

interface Window {
  /** Set by the Tauri 2 shell when running inside it (contract §4). */
  __TAURI_INTERNALS__?: unknown;
}
