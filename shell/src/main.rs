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
