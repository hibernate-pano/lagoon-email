//! lagoon-api - the v4 read-only backend, R1.
//!
//!     export LAGOON_BODY_KEY=...            # base64 of the 32-byte body key
//!     export LAGOON_API_TOKEN=...           # optional; enables bearer auth
//!     cargo run                             # serves v4/.dev/data/lagoon.sqlite
//!     cargo run -- --db /path/lagoon.sqlite --port 18099
//!
//! See README.md for the contract this binary answers.

use std::process::ExitCode;
use std::sync::Arc;

use lagoon_api::config::Config;
use lagoon_api::db::Db;
use lagoon_api::http::{self, AppState};
use lagoon_api::telemetry;

#[tokio::main]
async fn main() -> ExitCode {
    telemetry::init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|argument| argument == "--help" || argument == "-h") {
        print_usage();
        return ExitCode::SUCCESS;
    }

    // --migrate is a mode, not a setting: it creates/applies the v3 migration
    // chain and exits without binding a port. It is stripped before Config::load
    // so the config parser keeps refusing genuinely unknown flags.
    let migrate_only = args.iter().any(|argument| argument == "--migrate");
    let filtered: Vec<String> = args
        .iter()
        .filter(|argument| argument.as_str() != "--migrate")
        .cloned()
        .collect();

    let config = match Config::load(&filtered) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };

    if migrate_only {
        return match run_migrate(&config) {
            Ok(()) => ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("{message}");
                ExitCode::FAILURE
            }
        };
    }

    match run(config).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

/// Create or update the store, then exit. The equivalent of v3 opening the
/// database once: eleven migrations, GRDB bookkeeping, data repairs included.
fn run_migrate(config: &Config) -> Result<(), String> {
    let connection =
        lagoon_api::db::open_writable(config.db_path.clone()).map_err(|error| error.to_string())?;
    let report = lagoon_api::store::migrate::migrate(&connection, Some(&config.body_key))
        .map_err(|error| error.to_string())?;
    if report.applied.is_empty() {
        println!(
            "{}: already at lagoon-v10 ({} migrations recorded)",
            config.db_path.display(),
            report.already_present
        );
    } else {
        println!(
            "{}: applied {} migration(s): {}",
            config.db_path.display(),
            report.applied.len(),
            report.applied.join(", ")
        );
    }
    tracing::info!(applied = report.applied.len(), already = report.already_present, "migrated");
    Ok(())
}

async fn run(config: Config) -> Result<(), String> {
    // Fresh install: no store yet. Create one and apply the v3 migration chain,
    // which is what the v3 server did at startup ("applied automatically").
    // An existing store is still opened read-only and validated strictly below,
    // so a foreign or newer schema keeps failing closed.
    if !std::path::Path::new(&config.db_path).exists() {
        if let Some(parent) = std::path::Path::new(&config.db_path).parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
        }
        let connection = lagoon_api::db::open_writable(config.db_path.clone())
            .map_err(|error| error.to_string())?;
        let report = lagoon_api::store::migrate::migrate(&connection, Some(&config.body_key))
            .map_err(|error| error.to_string())?;
        tracing::info!(applied = report.applied.len(), "fresh store: migrated");
    }
    let db = Db::open_read_only(config.db_path.clone()).map_err(|error| error.to_string())?;

    // open_read_only already validated the schema and refused if it did not
    // match what R1 reads; the report is re-read here only to be logged.
    match db.validate_schema() {
        Ok(report) => {
            if !report.unknown_migrations.is_empty() {
                tracing::warn!(
                    migrations = ?report.unknown_migrations,
                    "store carries migrations newer than this build knows; the columns R1 reads all validated"
                );
            }
            tracing::info!(applied = report.migrations.len(), "schema verified");
        }
        Err(error) => return Err(error.to_string()),
    }

    let db = Arc::new(db);
    tracing::info!(
        host = %config.host,
        port = config.port,
        db = %db.path().display(),
        auth = config.api_token.is_some(),
        "starting"
    );

    // Provider wiring is a deployment decision, not a build feature:
    //   LAGOON_MAIL_PROVIDER=none        (default) no provider at all, so a
    //                                     contract run can never touch the net;
    //   LAGOON_MAIL_PROVIDER=production  the real lagoon-mail/TLS adapter.
    // Anything else refuses to start rather than guess which one was meant.
    let provider_mode = std::env::var("LAGOON_MAIL_PROVIDER").unwrap_or_else(|_| "none".to_owned());
    let mut state = AppState::new(Arc::clone(&db), &config);
    match provider_mode.as_str() {
        "none" => {}
        "production" => {
            state = state.with_provider_factory(Arc::new(
                lagoon_api::provider::lagoon_mail::LagoonMailFactory::production(),
            ));
        }
        other => {
            return Err(format!(
                "unknown LAGOON_MAIL_PROVIDER={other:?}: use none or production"
            ));
        }
    }
    // v3 starts one sync loop per connected account before it serves. With
    // provider none, start_all starts none, so a read-only store keeps its
    // recorded health instead of being rewritten to no-provider.
    state.sync.start_all().await;
    let listener = tokio::net::TcpListener::bind((config.host.as_str(), config.port))
        .await
        .map_err(|error| format!("cannot bind {}:{}: {error}", config.host, config.port))?;
    let bound = listener
        .local_addr()
        .map_err(|error| format!("cannot read the bound address: {error}"))?;
    // The *actual* port, not the configured one: with --port 0 v3 reports 0 back
    // and a supervisor cannot find the server. Printing the real port costs a
    // line and makes ephemeral ports usable.
    tracing::info!(port = bound.port(), "listening");
    // Machine-readable companion to the log line above. The shell spawns the
    // backend with --port 0 and must learn the port the kernel assigned; the
    // alternative - the shell picking a free port and handing it over - is a
    // TOCTOU: another process can take that port between the probe and the
    // bind, and the healthz handshake sends the API token to whoever holds it.
    println!("LAGOON_PORT={}", bound.port());
    use std::io::Write as _;
    let _ = std::io::stdout().flush();

    axum::serve(listener, http::router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|error| format!("server failed: {error}"))
}

async fn shutdown_signal() {
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(_) => std::future::pending().await,
        }
    };
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = terminate => {}
    }
    tracing::info!("stopping");
}

fn print_usage() {
    println!("usage: lagoon-api [--migrate] [--db PATH] [--host ADDR] [--port PORT]");
    println!();
    println!("  --migrate create/upgrade the store to lagoon-v10 and exit");
    println!("  --db    SQLite store to read (default: v4/.dev/data/lagoon.sqlite;");
    println!("          LAGOON_DB_PATH and LAGOON_V4_DATA_DIR are also honoured)");
    println!("  --host  bind address (default 127.0.0.1, or LAGOON_SERVER_HOST)");
    println!("  --port  bind port (default 8080, or LAGOON_SERVER_PORT; 0 = ephemeral)");
    println!();
    println!("environment:");
    println!("  LAGOON_BODY_KEY    required, base64 of the 32-byte body key");
    println!("  LAGOON_API_TOKEN   optional, bearer token; also required for a non-loopback bind");
    println!();
    println!("secrets come from the environment only, never from argv: arguments are");
    println!("visible in ps to every local process.");
}
