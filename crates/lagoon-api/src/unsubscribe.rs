//! RFC 8058 one-click unsubscribe: the single outbound request this product
//! ever makes to a third party on the user's behalf.
//!
//! The rules live here, not in the route, because they are the security
//! boundary: a URL in a mail header is written by a stranger, and this process
//! is on the user's machine, next to their LAN.
//!
//! What is allowed, and nothing else:
//!   * `https:` only, no userinfo, port 443 or none;
//!   * the target must declare `List-Unsubscribe-Post: List-Unsubscribe=One-Click`
//!     (the publisher opted into a machine POST; the plain link is a page for a
//!     human and stays with the browser);
//!   * the host must resolve to public addresses only - loopback, private,
//!     link-local, CGNAT, multicast and the cloud metadata address are refused;
//!   * the address that passed the check is the address we dial (`connect_to`),
//!     so a second resolution cannot swap in a private one (DNS rebinding);
//!   * no redirects: a 3xx is refused, because following it would move the
//!     request to a host that was never vetted;
//!   * no cookies, no referer, no credentials; one request per target.
//!
//! Failures are classified, not flattened: the route turns each into the
//! contract's own 422 code so the UI can tell "there is no way out" from
//! "the publisher wants you on a page".

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::time::Duration;

use lagoon_mail::transport::{TlsTransport, Transport};

use crate::ai::http::{self, HttpRequest};

/// The RFC 8058 request body, byte for byte.
pub const ONE_CLICK_BODY: &str = "List-Unsubscribe=One-Click";

/// How long a single unsubscribe request may take, end to end.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// Why a mail cannot be unsubscribed automatically.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// No usable `List-Unsubscribe` target at all (older row, or a broken header).
    Unavailable,
    /// A `https:` target exists but does not opt into one-click: it is a page.
    PageRequired,
    /// The guard refused the target itself (scheme, address, userinfo, ...).
    ManualRequired(&'static str),
}

impl Refusal {
    /// The contract's error code for this refusal.
    pub fn code(&self) -> &'static str {
        match self {
            Refusal::Unavailable => "unsubscribe-unavailable",
            Refusal::PageRequired => "unsubscribe-page-required",
            Refusal::ManualRequired(_) => "unsubscribe-manual-required",
        }
    }

    /// A short machine-side label for the audit row and the log.
    pub fn label(&self) -> &'static str {
        match self {
            Refusal::Unavailable => "unavailable",
            Refusal::PageRequired => "page-required",
            Refusal::ManualRequired(reason) => reason,
        }
    }
}

/// What the publisher answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    /// The subscription is over: 2xx, or the address is already gone (404/410).
    Unsubscribed { status: u16, publisher: String },
    /// The request itself failed; the user can retry or open the page.
    Failed { reason: String },
}

/// Whether the stored links declare any RFC 8058 one-click target.
///
/// The rule layer asks this, not `one_click_target`: a suggestion is worth
/// making even when the URL itself would be refused, because the UI then offers
/// the page instead of a button.
pub fn declared_one_click(links_json: &str) -> Option<bool> {
    let value: serde_json::Value = serde_json::from_str(links_json).ok()?;
    let links = value.as_array()?;
    Some(links.iter().any(|link| {
        link.get("kind").and_then(|kind| kind.as_str()) == Some("https")
            && link
                .get("oneClick")
                .and_then(|flag| flag.as_bool())
                .unwrap_or(false)
    }))
}

/// Pick the one-click target out of the stored `unsubscribeLinks` JSON.
///
/// The stored value is the parsed form of both headers (`url`, `kind`,
/// `oneClick`), so no header parsing happens here and no body is fetched.
pub fn one_click_target(links_json: &str) -> Result<String, Refusal> {
    let value: serde_json::Value =
        serde_json::from_str(links_json).map_err(|_| Refusal::Unavailable)?;
    let links = value.as_array().ok_or(Refusal::Unavailable)?;
    let mut saw_https = false;
    for link in links {
        let kind = link.get("kind").and_then(|kind| kind.as_str());
        if kind != Some("https") {
            continue;
        }
        saw_https = true;
        let one_click = link
            .get("oneClick")
            .and_then(|flag| flag.as_bool())
            .unwrap_or(false);
        if !one_click {
            continue;
        }
        if let Some(url) = link.get("url").and_then(|url| url.as_str()) {
            return parse_target(url).map(|target| target.url);
        }
    }
    if saw_https {
        Err(Refusal::PageRequired)
    } else {
        Err(Refusal::Unavailable)
    }
}

/// A vetted target: enough to dial without asking the resolver again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub url: String,
    pub host: String,
    pub port: u16,
    pub path: String,
}

/// Validate the URL and refuse anything the guards do not cover.
pub fn parse_target(url: &str) -> Result<Target, Refusal> {
    let url = url.trim();
    let rest = url
        .strip_prefix("https://")
        .ok_or(Refusal::ManualRequired("not-https"))?;
    if rest.is_empty() {
        return Err(Refusal::ManualRequired("empty-target"));
    }
    if rest.contains('@') {
        // Userinfo is the classic "https://trusted.com@evil.com" trick.
        return Err(Refusal::ManualRequired("userinfo"));
    }
    let (authority, path) = match rest.find(['/', '?', '#']) {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    if authority.is_empty() {
        return Err(Refusal::ManualRequired("no-host"));
    }
    if authority.starts_with('[') {
        // A bracketed IPv6 literal: the certificate would be checked against an
        // address, not a name, and the port split below would misread it.
        return Err(Refusal::ManualRequired("ip-literal"));
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port: u16 = port
                .parse()
                .map_err(|_| Refusal::ManualRequired("bad-port"))?;
            if port != 443 {
                // A non-443 port is almost never a real publisher, and allowing
                // arbitrary ports widens what an SSRF guard has to cover.
                return Err(Refusal::ManualRequired("nonstandard-port"));
            }
            (host, port)
        }
        None => (authority, 443),
    };
    if host.is_empty() {
        return Err(Refusal::ManualRequired("no-host"));
    }
    if host.parse::<IpAddr>().is_ok() {
        // A hostname is required: the certificate is verified against it, and
        // an IP-literal target skips the name check entirely.
        return Err(Refusal::ManualRequired("ip-literal"));
    }
    let path = if path.is_empty() { "/" } else { path };
    Ok(Target {
        url: url.to_owned(),
        host: host.to_ascii_lowercase(),
        port,
        path: path.to_owned(),
    })
}

/// Resolve the host and keep only answers that are safe to dial.
pub fn public_addresses(host: &str, port: u16) -> Result<Vec<SocketAddr>, Refusal> {
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|_| Refusal::ManualRequired("resolve-failed"))?
        .collect();
    if addrs.is_empty() {
        return Err(Refusal::ManualRequired("no-address"));
    }
    let mut allowed = Vec::new();
    for address in addrs {
        if is_public(&address.ip()) {
            allowed.push(address);
        }
    }
    if allowed.is_empty() {
        return Err(Refusal::ManualRequired("private-address"));
    }
    Ok(allowed)
}

/// Whether an address is safe to connect to from a user's machine.
pub fn is_public(ip: &IpAddr) -> bool {
    // A test that spins up a local server is the only caller allowed through,
    // and only in a debug build with the switch set on purpose.
    if loopback_allowed() && ip.is_loopback() {
        return true;
    }
    match ip {
        IpAddr::V4(ip) => is_public_v4(ip),
        IpAddr::V6(ip) => is_public_v6(ip),
    }
}

fn loopback_allowed() -> bool {
    cfg!(debug_assertions)
        && std::env::var("LAGOON_UNSUBSCRIBE_ALLOW_LOOPBACK")
            .map(|value| value == "1")
            .unwrap_or(false)
}

fn is_public_v4(ip: &Ipv4Addr) -> bool {
    let octets = ip.octets();
    !(ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_multicast()
        || ip.is_unspecified()
        // 100.64.0.0/10 - carrier-grade NAT, often the LAN side of a router.
        || (octets[0] == 100 && (64..=127).contains(&octets[1]))
        // 0.0.0.0/8 "this network" and 198.18.0.0/15 benchmarking.
        || octets[0] == 0
        || (octets[0] == 198 && (octets[1] == 18 || octets[1] == 19))
        // 169.254.0.0/16 covers the cloud metadata endpoint (169.254.169.254).
        || (octets[0] == 169 && octets[1] == 254))
}

fn is_public_v6(ip: &Ipv6Addr) -> bool {
    // An IPv4-mapped address must pass the IPv4 rules, not slip past them.
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(&v4);
    }
    !(ip.is_loopback()
        || ip.is_unspecified()
        || ip.is_multicast()
        // Unique-local fc00::/7 and link-local fe80::/10.
        || (ip.segments()[0] & 0xfe00) == 0xfc00
        || (ip.segments()[0] & 0xffc0) == 0xfe80
        // Deprecated site-local fec0::/10.
        || (ip.segments()[0] & 0xffc0) == 0xfec0)
}

/// Who performs the request.
///
/// A trait, not a free function, so the route tests can answer without a
/// socket: everything about *whether* to send lives in the guards above, and
/// the guards are tested against real names and addresses. This is the same
/// seam `ProviderFactory` gives the mail paths.
pub trait Firer: Send + Sync {
    fn fire(&self, target: &Target) -> Reply;
}

/// The real one: TLS to the vetted address.
pub struct RealFirer;

impl Firer for RealFirer {
    fn fire(&self, target: &Target) -> Reply {
        fire(target)
    }
}

/// Send the one-click POST and map the answer.
///
/// Blocking on purpose: the TLS stack in this tree is synchronous, so the
/// route runs this on `spawn_blocking` rather than pretending it is async.
pub fn fire(target: &Target) -> Reply {
    let addresses = match public_addresses(&target.host, target.port) {
        Ok(addresses) => addresses,
        Err(refusal) => {
            return Reply::Failed {
                reason: refusal.label().to_owned(),
            }
        }
    };
    let mut transport = TlsTransport::with_read_timeout(REQUEST_TIMEOUT);
    let mut connected = false;
    for address in &addresses {
        match transport.connect_to(&target.host, *address) {
            Ok(()) => {
                connected = true;
                break;
            }
            Err(error) => {
                tracing::warn!(host = %target.host, err = ?error, "unsubscribe.connectFailed");
            }
        }
    }
    if !connected {
        return Reply::Failed {
            reason: "unreachable".to_owned(),
        };
    }
    let request = HttpRequest {
        host: target.host.clone(),
        port: target.port,
        path: target.path.clone(),
        headers: vec![
            ("User-Agent".to_owned(), "Lagoon/0.4.1".to_owned()),
            (
                "Content-Type".to_owned(),
                "application/x-www-form-urlencoded".to_owned(),
            ),
            ("Accept".to_owned(), "*/*".to_owned()),
        ],
        body: ONE_CLICK_BODY.as_bytes().to_vec(),
    };
    let outcome = http::exchange(&mut transport, &request);
    transport.close();
    let response = match outcome {
        Ok(response) => response,
        Err(error) => {
            tracing::warn!(host = %target.host, err = %error, "unsubscribe.requestFailed");
            return Reply::Failed {
                reason: "request-failed".to_owned(),
            };
        }
    };
    let publisher = target.host.clone();
    match response.status {
        200..=299 => Reply::Unsubscribed {
            status: response.status,
            publisher,
        },
        // RFC 8058 §3.2: 404/410 mean the subscription is already gone.
        404 | 410 => Reply::Unsubscribed {
            status: response.status,
            publisher,
        },
        300..=399 => Reply::Failed {
            reason: "redirect".to_owned(),
        },
        status => Reply::Failed {
            reason: format!("http-{status}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn links(url: &str, one_click: bool) -> String {
        format!(r#"[{{"url":"{url}","kind":"https","oneClick":{one_click}}}]"#)
    }

    #[test]
    fn a_declared_one_click_target_is_the_only_automatic_one() {
        let target = one_click_target(&links("https://a.example/u", true)).expect("target");
        assert_eq!(target, "https://a.example/u");
        assert_eq!(
            one_click_target(&links("https://a.example/u", false)),
            Err(Refusal::PageRequired)
        );
        assert_eq!(
            one_click_target(r#"[{"url":"mailto:x@a.example","kind":"mailto"}]"#),
            Err(Refusal::Unavailable)
        );
        assert_eq!(one_click_target("[]"), Err(Refusal::Unavailable));
        assert_eq!(one_click_target("not json"), Err(Refusal::Unavailable));
    }

    #[test]
    fn the_url_guard_refuses_every_escape_route() {
        let refused = [
            ("http://a.example/u", "not-https"),
            ("https://user:pw@a.example/u", "userinfo"),
            ("https://a.example:8443/u", "nonstandard-port"),
            ("https://127.0.0.1/u", "ip-literal"),
            ("https://[::1]/u", "ip-literal"),
        ];
        for (url, label) in refused {
            assert_eq!(
                parse_target(url),
                Err(Refusal::ManualRequired(label)),
                "{url}"
            );
        }
        let target = parse_target("https://A.Example/u?x=1").expect("valid");
        assert_eq!(target.host, "a.example");
        assert_eq!(target.port, 443);
        assert_eq!(target.path, "/u?x=1");
        // A URL with no path still has one to request.
        assert_eq!(parse_target("https://a.example").expect("valid").path, "/");
    }

    #[test]
    fn private_and_metadata_addresses_are_not_public() {
        let refused = [
            "127.0.0.1",
            "10.1.2.3",
            "192.168.1.1",
            "172.16.0.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "198.18.0.1",
            "::1",
            "fe80::1",
            "fd00::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
        ];
        for raw in refused {
            let ip: IpAddr = raw.parse().expect("ip");
            assert!(!is_public(&ip), "{raw} must be refused");
        }
        for raw in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] {
            let ip: IpAddr = raw.parse().expect("ip");
            assert!(is_public(&ip), "{raw} must be allowed");
        }
    }

    #[test]
    fn a_refusal_maps_to_the_contract_code() {
        assert_eq!(Refusal::Unavailable.code(), "unsubscribe-unavailable");
        assert_eq!(Refusal::PageRequired.code(), "unsubscribe-page-required");
        assert_eq!(
            Refusal::ManualRequired("userinfo").code(),
            "unsubscribe-manual-required"
        );
    }
}
