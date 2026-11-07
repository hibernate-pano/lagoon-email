#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Lagoon V4 desktop shell.
//!
//! Responsibilities, and nothing else (v4/docs/adr/0001-strangler-tauri-shell.md):
//! * own the sidecar lifecycle (start, health-check, restart once, kill on exit);
//! * be the only holder of the API token, and the only HTTP path to the server
//!   (v4/docs/ipc-contract.md §1);
//! * expose exactly three commands and one event, per the contract.

mod api;
mod backend;
mod download;
mod keys;
mod port;
mod selftest;
mod sidecar;
mod state;

use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tauri::{Manager, State};

use backend::Backend;
use state::{BootStatus, Shared};

/// Managed state handed to the Tauri commands.
pub struct AppState {
    pub shared: Arc<Shared>,
}

/// Contract §4.1.
#[tauri::command]
async fn boot_status(state: State<'_, AppState>) -> Result<BootStatus, String> {
    let status = state.shared.status();
    // Logged because it doubles as proof that the WebView really loaded and
    // ran our JavaScript: nothing else can call this command.
    eprintln!(
        "[ipc] boot_status -> phase={} port={:?}",
        status.phase.as_str(),
        status.port
    );
    Ok(status)
}

/// Contract §4.2.
#[tauri::command]
async fn api(state: State<'_, AppState>, request: Value) -> Result<api::ApiResponse, String> {
    match api::parse_request(request) {
        Ok(request) => Ok(api::forward(&state.shared, request).await),
        Err(response) => Ok(response),
    }
}

/// Contract §4.3. The restart is asynchronous: the reply says what the phase
/// is at reply time, and the `boot-status` event reports the transitions.
#[tauri::command]
async fn restart_sidecar(state: State<'_, AppState>) -> Result<Value, String> {
    let shared = state.shared.clone();
    tauri::async_runtime::spawn(async move { sidecar::restart(shared).await });
    Ok(serde_json::json!({ "ok": true, "phase": "starting" }))
}

/// Contract §4.5: the binary channel (attachment bytes).
#[tauri::command]
async fn download(
    state: State<'_, AppState>,
    request: Value,
) -> Result<download::DownloadResponse, String> {
    let parsed: download::DownloadRequest = match request.get("request") {
        Some(inner) => serde_json::from_value(inner.clone()),
        None => serde_json::from_value(request),
    }
    .map_err(|error| format!("invalid DownloadRequest: {error}"))?;
    Ok(download::run(&state.shared, parsed).await)
}

/// Whether a navigation leaves the app for the open web.
///
/// The app itself loads from `tauri://localhost`, and nothing else in the
/// window navigates: API calls go through the `api` command, not the document.
/// So an http(s) navigation can only come from a link inside a mail body.
fn leaves_the_app(url: &tauri::Url) -> bool {
    matches!(url.scheme(), "http" | "https")
}

/// Hand a mail link to the system browser.
///
/// The message iframe is sandboxed with no scripts, so a click is the only way
/// a link can produce a navigation — and navigating *inside* the app both kept
/// foreign content in the app's window and made the request from the app's
/// webview before the reader had actually decided to visit the site.
fn open_in_browser(url: &str) {
    if let Err(error) = std::process::Command::new("open").arg(url).spawn() {
        eprintln!("[ipc] could not open {url}: {error}");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // --backend / LAGOON_V4_BACKEND, default swift (contract v0.2 4.1).
    // An unknown value is a startup refusal: guessing a backend would mean
    // the UI silently talks to the wrong server.
    let backend = match Backend::from_args_and_env(&args) {
        Ok(backend) => backend,
        Err(message) => {
            eprintln!("[shell] {message}");
            std::process::exit(2);
        }
    };

    // Headless acceptance run: no window, no AppHandle, same code paths.
    // It deliberately ignores --backend and exercises every backend whose
    // binary is present, so one run proves both.
    if args.iter().any(|arg| arg == "--selftest") {
        let failures = selftest::run();
        std::process::exit(if failures == 0 { 0 } else { 1 });
    }

    sidecar::install_signal_handlers();

    eprintln!("[shell] backend={}", backend.as_str());
    let shared = Arc::new(Shared::new(backend));
    let setup_shared = shared.clone();

    tauri::Builder::default()
        // Mail links open in the reader's browser, never inside the app's
        // window. This hook fires for every frame of the webview, which is what
        // makes it the right place: the message body is an iframe, and the
        // sandbox that keeps scripts out does not stop the frame from
        // navigating itself. See leaves_the_app.
        .plugin(
            tauri::plugin::Builder::<tauri::Wry>::new("lagoon-navigation")
                .on_navigation(|_webview, url| {
                    if !leaves_the_app(url) {
                        return true;
                    }
                    open_in_browser(url.as_str());
                    false
                })
                .build(),
        )
        .manage(AppState {
            shared: shared.clone(),
        })
        .invoke_handler(tauri::generate_handler![
            boot_status,
            api,
            restart_sidecar,
            download
        ])
        .setup(move |app| {
            setup_shared.set_app(app.handle().clone());
            // Publish `starting` now that an emitter exists, so a front end
            // that subscribes during boot sees the event stream from the top.
            setup_shared.republish();
            let supervisor_shared = setup_shared.clone();
            tauri::async_runtime::spawn(async move { sidecar::supervise(supervisor_shared).await });
            Ok(())
        })
        .on_page_load(|_window, payload| {
            // Diagnostics only: names the URL the WebView actually loaded, and
            // whether the navigation finished. A window with no line at all is
            // a different failure from a loaded page whose JS never ran.
            eprintln!(
                "[ipc] page-load url={} event={:?}",
                payload.url(),
                payload.event()
            );
        })
        .build(tauri::generate_context!())
        .expect("failed to build the Lagoon V4 Tauri application")
        .run(|app_handle, event| {
            if matches!(
                event,
                tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
            ) {
                if let Some(state) = app_handle.try_state::<AppState>() {
                    state.shared.shutdown_all(Duration::from_secs(5));
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(text: &str) -> tauri::Url {
        tauri::Url::parse(text).expect("url")
    }

    #[test]
    fn the_app_itself_stays_in_the_window() {
        assert!(!leaves_the_app(&url("tauri://localhost/index.html")));
        assert!(!leaves_the_app(&url("about:srcdoc")));
    }

    #[test]
    fn a_mail_link_leaves_the_app() {
        assert!(leaves_the_app(&url("https://example.com/reset?token=1")));
        assert!(leaves_the_app(&url("http://example.com/")));
    }

    #[test]
    fn other_schemes_are_not_handed_to_open() {
        // `open` would happily launch a handler for these. Only web links are
        // a mail's business; everything else is cancelled by not reaching
        // open_in_browser.
        assert!(!leaves_the_app(&url("file:///etc/passwd")));
        assert!(!leaves_the_app(&url("mailto:someone@example.com")));
    }
}
