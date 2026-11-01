//! TLS verification test: the *production* rustls client configuration must
//! reject a self-signed certificate. The handshake runs entirely in memory —
//! two rustls state machines exchanging buffers — so there is no socket, no DNS
//! and no network, while still exercising the real certificate verifier.
//!
//! This is the Rust counterpart of the v3 rule "NIOSSL default trust roots,
//! no accept-anything option": a server with a self-signed or incomplete chain
//! must fail, and there must be no fallback that retries without verification.

use std::sync::Arc;

use lagoon_mail::tls::client_config;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use rustls::{ClientConnection, ServerConfig, ServerConnection};

fn server_config() -> Arc<ServerConfig> {
    let certificate =
        CertificateDer::from(include_bytes!("fixtures/self-signed-cert.der").to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        include_bytes!("fixtures/self-signed-key.der").to_vec(),
    ));
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![certificate], key)
        .expect("fixture certificate/key pair");
    Arc::new(config)
}

#[test]
fn production_config_rejects_a_self_signed_certificate() {
    let config = client_config().expect("platform verifier configuration");
    let server_name = ServerName::try_from("imap.invalid.test").expect("valid DNS name");
    let mut client = ClientConnection::new(config, server_name).expect("client connection");
    let mut server = ServerConnection::new(server_config()).expect("server connection");

    let mut to_server = Vec::new();
    let mut to_client = Vec::new();
    let mut handshake_error = None;

    for _ in 0..16 {
        to_server.clear();
        client.write_tls(&mut to_server).ok();
        if !to_server.is_empty() {
            let mut reader: &[u8] = &to_server;
            if server.read_tls(&mut reader).is_err() {
                break;
            }
            if let Err(error) = server.process_new_packets() {
                handshake_error = Some(format!("{error:?}"));
                break;
            }
        }

        to_client.clear();
        server.write_tls(&mut to_client).ok();
        if !to_client.is_empty() {
            let mut reader: &[u8] = &to_client;
            if client.read_tls(&mut reader).is_err() {
                break;
            }
            match client.process_new_packets() {
                Ok(_) => {}
                Err(error) => {
                    handshake_error = Some(format!("{error:?}"));
                    break;
                }
            }
        }

        if !client.is_handshaking() {
            break;
        }
    }

    let error = handshake_error.expect("the handshake must fail for an untrusted certificate");
    assert!(
        client.is_handshaking(),
        "the client completed a handshake with an untrusted certificate: {error}"
    );
    assert!(
        !client.is_handshaking()
            || error.to_lowercase().contains("certificate")
            || error.to_lowercase().contains("unknownissuer")
            || error.to_lowercase().contains("invalid certificate"),
        "unexpected TLS failure: {error}"
    );
}
