//! Sidecar supervision (contract §2 and §3).
//!
//! Sequence, once: read keys → pick a free port → spawn LagoonServerCLI
//! with LAGOON_* env → poll /healthz for ≤20s → phase=ready.
//! A failure or a crash is retried **once**; a second failure ends in
//! phase=failed with a classified reason. On exit: SIGTERM → 5s → SIGKILL.
//!
//! Why the v3 CLI is spawned with a plain std::process::Command and not
//! tauri-plugin-shell: the shell plugin exists so the *front end* can run
//! binaries, and enabling it means shipping a capability that lets web code
//! execute processes. The shell never needs that (see v4/recon/rust-spike.md
//! §4.2A), so it is not linked in at all.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::backend::Backend;
use crate::keys::{self, Keys};
use crate::port;
use crate::state::{BootError, BootStatus, Shared};

/// Contract §3: poll /healthz, budget 20s.
pub const HEALTHZ_BUDGET: Duration = Duration::from_secs(20);
/// Contract §3: SIGTERM the sidecar, SIGKILL after 5s.
pub const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/// The sidecar pid, so an async-signal-safe handler can kill it.
/// Only kill() and _exit() are safe to call from a signal context; without
/// this, killing the shell (Ctrl-C, kill) would orphan the sidecar, because
/// Tauri's exit event only runs on a normal window close.
pub static CHILD_PID: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

extern "C" fn exit_with_sidecar(signal: libc::c_int) {
    let pid = CHILD_PID.load(Ordering::SeqCst);
    if pid > 0 {
        unsafe { libc::kill(pid, libc::SIGTERM) };
    }
    unsafe { libc::_exit(128 + signal) };
}

/// Installs SIGTERM/SIGINT handling once at startup (contract §3: no orphans).
pub fn install_signal_handlers() {
    unsafe {
        libc::signal(
            libc::SIGTERM,
            exit_with_sidecar as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            exit_with_sidecar as *const () as libc::sighandler_t,
        );
    }
}

pub struct Context {
    pub backend: Backend,
    pub root: PathBuf,
    pub bin: PathBuf,
    pub data_dir: PathBuf,
    pub keys: Keys,
    /// The directory child processes run in: the repo root in development,
    /// the app home in a packaged bundle (a repo root does not exist there).
    pub working_dir: PathBuf,
    /// Whether the Rust backend is allowed to talk to a real mail server.
    /// True for the packaged product and for an explicit `production` request;
    /// false in selftest so the contract can never touch the network.
    pub production_provider: bool,
}

/// True when this executable lives inside a .app bundle. A packaged run has
/// no repo root: data and keys live under ~/Library/Application Support and
/// the backend binary under Contents/Resources.
pub fn is_packaged() -> bool {
    std::env::current_exe()
        .map(|exe| exe.to_string_lossy().contains(".app/Contents/MacOS"))
        .unwrap_or(false)
}

/// The per-user home for a packaged install (keys + SQLite store).
fn app_home() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_owned());
    Path::new(&home).join("Library/Application Support/Lagoon-v4")
}

/// The repo root, resolvable because this crate is checked in at <repo>/shell
/// and CARGO_MANIFEST_DIR is baked in at compile time. LAGOON_V4_ROOT overrides
/// it (documented dev escape hatch; the contract default stands).
pub fn repo_root() -> PathBuf {
    if let Ok(explicit) = std::env::var("LAGOON_V4_ROOT") {
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .ancestors()
        .nth(1)
        .map(Path::to_path_buf)
        .unwrap_or(manifest_dir)
}

pub fn data_dir(root: &Path) -> PathBuf {
    match std::env::var("LAGOON_V4_DATA_DIR") {
        Ok(explicit) if !explicit.is_empty() => PathBuf::from(explicit),
        _ => root.join(".dev/data"),
    }
}

pub fn keys_path(root: &Path) -> PathBuf {
    match std::env::var("LAGOON_V4_KEYS") {
        Ok(explicit) if !explicit.is_empty() => PathBuf::from(explicit),
        _ => root.join(".dev").join("keys.json"),
    }
}

impl Context {
    pub fn load(backend: Backend) -> Result<Self, BootError> {
        let packaged = is_packaged();
        let (root, working_dir, data_dir, keys_path) = if packaged {
            let home = app_home();
            (
                home.clone(),
                home.clone(),
                home.clone(),
                home.join("keys.json"),
            )
        } else {
            let root = repo_root();
            let data = data_dir(&root);
            let keys = keys_path(&root);
            (root.clone(), root.clone(), data, keys)
        };
        let bin = backend.binary(&root)?;
        std::fs::create_dir_all(&data_dir).map_err(|e| BootError {
            code: "spawn",
            message: format!("cannot create data dir {}: {e}", data_dir.display()),
        })?;
        let keys = keys::load_or_generate(&keys_path).map_err(|message| BootError {
            code: "keys",
            message,
        })?;
        Ok(Self {
            backend,
            root,
            bin,
            data_dir,
            keys,
            working_dir,
            production_provider: packaged,
        })
    }
}

fn pump<R: Read + Send + 'static, F: Fn(&str) + Send + 'static>(
    reader: R,
    tag: &'static str,
    on_line: F,
) {
    std::thread::spawn(move || {
        use std::io::BufRead;
        for line in std::io::BufReader::new(reader).lines() {
            match line {
                Ok(line) => {
                    on_line(&line);
                    eprintln!("[{tag}] {line}");
                }
                Err(_) => break,
            }
        }
    });
}

/// The one machine-readable line the backend prints after binding.
///
/// `<u16>` only, and never 0: `--port 0` is the request, not the answer.
pub(crate) fn parse_port_line(line: &str) -> Option<u16> {
    let raw = line.trim().strip_prefix("LAGOON_PORT=")?;
    match raw.trim().parse::<u16>() {
        Ok(port) if port != 0 => Some(port),
        _ => None,
    }
}

fn spawn(
    ctx: &Context,
    port: u16,
    on_stdout: impl Fn(&str) + Send + 'static,
) -> Result<Child, BootError> {
    let db = ctx.data_dir.join("lagoon.sqlite");
    let mut command = Command::new(&ctx.bin);
    match ctx.backend {
        // The v3 CLI's env contract (Sources/LagoonServerCLI/main.swift:21-65).
        Backend::Swift => {
            command
                .env("LAGOON_DB_PATH", &db)
                .env("LAGOON_SERVER_HOST", "127.0.0.1")
                .env("LAGOON_SERVER_PORT", port.to_string())
                .env("LAGOON_TOKEN_KEY", &ctx.keys.token_key)
                .env("LAGOON_BODY_KEY", &ctx.keys.body_key)
                .env("LAGOON_API_TOKEN", &ctx.keys.api_token);
        }
        // lagoon-api takes flags for location and env for secrets (v4/crates
        // lagoon-api README): secrets never go on argv, where ps would see them.
        Backend::Rust => {
            command
                .arg("--db")
                .arg(&db)
                .arg("--host")
                .arg("127.0.0.1")
                .arg("--port")
                .arg(port.to_string())
                .env("LAGOON_TOKEN_KEY", &ctx.keys.token_key)
                .env("LAGOON_BODY_KEY", &ctx.keys.body_key)
                .env("LAGOON_API_TOKEN", &ctx.keys.api_token)
                // The packaged product talks to a real mailbox; selftest runs
                // with production_provider = false so the contract can never
                // touch the network.
                .env(
                    "LAGOON_MAIL_PROVIDER",
                    if ctx.production_provider {
                        "production"
                    } else {
                        "none"
                    },
                );
            // The AI key, when keys.json carries one. Finder-launched apps
            // do not see the shell's environment, so this file is the only
            // way a user can configure the advisor without a terminal.
            if let Some(key) = &ctx.keys.llm_api_key {
                command.env("LLM_PROVIDER_PRIMARY_API_KEY", key);
            }
        }
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // The v3 CLI resolves relative paths (config/providers.json) against the
        // process CWD, so development pins it to the repo root. A packaged run
        // has no repo root and the Rust backend needs no CWD: use the app home.
        .current_dir(&ctx.working_dir);
    let mut child = command.spawn().map_err(|e| BootError {
        code: "spawn",
        message: format!("spawn {}: {e}", ctx.bin.display()),
    })?;
    if let Some(stdout) = child.stdout.take() {
        pump(stdout, "sidecar", on_stdout);
    }
    if let Some(stderr) = child.stderr.take() {
        pump(stderr, "sidecar", |_| {});
    }
    Ok(child)
}

async fn healthz_once(shared: &Shared, port: u16, token: &str) -> bool {
    let url = format!("http://127.0.0.1:{port}/healthz");
    shared
        .http
        .get(&url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
        .timeout(Duration::from_millis(1500))
        .send()
        .await
        .map(|response| response.status().is_success())
        .unwrap_or(false)
}

/// Wait for the port the backend bound, then for /healthz to answer 2xx.
///
/// The Rust backend is spawned with `--port 0` and prints `LAGOON_PORT=` once
/// it is listening; until that line arrives there is no address to handshake
/// with. The Swift reference backend cannot print it, so it keeps the
/// shell-chosen port.
async fn wait_healthz(
    shared: &Shared,
    backend: Backend,
    fixed_port: u16,
    token: &str,
) -> Result<u16, BootError> {
    let deadline = Instant::now() + HEALTHZ_BUDGET;
    loop {
        let port = match backend {
            Backend::Rust => shared.reported_port(),
            Backend::Swift => fixed_port,
        };
        if port != 0 && healthz_once(shared, port, token).await {
            return Ok(port);
        }
        // A child that died during startup is a different failure than a slow
        // one: `exited` vs `health-timeout` (contract §4.1 code set).
        match shared.with_child_mut(|child| child.try_wait()) {
            Some(Ok(Some(status))) => {
                return Err(BootError {
                    code: "exited",
                    message: format!(
                    "sidecar exited during startup ({status:?}); see the [sidecar] log lines above"
                ),
                })
            }
            Some(Err(e)) => {
                return Err(BootError {
                    code: "exited",
                    message: format!("try_wait failed: {e}"),
                })
            }
            _ => {}
        }
        if Instant::now() >= deadline {
            return Err(BootError {
                code: "health-timeout",
                message: if port == 0 {
                    format!(
                        "the backend did not print LAGOON_PORT within {}s",
                        HEALTHZ_BUDGET.as_secs()
                    )
                } else {
                    format!(
                        "no 2xx from http://127.0.0.1:{port}/healthz within {}s",
                        HEALTHZ_BUDGET.as_secs()
                    )
                },
            });
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// One spawn -> healthz -> phase=ready attempt.
pub async fn start_once(shared: &Shared, ctx: &Context) -> Result<(), BootError> {
    // Rust: the backend binds :0 and reports the port it got. Choosing the
    // port here would be a TOCTOU - the listener is closed between the probe
    // and the child's bind, and whoever takes it receives the healthz request
    // with the real API token in the Authorization header.
    let requested = match ctx.backend {
        Backend::Rust => {
            shared.clear_reported_port();
            0
        }
        Backend::Swift => port::free_port_with_retry(5).map_err(|message| BootError {
            code: "port",
            message,
        })?,
    };
    let slot = shared.port_slot();
    let child = spawn(ctx, requested, move |line| {
        if let Some(port) = parse_port_line(line) {
            let _ = slot.compare_exchange(0, port, Ordering::SeqCst, Ordering::SeqCst);
        }
    })?;
    let pid = child.id();
    CHILD_PID.store(pid as i32, Ordering::SeqCst);
    shared.store_child(child);
    shared.set_token(ctx.keys.api_token.clone());
    eprintln!(
        "[sidecar] spawned pid={pid} requested_port={requested} bin={} db={} root={}",
        ctx.bin.display(),
        ctx.data_dir.join("lagoon.sqlite").display(),
        ctx.root.display()
    );
    match wait_healthz(shared, ctx.backend, requested, &ctx.keys.api_token).await {
        Ok(port) => {
            shared.publish(BootStatus::ready(shared.backend().as_str(), port, pid));
            Ok(())
        }
        Err(error) => {
            // Do not leave a half-started process behind (contract §3).
            shared.terminate_child(Duration::from_secs(2));
            Err(error)
        }
    }
}

/// Wait until the child we spawned exits. None means "we are shutting down".
async fn watch_child(shared: &Shared) -> Option<String> {
    loop {
        if shared.shutdown.load(Ordering::SeqCst) {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
        match shared.with_child_mut(|child| child.try_wait()) {
            Some(Ok(Some(status))) => {
                CHILD_PID.store(0, Ordering::SeqCst);
                return Some(format!("{status:?}"));
            }
            Some(Ok(None)) => {}
            Some(Err(e)) => return Some(format!("try_wait failed: {e}")),
            None => return Some("child handle missing".to_string()),
        }
    }
}

/// The supervisor loop: start, watch, restart once, then give up.
pub async fn supervise(shared: Arc<Shared>) {
    if shared.supervising.swap(true, Ordering::SeqCst) {
        eprintln!("[boot] supervisor already running; not starting a second one");
        return;
    }

    let ctx = match Context::load(shared.backend()) {
        Ok(ctx) => ctx,
        Err(error) => {
            shared.publish(BootStatus::failed_from(shared.backend().as_str(), error));
            shared.supervising.store(false, Ordering::SeqCst);
            return;
        }
    };
    // Downloads land beside the store, not in the working directory: a dev run
    // and a packaged run then behave the same way, and nothing is written to
    // a directory the user did not choose.
    shared.set_downloads_dir(ctx.data_dir.join("downloads"));

    let mut restarts_left = 1u8;
    loop {
        if shared.shutdown.load(Ordering::SeqCst) {
            break;
        }
        shared.publish(BootStatus::starting(shared.backend().as_str()));
        match start_once(&shared, &ctx).await {
            Ok(()) => {
                let exit_reason = watch_child(&shared).await;
                if shared.shutdown.load(Ordering::SeqCst) {
                    break;
                }
                match exit_reason {
                    Some(reason) => {
                        if restarts_left > 0 {
                            restarts_left -= 1;
                            eprintln!("[boot] sidecar exited ({reason}); restarting once");
                            continue;
                        }
                        shared.publish(BootStatus::failed(
                            shared.backend().as_str(),
                            "exited",
                            format!("sidecar exited and did not survive the restart: {reason}"),
                        ));
                        break;
                    }
                    None => break,
                }
            }
            Err(error) => {
                if restarts_left > 0 {
                    restarts_left -= 1;
                    eprintln!("[boot] startup failed ({}); retrying once", error.code);
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    continue;
                }
                shared.publish(BootStatus::failed_from(shared.backend().as_str(), error));
                break;
            }
        }
    }

    shared.supervising.store(false, Ordering::SeqCst);
}

/// restart_sidecar (contract §4.3): stop the current supervisor, then start a
/// fresh one with a fresh restart budget.
pub async fn restart(shared: Arc<Shared>) {
    shared.shutdown.store(true, Ordering::SeqCst);
    shared.terminate_child(SHUTDOWN_GRACE);

    let deadline = Instant::now() + Duration::from_secs(7);
    while shared.supervising.load(Ordering::SeqCst) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    shared.shutdown.store(false, Ordering::SeqCst);
    shared.publish(BootStatus::starting(shared.backend().as_str()));
    supervise(shared).await;
}

/// Raw GET used by --selftest to prove the 401 case: the proxy always sends the
/// real token, so the only way to observe a 401 is to send a wrong one.
pub async fn raw_status(
    shared: &Shared,
    path: &str,
    token_override: Option<&str>,
) -> Result<u16, String> {
    let Some((base, real_token)) = shared.ready_endpoint() else {
        return Err("not ready".to_string());
    };
    let token = token_override.unwrap_or(&real_token);
    shared
        .http
        .get(format!("{base}{path}"))
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map(|response| response.status().as_u16())
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::parse_port_line;

    #[test]
    fn the_port_marker_is_parsed_and_nothing_else_is() {
        assert_eq!(parse_port_line("LAGOON_PORT=51234"), Some(51234));
        // 0 is what `--port 0` *means*, never what a bound listener reports.
        assert_eq!(parse_port_line("LAGOON_PORT=0"), None);
        assert_eq!(parse_port_line("[sidecar] LAGOON_PORT=1"), None);
        assert_eq!(parse_port_line("LAGOON_PORT=nope"), None);
        assert_eq!(parse_port_line(""), None);
    }
}
