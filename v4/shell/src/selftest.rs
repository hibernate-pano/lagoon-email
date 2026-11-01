//! --selftest: the acceptance evidence, produced without a window.
//!
//! It drives the same supervisor loop (sidecar::supervise) and the same proxy
//! (api::forward) the GUI uses, once per backend whose binary is present:
//! swift (v3 LagoonServerCLI) and rust (v4/crates lagoon-api).
//!
//! The rust backend is READ-ONLY in R3: endpoints it has not implemented answer
//! 404 with an empty body. Contract v0.2 4.1 says the shell must pass that
//! through as ok:true - a front end that showed it as a network error would be
//! lying about what happened - so that case is asserted, not assumed.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::api;
use crate::backend::Backend;
use crate::sidecar;
use crate::state::{Phase, Shared};

fn check(scope: &str, name: &str, passed: bool, detail: impl AsRef<str>) -> usize {
    let mark = if passed { "PASS" } else { "FAIL" };
    eprintln!("[selftest {scope}] {mark} {name}");
    eprintln!("                 {}", detail.as_ref());
    if passed { 0 } else { 1 }
}

fn render(response: &api::ApiResponse) -> String {
    serde_json::to_string(response).unwrap_or_else(|e| format!("<unserialisable: {e}>"))
}

fn request(method: &str, path: &str) -> api::ApiRequest {
    api::ApiRequest { method: method.to_string(), path: path.to_string(), query: None, body: None }
}

fn write_request(method: &str, path: &str) -> api::ApiRequest {
    api::ApiRequest {
        method: method.to_string(),
        path: path.to_string(),
        query: None,
        body: Some(serde_json::json!({})),
    }
}

fn process_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

async fn wait_ready(shared: &Shared, budget: Duration, different_from: Option<u32>) -> Option<(u16, u32)> {
    let deadline = Instant::now() + budget;
    loop {
        let status = shared.status();
        if status.phase == Phase::Ready {
            if let (Some(port), Some(pid)) = (status.port, status.pid) {
                if different_from != Some(pid) {
                    return Some((port, pid));
                }
            }
        }
        if status.phase == Phase::Failed {
            eprintln!("[selftest] phase=failed: {:?}", status.error);
            return None;
        }
        if Instant::now() >= deadline {
            eprintln!("[selftest] timed out waiting for ready; last status={status:?}");
            return None;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Every backend whose binary can be resolved gets a full run. A missing
/// binary is a SKIP (printed), not a failure: a checkout may only have one.
fn available_backends() -> Vec<Backend> {
    let root = sidecar::repo_root();
    let mut available = Vec::new();
    for backend in [Backend::Swift, Backend::Rust] {
        match backend.binary(&root) {
            Ok(path) => {
                eprintln!("[selftest] found {} backend: {}", backend.as_str(), path.display());
                available.push(backend);
            }
            Err(error) => {
                eprintln!("[selftest] SKIP {} backend: {}", backend.as_str(), error.message);
            }
        }
    }
    available
}

pub fn run() -> usize {
    let available = available_backends();
    if available.is_empty() {
        eprintln!("[selftest] FAIL no backend binary found (swift or rust)");
        return 1;
    }
    let names: Vec<&str> = available.iter().map(|backend| backend.as_str()).collect();
    eprintln!("[selftest] backends under test: {}", names.join(", "));
    let mut failures = 0usize;
    for backend in available {
        failures += tauri::async_runtime::block_on(run_one(backend));
    }
    eprintln!("[selftest] all backends done, {failures} failure(s)");
    failures
}

async fn run_one(backend: Backend) -> usize {
    let scope = backend.as_str();
    let mut failures = 0usize;
    eprintln!("[selftest {scope}] ---- run start (no window; same code paths as the GUI) ----");
    let shared = Arc::new(Shared::new(backend));

    // 1. Before the backend exists: contract 4.2 not-ready.
    let response = api::forward(&shared, request("GET", "/healthz")).await;
    failures += check(
        scope,
        "api before boot => ok:false code=not-ready status=0",
        !response.ok && response.status == 0 && response.error.as_ref().map(|e| e.code) == Some("not-ready"),
        render(&response),
    );

    // 2. Boot through the real supervisor loop (restart budget included).
    let supervisor = shared.clone();
    tauri::async_runtime::spawn(async move { sidecar::supervise(supervisor).await });
    let Some((port, pid)) = wait_ready(&shared, Duration::from_secs(25), None).await else {
        eprintln!("[selftest {scope}] FAIL phase never became ready");
        return failures + 1;
    };
    let status = shared.status();
    failures += check(
        scope,
        "phase=ready, backend field matches, port+pid present",
        status.phase == Phase::Ready
            && status.backend == scope
            && status.port == Some(port)
            && status.pid == Some(pid),
        format!("phase={} backend={} port={port} pid={pid}", status.phase.as_str(), status.backend),
    );
    eprintln!("[selftest {scope}] backend base=http://127.0.0.1:{port}");

    // 3. Contract 4.2 happy path.
    let response = api::forward(&shared, request("GET", "/healthz")).await;
    failures += check(scope, "api GET /healthz => ok:true status=200", response.ok && response.status == 200, render(&response));

    let response = api::forward(&shared, request("GET", "/api/accounts")).await;
    failures += check(
        scope,
        "api GET /api/accounts => ok:true status=200 body=array",
        response.ok && response.status == 200 && response.body.as_ref().map(|b| b.is_array()).unwrap_or(false),
        render(&response),
    );

    // 4. A 4xx is a server answer, not a transport failure (contract 1.2).
    let response = api::forward(&shared, request("GET", "/api/does-not-exist")).await;
    failures += check(
        scope,
        "api GET /api/does-not-exist => ok:true status=404 (passthrough)",
        response.ok && response.status == 404,
        render(&response),
    );

    // 5. Write endpoint: both backends implement it, and both reject an empty
    //    body with 400 missing-field — v3's collectBody succeeds with zero
    //    bytes and the JSON decoder is what fails, so empty body and missing
    //    field share one code (R3.3 verified this against the real v3).
    let response = api::forward(&shared, write_request("POST", "/api/accounts/imap")).await;
    failures += check(
        scope,
        "POST /api/accounts/imap => ok:true status=400 missing-field (implemented, rejects empty body)",
        response.ok
            && response.status == 400
            && matches!(
                response.body.as_ref(),
                Some(serde_json::Value::Object(map))
                    if map.get("error").and_then(|v| v.as_str()) == Some("missing-field")
            ),
        render(&response),
    );

    // 6. 401: the proxy always sends the real token, so a wrong one is sent
    //    directly to the same port to show the header is what authorises.
    match sidecar::raw_status(&shared, "/api/accounts", Some("not-the-token")).await {
        Ok(code) => failures += check(scope, "wrong Bearer => 401", code == 401, format!("status={code}")),
        Err(e) => failures += check(scope, "wrong Bearer => 401", false, e),
    }
    match sidecar::raw_status(&shared, "/api/accounts", None).await {
        Ok(code) => failures += check(
            scope,
            "real Bearer => 200 (proves the header is what authorises)",
            code == 200,
            format!("status={code}"),
        ),
        Err(e) => failures += check(scope, "real Bearer => 200", false, e),
    }

    // 7. Refusals: not a transport error and not a server answer either.
    let response = api::forward(&shared, request("GET", "/etc/passwd")).await;
    failures += check(
        scope,
        "api GET /etc/passwd => ok:false code=bad-path",
        !response.ok && response.error.as_ref().map(|e| e.code) == Some("bad-path"),
        render(&response),
    );

    let response = api::forward(&shared, request("TRACE", "/api/accounts")).await;
    failures += check(
        scope,
        "api TRACE /api/accounts => ok:false code=bad-request",
        !response.ok && response.error.as_ref().map(|e| e.code) == Some("bad-request"),
        render(&response),
    );

    // 8. Crash -> restart once (contract 3).
    eprintln!("[selftest {scope}] SIGKILL backend pid={pid} to exercise the restart path");
    unsafe { libc::kill(pid as i32, libc::SIGKILL) };
    match wait_ready(&shared, Duration::from_secs(25), Some(pid)).await {
        Some((port2, pid2)) => failures += check(
            scope,
            "crash => restarted once, phase=ready with a new pid",
            pid2 != pid,
            format!("old pid={pid} -> new pid={pid2} port={port2}"),
        ),
        None => failures += check(scope, "crash => restarted once, phase=ready with a new pid", false, "no ready state with a new pid within 25s"),
    }

    // 9. restart_sidecar (contract 4.3): the command wraps this exact fn.
    let before_restart = shared.status().pid;
    let restarter = shared.clone();
    tauri::async_runtime::spawn(async move { sidecar::restart(restarter).await });
    match wait_ready(&shared, Duration::from_secs(25), before_restart).await {
        Some((restart_port, restart_pid)) => failures += check(
            scope,
            "restart_sidecar => phase=ready again with a new pid",
            Some(restart_pid) != before_restart,
            format!("before={before_restart:?} after pid={restart_pid} port={restart_port}"),
        ),
        None => failures += check(scope, "restart_sidecar => phase=ready again with a new pid", false, "no ready state after restart_sidecar within 25s"),
    }
    let pid_after_restart = shared.status().pid;

    // 10. Shutdown: SIGTERM, 5s, SIGKILL - and no orphan left behind.
    shared.shutdown_all(sidecar::SHUTDOWN_GRACE);
    tokio::time::sleep(Duration::from_millis(600)).await;
    if let Some(pid) = pid_after_restart {
        failures += check(
            scope,
            "no orphan after shutdown",
            !process_alive(pid),
            format!("pid={pid} alive={}", process_alive(pid)),
        );
    }

    // Let the supervisor task observe shutdown before the next backend starts.
    let deadline = Instant::now() + Duration::from_secs(5);
    while shared.supervising.load(std::sync::atomic::Ordering::SeqCst) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    eprintln!("[selftest {scope}] {failures} failure(s)");
    failures
}
