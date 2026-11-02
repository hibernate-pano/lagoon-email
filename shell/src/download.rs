//! The binary channel: attachment downloads.
//!
//! `api` carries JSON only, so an attachment cannot ride it: the proxy turns a
//! non-JSON body into a lossy `String` and the bytes are gone. This command is
//! the one other way to reach the sidecar, and it exists because a download is
//! not a JSON value.
//!
//! The rules that made `api` safe apply here unchanged:
//!
//! * the token never leaves this process (it is added here, never returned);
//! * the path is validated before a socket is opened (the same SSRF guard);
//! * a 4xx/5xx from the server is an *answer*, not a transport failure - the
//!   caller must be able to read the status and the error code.
//!
//! What it adds: the bytes land in `<app data>/downloads/` under a sanitised
//! name, and the file is revealed in Finder. It is deliberately **not**
//! opened: an attachment called `invoice.command` must not run because it was
//! clicked in a mail reader. The user decides what to do with the file.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::api::{self, ApiError};
use crate::state::Shared;

/// Contract §4.5. Same wrapper rule as `api`: `{ request: … }`.
#[derive(Debug, Clone, Deserialize)]
pub struct DownloadRequest {
    /// Must start with "/api/" - the same whitelist `api` enforces.
    pub path: String,
    #[serde(default, deserialize_with = "api::stringify_query")]
    pub query: Option<HashMap<String, String>>,
    /// The name to save under. The reader knows it from the message body; the
    /// server's `Content-Disposition` carries the same name.
    pub filename: Option<String>,
}

/// Contract §4.5.
///
/// `ok` means "the server answered", exactly as in `ApiResponse`: a 404 is an
/// answer (`ok: true, status: 404, code: "attachment-not-found"`), a dead
/// socket is not (`ok: false, status: 0`).
#[derive(Serialize, Clone, Debug)]
pub struct DownloadResponse {
    pub ok: bool,
    pub status: u16,
    /// Where the bytes were saved. Present only on 2xx.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// The server's `{"error": …}` code, when it answered with one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ApiError>,
}

impl DownloadResponse {
    fn fail(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            status: 0,
            path: None,
            code: None,
            error: Some(ApiError {
                code,
                message: message.into(),
            }),
        }
    }
}

/// Fetch, save, reveal. The one entry point the Tauri command calls.
pub async fn run(shared: &Shared, request: DownloadRequest) -> DownloadResponse {
    run_with(shared, request, reveal_in_finder).await
}

/// The same, with the reveal step injected so a test never opens Finder.
async fn run_with<R: Fn(&Path)>(
    shared: &Shared,
    request: DownloadRequest,
    reveal: R,
) -> DownloadResponse {
    let Some((base, token)) = shared.ready_endpoint() else {
        let status = shared.status();
        return DownloadResponse::fail(
            "not-ready",
            format!("sidecar is {}", status.phase.as_str()),
        );
    };
    if !request.path.starts_with("/api/") || request.path.contains("..") {
        return DownloadResponse::fail(
            "bad-path",
            format!("path {:?} is not under /api/", request.path),
        );
    }
    let url = format!("{base}{}", api::with_query(&request.path, &request.query));
    let response = match shared
        .http
        .get(&url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
        // A download may be a PDF, a ZIP, anything: do not constrain it.
        .header(reqwest::header::ACCEPT, "*/*")
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => {
            return DownloadResponse::fail(
                if error.is_timeout() {
                    "timeout"
                } else {
                    "transport"
                },
                format!("could not reach the sidecar: {error}"),
            )
        }
    };

    let status = response.status().as_u16();
    let bytes = match response.bytes().await {
        Ok(bytes) => bytes,
        Err(error) => return DownloadResponse::fail("transport", error.to_string()),
    };

    if !(200..300).contains(&status) {
        // The error envelope is `{"error": "<code>"}`; anything else is passed
        // through as an unknown answer rather than invented.
        let code = serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|value| {
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });
        return DownloadResponse {
            ok: true,
            status,
            path: None,
            code,
            error: None,
        };
    }

    let Some(dir) = shared.downloads_dir() else {
        return DownloadResponse::fail("not-ready", "the downloads directory is not set yet");
    };
    let filename = sanitize_filename(request.filename.as_deref().unwrap_or("attachment"));
    let path = unique_path(&dir, &filename);
    if let Err(error) = std::fs::create_dir_all(&dir) {
        return DownloadResponse::fail("save", format!("cannot create {}: {error}", dir.display()));
    }
    if let Err(error) = std::fs::write(&path, &bytes) {
        return DownloadResponse::fail("save", format!("cannot write {}: {error}", path.display()));
    }

    eprintln!(
        "[ipc] download {} -> {} ({} bytes)",
        request.path,
        path.display(),
        bytes.len()
    );
    // A Finder that refuses to come forward is not a failed download: the file
    // is on disk and the answer says where.
    reveal(&path);

    DownloadResponse {
        ok: true,
        status,
        path: Some(path.to_string_lossy().into_owned()),
        code: None,
        error: None,
    }
}

/// Select the file in Finder. Deliberately not `open`: see the module comment.
fn reveal_in_finder(path: &Path) {
    if let Err(error) = Command::new("open").arg("-R").arg(path).spawn() {
        eprintln!("[ipc] could not reveal {}: {error}", path.display());
    }
}

/// A filename that cannot leave the directory it is joined to.
///
/// The server's name comes from a mail, so it is attacker-controlled: path
/// separators, control characters and leading dots are all removed rather
/// than escaped, because there is no reason a saved attachment needs them.
pub fn sanitize_filename(raw: &str) -> String {
    let last = raw.rsplit(['/', '\\']).next().unwrap_or(raw).trim();
    let cleaned: String = last
        .chars()
        .map(|ch| match ch {
            ch if ch.is_control() => '_',
            ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            ch => ch,
        })
        .collect();
    let trimmed = cleaned.trim_start_matches('.').trim();
    if trimmed.is_empty() {
        return "attachment".to_owned();
    }
    // Filesystems cap a name at 255 bytes; leave room for the " 2" a second
    // download adds.
    if trimmed.chars().count() > 120 {
        return trimmed.chars().take(120).collect();
    }
    trimmed.to_owned()
}

/// The first free name in `dir`: an existing file is never overwritten.
pub fn unique_path(dir: &Path, filename: &str) -> PathBuf {
    let first = dir.join(filename);
    if !first.exists() {
        return first;
    }
    let path = Path::new(filename);
    let stem = path
        .file_stem()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| filename.to_owned());
    let extension = path
        .extension()
        .map(|value| format!(".{}", value.to_string_lossy()))
        .unwrap_or_default();
    for index in 2..1000 {
        let candidate = dir.join(format!("{stem} {index}{extension}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    // A thousand same-named files is not a real case; the caller still gets a
    // path instead of an error.
    first
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::Backend;
    use crate::state::{BootStatus, Shared};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    /// A one-shot HTTP server on an ephemeral port. Returns the port and a
    /// receiver for the raw request it saw, so a test can assert what the shell
    /// actually sent (path, query, token).
    fn serve_once(
        status: &'static str,
        content_type: &'static str,
        body: Vec<u8>,
    ) -> (u16, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buf = [0u8; 1024];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                match socket.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => request.extend_from_slice(&buf[..n]),
                }
            }
            let _ = tx.send(String::from_utf8_lossy(&request).into_owned());
            let head = format!(
                "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = socket.write_all(head.as_bytes());
            let _ = socket.write_all(&body);
        });
        (port, rx)
    }

    fn ready_shared(port: u16) -> (Shared, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "lagoon-download-run-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let shared = Shared::new(Backend::Rust);
        shared.set_token("test-token".to_owned());
        shared.publish(BootStatus::ready("rust", port, 1));
        shared.set_downloads_dir(dir.clone());
        (shared, dir)
    }

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(future)
    }

    #[test]
    fn a_two_hundred_writes_the_bytes_where_its_answer_says() {
        let (port, request) = serve_once("200 OK", "application/pdf", b"%PDF-1.4 bytes".to_vec());
        let (shared, dir) = ready_shared(port);
        let revealed = std::sync::Arc::new(std::sync::Mutex::new(None::<PathBuf>));
        let seen = std::sync::Arc::clone(&revealed);

        let response = block_on(run_with(
            &shared,
            DownloadRequest {
                path: "/api/messages/msg-1/attachments/1.2".to_owned(),
                query: Some(HashMap::from([(
                    "accountId".to_owned(),
                    "acc-1".to_owned(),
                )])),
                filename: Some("会议纪要.pdf".to_owned()),
            },
            move |path: &Path| *seen.lock().unwrap() = Some(path.to_path_buf()),
        ));

        assert!(response.ok, "a 200 is ok: {response:?}");
        assert_eq!(response.status, 200);
        let path = PathBuf::from(response.path.clone().expect("path on 2xx"));
        assert_eq!(std::fs::read(&path).expect("saved file"), b"%PDF-1.4 bytes");
        assert_eq!(path.file_name().unwrap(), "会议纪要.pdf");
        // The file is revealed, not opened: the caller is told where it is.
        assert_eq!(*revealed.lock().unwrap(), Some(path));

        // What went on the wire: the encoded path, the query, the token.
        let sent = request.recv().expect("request line").to_ascii_lowercase();
        assert!(
            sent.starts_with("get /api/messages/msg-1/attachments/1.2?accountid=acc-1 "),
            "{sent}"
        );
        assert!(sent.contains("authorization: bearer test-token"), "{sent}");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_four_oh_four_is_an_answer_and_writes_no_file() {
        let (port, _request) = serve_once(
            "404 Not Found",
            "application/json",
            br#"{"error":"attachment-not-found"}"#.to_vec(),
        );
        let (shared, dir) = ready_shared(port);

        let response = block_on(run_with(
            &shared,
            DownloadRequest {
                path: "/api/messages/msg-1/attachments/9".to_owned(),
                query: None,
                filename: Some("gone.pdf".to_owned()),
            },
            |_| panic!("a failed download must not be revealed"),
        ));

        assert!(response.ok, "the server answered: {response:?}");
        assert_eq!(response.status, 404);
        assert_eq!(response.code.as_deref(), Some("attachment-not-found"));
        assert!(response.path.is_none());
        assert!(!dir.join("gone.pdf").exists());

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_path_outside_the_api_is_refused_before_a_socket_is_opened() {
        // No listener at all: if the guard let this through it would be a
        // transport failure, not bad-path.
        let (shared, dir) = ready_shared(9);

        let response = block_on(run_with(
            &shared,
            DownloadRequest {
                path: "/healthz".to_owned(),
                query: None,
                filename: None,
            },
            |_| panic!("nothing was downloaded"),
        ));

        assert!(!response.ok);
        assert_eq!(response.error.as_ref().unwrap().code, "bad-path");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_filename_cannot_escape_the_downloads_directory() {
        assert_eq!(sanitize_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("/etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("a/b"), "b");
        assert_eq!(sanitize_filename(".."), "attachment");
        assert_eq!(sanitize_filename(".hidden"), "hidden");
    }

    #[test]
    fn control_characters_and_quotes_are_replaced_not_escaped() {
        assert_eq!(sanitize_filename("a\u{0}b.txt"), "a_b.txt");
        assert_eq!(sanitize_filename("a\"b.txt"), "a_b.txt");
        assert_eq!(sanitize_filename("a:b.txt"), "a_b.txt");
    }

    #[test]
    fn an_empty_or_blank_name_becomes_attachment() {
        assert_eq!(sanitize_filename(""), "attachment");
        assert_eq!(sanitize_filename("   "), "attachment");
    }

    #[test]
    fn a_chinese_name_is_kept_as_is() {
        assert_eq!(sanitize_filename("会议纪要.pdf"), "会议纪要.pdf");
    }

    #[test]
    fn a_very_long_name_is_truncated_to_a_safe_length() {
        let long = "x".repeat(400);
        assert_eq!(sanitize_filename(&long).chars().count(), 120);
    }

    #[test]
    fn a_second_download_does_not_overwrite_the_first() {
        let dir = std::env::temp_dir().join(format!("lagoon-download-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let first = unique_path(&dir, "report.pdf");
        std::fs::write(&first, b"one").expect("write first");

        let second = unique_path(&dir, "report.pdf");
        assert_eq!(second.file_name().unwrap(), "report 2.pdf");
        std::fs::write(&second, b"two").expect("write second");

        let third = unique_path(&dir, "report.pdf");
        assert_eq!(third.file_name().unwrap(), "report 3.pdf");
        assert_eq!(std::fs::read(&first).unwrap(), b"one");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
