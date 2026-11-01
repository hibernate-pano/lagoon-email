//! Minimal Tauri 2 shell: a window that loads a static index.html with no packager.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[tauri::command]
fn ping(name: String) -> String {
    format!("pong from rust: {name}")
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![ping])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
