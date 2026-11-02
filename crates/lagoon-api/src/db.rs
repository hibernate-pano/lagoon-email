//! Read-only SQLite access.
//!
//! Three rules, all enforced here rather than at the call sites:
//!
//! 1. The store is opened with `SQLITE_OPEN_READ_ONLY` and every connection
//!    also sets `PRAGMA query_only = ON`. R1 has no write path, and a read-only
//!    handle is what makes that a property of the process instead of a promise.
//! 2. The schema is probed at startup. A store that is not the one R1 was
//!    written against - a v3 store older than `lagoon-v10`, or a file that is
//!    not a Lagoon store at all - **refuses to start** instead of failing later
//!    with an empty list. v3 keeps migration sovereignty (recon/server-contract
//!    §9); this crate never migrates.
//! 3. Queries run on a small pool of blocking connections via `spawn_blocking`,
//!    so an async handler never blocks the reactor on SQLite.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{Connection, OpenFlags, Row};

use crate::store::StoreError;
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

/// Connections opened at startup. R1 answers one user's reads; four is already
/// more than the server can use and keeps WAL readers cheap.
const POOL_SIZE: usize = 4;

const BUSY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// The migrations R1's SQL was read from (`LagoonDatabase.swift`, registration
/// order). A store missing any of these is older than the schema in
/// `recon/server-contract.md` §7 and is refused.
pub const KNOWN_MIGRATIONS: &[&str] = &[
    "lagoon-v1",
    "lagoon-v2",
    "lagoon-v3",
    "lagoon-v4",
    "lagoon-v5",
    "lagoon-v5b",
    "lagoon-v6",
    "lagoon-v7",
    "lagoon-v8",
    "lagoon-v9",
    "lagoon-v10",
];

/// v4's own migration, appended after v3's chain. It is additive (one nullable
/// column) and the read path works without it, so it is not *required* the way
/// the v3 list is — but a store carrying it is not "newer than this build
/// knows", and must not be reported as such.
pub const V4_MIGRATIONS: &[&str] = &["lagoon-v11"];

/// Whether `path` is a store this build may migrate: a SQLite file whose
/// `grdb_migrations` records the end of the v3 chain. Checked before opening
/// writable, so a foreign or truncated file is never written to.
pub fn looks_like_a_lagoon_store(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    let Ok(connection) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return false;
    };
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = 'lagoon-v10')",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(|found| found == 1)
        .unwrap_or(false)
}

/// Tables and columns R1 reads. The probe is column-level on purpose: a v3
/// migration that only *adds* columns must not stop the server, while one that
/// renames a column this crate selects has to.
pub const REQUIRED_SCHEMA: &[(&str, &[&str])] = &[
    (
        "accounts",
        &[
            "id",
            "provider",
            "email",
            "is_active",
            "sync_status",
            "last_sync_at",
            "last_sync_error",
            "capabilities",
        ],
    ),
    (
        "message_headers",
        &[
            "id",
            "account_id",
            "remote_id",
            "thread_id",
            "from_address",
            "from_name",
            "subject",
            "snippet_cipher",
            "received_at",
            "is_read",
            "is_archived",
            "is_deleted",
            "is_sent",
            "message_id_header",
            "in_reply_to",
            "references_header",
        ],
    ),
    ("message_pins", &["account_id", "remote_id"]),
    (
        "message_bodies",
        &[
            "account_id",
            "remote_id",
            "body_cipher",
            "body_html_cipher",
            "has_more",
            "attachments",
            "to_addresses",
            "cc_addresses",
        ],
    ),
    ("stack_rules", &["id", "account_id", "kind", "value"]),
    ("grdb_migrations", &["identifier"]),
];

#[derive(Debug)]
pub enum DbError {
    Missing(PathBuf),
    Open { path: PathBuf, message: String },
    Sqlite(rusqlite::Error),
    Store(StoreError),
    Schema(String),
    Task(String),
}

impl std::fmt::Display for DbError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DbError::Missing(path) => write!(
                formatter,
                "the store {} does not exist (R1 never creates or migrates one)",
                path.display()
            ),
            DbError::Open { path, message } => {
                write!(formatter, "cannot open {}: {message}", path.display())
            }
            DbError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            DbError::Store(error) => write!(formatter, "{error}"),
            DbError::Schema(message) => write!(formatter, "refusing this store: {message}"),
            DbError::Task(message) => write!(formatter, "worker failed: {message}"),
        }
    }
}

impl std::error::Error for DbError {}

impl From<rusqlite::Error> for DbError {
    fn from(error: rusqlite::Error) -> Self {
        DbError::Sqlite(error)
    }
}

impl From<StoreError> for DbError {
    fn from(error: StoreError) -> Self {
        DbError::Store(error)
    }
}

impl From<tokio::task::JoinError> for DbError {
    fn from(error: tokio::task::JoinError) -> Self {
        DbError::Task(error.to_string())
    }
}

impl From<crate::store::search::SearchError> for DbError {
    fn from(_error: crate::store::search::SearchError) -> Self {
        // A sealed value that will not open is unanswerable, not retryable; the
        // route turns every DbError into one 500 with a log line.
        DbError::Store(StoreError::Sqlite(rusqlite::Error::InvalidQuery))
    }
}

/// What the startup probe learned. Logged, not enforced: unknown migrations are
/// additive and the column probe already covers what this crate reads.
#[derive(Debug, Clone, Default)]
pub struct SchemaReport {
    pub migrations: Vec<String>,
    pub unknown_migrations: Vec<String>,
}

/// A read-only pool over one SQLite file.
pub struct Db {
    path: PathBuf,
    idle: Mutex<Vec<Connection>>,
}

/// Open a store for writing, creating the file when it does not exist.
///
/// This exists for the migration path only: the server itself always opens
/// read-only, and R3.2 does not serve writes yet. WAL is the journal v3 uses,
/// so a store this creates behaves the same under a concurrent reader.
pub fn open_writable(path: impl Into<PathBuf>) -> Result<Connection, DbError> {
    let path = path.into();
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|error| DbError::Open {
                path: path.clone(),
                message: error.to_string(),
            })?;
        }
    }
    let connection = Connection::open(&path).map_err(|error| DbError::Open {
        path: path.clone(),
        message: error.to_string(),
    })?;
    connection
        .execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        .map_err(DbError::Sqlite)?;
    Ok(connection)
}

impl Db {
    /// Open the store read-only and verify the schema.
    pub fn open_read_only(path: impl Into<PathBuf>) -> Result<Self, DbError> {
        let path = path.into();
        if !path.is_file() {
            return Err(DbError::Missing(path));
        }
        let mut connections = Vec::with_capacity(POOL_SIZE);
        for _ in 0..POOL_SIZE {
            connections.push(open_connection(&path)?);
        }
        let db = Self {
            path,
            idle: Mutex::new(connections),
        };
        db.validate_schema()?;
        Ok(db)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Probe the schema on a checked-out connection.
    pub fn validate_schema(&self) -> Result<SchemaReport, DbError> {
        let connection = self.checkout()?;
        let outcome = validate_schema(&connection);
        self.checkin(connection);
        outcome
    }

    /// Run `f` on a pooled connection, blocking the calling thread.
    pub fn with_connection<T, E, F>(&self, f: F) -> Result<T, DbError>
    where
        F: FnOnce(&Connection) -> Result<T, E>,
        E: Into<DbError>,
    {
        let connection = self.checkout()?;
        let outcome = f(&connection);
        self.checkin(connection);
        outcome.map_err(Into::into)
    }

    /// Run `f` on a pooled connection from an async context.
    ///
    /// The closure is `'static` and `Send` because it moves to a blocking
    /// worker; the pool hands it the only borrow it gets.
    pub async fn read<T, E, F>(self: &Arc<Self>, f: F) -> Result<T, DbError>
    where
        F: FnOnce(&Connection) -> Result<T, E> + Send + 'static,
        E: Into<DbError> + Send + 'static,
        T: Send + 'static,
    {
        let db = Arc::clone(self);
        tokio::task::spawn_blocking(move || db.with_connection(f)).await?
    }

    fn checkout(&self) -> Result<Connection, DbError> {
        let mut idle = self
            .idle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match idle.pop() {
            Some(connection) => Ok(connection),
            None => open_connection(&self.path),
        }
    }

    fn checkin(&self, connection: Connection) {
        let mut idle = self
            .idle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        idle.push(connection);
    }
}

fn open_connection(path: &Path) -> Result<Connection, DbError> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| DbError::Open {
        path: path.to_path_buf(),
        message: error.to_string(),
    })?;
    connection.busy_timeout(BUSY_TIMEOUT)?;
    // Belt and braces: the handle is already read-only, and `query_only` makes
    // even a future refactor that swaps the open flags fail at the first write.
    connection.execute_batch("PRAGMA query_only = ON;")?;
    Ok(connection)
}

fn validate_schema(connection: &Connection) -> Result<SchemaReport, DbError> {
    for (table, columns) in REQUIRED_SCHEMA {
        let present = table_columns(connection, table)?;
        if present.is_empty() {
            return Err(DbError::Schema(format!(
                "table `{table}` is missing - this is not a Lagoon store, or it predates the schema R1 reads"
            )));
        }
        for column in *columns {
            if !present.iter().any(|name| name == column) {
                return Err(DbError::Schema(format!(
                    "table `{table}` has no column `{column}` - the store is older than recon/server-contract.md §7"
                )));
            }
        }
    }

    let mut statement =
        connection.prepare("SELECT identifier FROM grdb_migrations ORDER BY rowid")?;
    let migrations: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let missing: Vec<&str> = KNOWN_MIGRATIONS
        .iter()
        .copied()
        .filter(|known| !migrations.iter().any(|applied| applied == known))
        .collect();
    if !missing.is_empty() {
        return Err(DbError::Schema(format!(
            "the store has not applied {} - R1 reads the v3.2.0 schema, and refusing is safer than guessing",
            missing.join(", ")
        )));
    }

    let unknown_migrations = migrations
        .iter()
        .filter(|applied| !KNOWN_MIGRATIONS.contains(&applied.as_str()))
        .filter(|applied| !V4_MIGRATIONS.contains(&applied.as_str()))
        .cloned()
        .collect();

    Ok(SchemaReport {
        migrations,
        unknown_migrations,
    })
}

fn table_columns(connection: &Connection, table: &str) -> Result<Vec<String>, DbError> {
    // The table name is a `&'static str` from REQUIRED_SCHEMA, never input.
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(columns)
}

// Column decoding shared by the store modules.

/// A BLOB (or text) UUID column. See [`Uuid::from_stored`] for the tolerance.
pub fn uuid_column(row: &Row<'_>, index: usize) -> rusqlite::Result<Uuid> {
    let raw = row.get_ref(index)?;
    let bytes: Vec<u8> = match raw {
        rusqlite::types::ValueRef::Blob(bytes) => bytes.to_vec(),
        rusqlite::types::ValueRef::Text(bytes) => bytes.to_vec(),
        rusqlite::types::ValueRef::Integer(value) => value.to_string().into_bytes(),
        other => {
            return Err(rusqlite::Error::FromSqlConversionFailure(
                index,
                other.data_type(),
                Box::new(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "account id is neither a 16-byte blob nor text",
                )),
            ))
        }
    };
    Uuid::from_stored(&bytes).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Blob,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "stored account id is not a UUID",
            )),
        )
    })
}

pub fn bool_column(row: &Row<'_>, index: usize) -> rusqlite::Result<bool> {
    Ok(row.get::<_, i64>(index)? != 0)
}

/// A stored timestamp column. `None` for NULL; an error for a value
/// `StoredDate` would refuse, because v3's row decoder would have thrown too.
pub fn timestamp_column(row: &Row<'_>, index: usize) -> rusqlite::Result<Timestamp> {
    let raw: Option<String> = row.get(index)?;
    crate::timefmt::parse(raw.as_deref()).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("stored date {raw:?} is not in the StoredDate format"),
            )),
        )
    })
}

pub fn optional_timestamp_column(
    row: &Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<Timestamp>> {
    let raw: Option<String> = row.get(index)?;
    Ok(crate::timefmt::parse(raw.as_deref()))
}
