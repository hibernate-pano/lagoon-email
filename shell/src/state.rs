//! Boot state: the one place `phase` lives.
//!
//! Implements `v4/docs/ipc-contract.md` §3 (startup sequence), §4.1
//! (`boot_status` shape) and §4.4 (`boot-status` event).
//!
//! Two rules this file exists to keep:
//! 1. The API token never leaves this process. It lives in `Inner::token`,
//!    `Inner` has no `Debug`, and nothing here serialises it.
//! 2. Every phase change is published exactly once — stored for late
//!    `boot_status` callers *and* emitted as an event, so a front end that
//!    subscribes late still sees the current state.

use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::backend::Backend;

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    Starting,
    Ready,
    Failed,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Starting => "starting",
            Phase::Ready => "ready",
            Phase::Failed => "failed",
        }
    }
}

/// Contract §4.1 error codes. `&'static str` on purpose: the set is closed.
#[derive(Serialize, Clone, Debug)]
pub struct BootError {
    pub code: &'static str,
    pub message: String,
}

/// Contract §4.1 — the payload of `boot_status` and of the `boot-status` event.
#[derive(Serialize, Clone, Debug)]
pub struct BootStatus {
    pub phase: Phase,
    /// Contract v0.2 4.1: which business backend this run talks to.
    pub backend: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<BootError>,
}

impl BootStatus {
    pub fn starting(backend: &'static str) -> Self {
        Self { phase: Phase::Starting, backend, port: None, pid: None, error: None }
    }

    pub fn ready(backend: &'static str, port: u16, pid: u32) -> Self {
        Self { phase: Phase::Ready, backend, port: Some(port), pid: Some(pid), error: None }
    }

    pub fn failed(backend: &'static str, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            phase: Phase::Failed,
            backend,
            port: None,
            pid: None,
            error: Some(BootError { code, message: message.into() }),
        }
    }

    pub fn failed_from(backend: &'static str, err: BootError) -> Self {
        Self { phase: Phase::Failed, backend, port: None, pid: None, error: Some(err) }
    }
}

struct Inner {
    backend: Backend,
    status: BootStatus,
    /// The sidecar's API token. Rust-side only, by contract §1.1.
    token: Option<String>,
    child: Option<Child>,
}

pub struct Shared {
    inner: Mutex<Inner>,
    app: Mutex<Option<AppHandle>>,
    /// The HTTP client for 127.0.0.1 only (no TLS backend is compiled in).
    pub http: reqwest::Client,
    /// Set when the supervisor loop is running, so a second one cannot start.
    pub supervising: AtomicBool,
    /// Set on app exit: the supervisor must stop restarting things.
    pub shutdown: AtomicBool,
}

impl Shared {
    pub fn new(backend: Backend) -> Self {
        let http = reqwest::Client::builder()
            // Contract §4.2: connect 5s, read 60s.
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            inner: Mutex::new(Inner {
                backend,
                status: BootStatus::starting(backend.as_str()),
                token: None,
                child: None,
            }),
            app: Mutex::new(None),
            http,
            supervising: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
        }
    }

    pub fn set_app(&self, app: AppHandle) {
        *self.app.lock().unwrap() = Some(app);
    }

    pub fn backend(&self) -> Backend {
        self.inner.lock().unwrap().backend
    }

    pub fn status(&self) -> BootStatus {
        self.inner.lock().unwrap().status.clone()
    }

    /// Store + emit. The single write point for `phase`.
    pub fn publish(&self, status: BootStatus) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.status = status.clone();
        }
        // Event first (contract §4.4: subscribers drive the splash screen),
        // then a log line so a headless `cargo run` transcript still shows
        // every transition — which is how M1 is evidenced.
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit("boot-status", status.clone());
        }
        match serde_json::to_string(&status) {
            Ok(json) => eprintln!("[boot] {json}"),
            Err(_) => eprintln!("[boot] phase={}", status.phase.as_str()),
        }
    }

    /// Publish the current state again (a new subscriber can also call
    /// `boot_status`; this keeps the event stream and the stored state equal).
    pub fn republish(&self) {
        let current = self.status();
        self.publish(current);
    }

    pub fn set_token(&self, token: String) {
        self.inner.lock().unwrap().token = Some(token);
    }

    pub fn store_child(&self, child: Child) {
        self.inner.lock().unwrap().child = Some(child);
    }

    pub fn take_child(&self) -> Option<Child> {
        self.inner.lock().unwrap().child.take()
    }

    pub fn with_child_mut<R>(&self, f: impl FnOnce(&mut Child) -> R) -> Option<R> {
        self.inner.lock().unwrap().child.as_mut().map(f)
    }

    /// `(base_url, token)` when a request can actually be sent.
    pub fn ready_endpoint(&self) -> Option<(String, String)> {
        let inner = self.inner.lock().unwrap();
        if inner.status.phase != Phase::Ready {
            return None;
        }
        let port = inner.status.port?;
        let token = inner.token.clone()?;
        Some((format!("http://127.0.0.1:{port}"), token))
    }

    /// SIGTERM, wait `grace`, then SIGKILL (contract §3: no orphans).
    pub fn terminate_child(&self, grace: Duration) {
        let Some(mut child) = self.take_child() else { return };
        let pid = child.id() as i32;
        crate::sidecar::CHILD_PID.store(0, Ordering::SeqCst);
        eprintln!("[sidecar] SIGTERM pid={pid}");
        unsafe { libc::kill(pid, libc::SIGTERM) };
        let deadline = Instant::now() + grace;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    eprintln!("[sidecar] exited cleanly pid={pid} status={status:?}");
                    return;
                }
                Ok(None) => {}
                Err(e) => {
                    eprintln!("[sidecar] try_wait failed pid={pid}: {e}");
                    return;
                }
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        eprintln!("[sidecar] SIGKILL pid={pid} (did not exit within {:?})", grace);
        unsafe { libc::kill(pid, libc::SIGKILL) };
        let _ = child.wait();
    }

    /// App shutdown path: stop the supervisor loop, then kill the child.
    pub fn shutdown_all(&self, grace: Duration) {
        self.shutdown.store(true, Ordering::SeqCst);
        self.terminate_child(grace);
    }
}

impl Drop for Shared {
    fn drop(&mut self) {
        // Belt and braces: if the process is torn down without the Tauri
        // exit event (panic/unwind), the child still must not survive.
        if let Ok(mut inner) = self.inner.lock() {
            if let Some(mut child) = inner.child.take() {
                let pid = child.id() as i32;
                unsafe { libc::kill(pid, libc::SIGTERM) };
                let _ = child.wait();
            }
        }
    }
}
