//! Free-port selection (contract §3: "不固定 8080").
//!
//! Binding :0 and *dropping* the listener is inherently racy — another process
//! can take the port between the drop and the sidecar's bind. The supervisor
//! therefore retries the whole spawn with a fresh port when the handshake
//! fails, which is the "重试兜底" the contract asks for.

use std::net::TcpListener;
use std::time::Duration;

pub fn free_port() -> std::io::Result<u16> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

/// A few attempts, because the window between drop and rebind is real.
pub fn free_port_with_retry(attempts: u8) -> Result<u16, String> {
    let mut last = String::new();
    for attempt in 0..attempts {
        match free_port() {
            Ok(port) => return Ok(port),
            Err(e) => {
                last = e.to_string();
                if attempt + 1 < attempts {
                    std::thread::sleep(Duration::from_millis(25));
                }
            }
        }
    }
    Err(format!(
        "could not bind a free port after {attempts} attempts: {last}"
    ))
}
