//! The SQL v3 runs, ported statement for statement.
//!
//! Every query here is a transcription of `Sources/LagoonServer/Storage/*`,
//! and the comments point at the Swift function it came from. The clause shapes
//! matter as much as the results: `filterSQL` in particular is the single
//! definition of "which list is this message in", and a list that disagrees
//! with its badge is the class of bug the v3 comments spend pages on.

pub mod accounts;
pub mod actions;
pub mod advice;
pub mod bodies;
pub mod briefing;
pub mod drafts;
pub mod messages;
/// The migration engine (v3's eleven migrations, translated).
pub mod migrate;
pub mod notices;
pub mod reminders;
pub mod search;
pub mod senders;
pub mod stacks;
/// The cached AI summaries (`message_summaries`).
pub mod summaries;
pub mod usage;
/// The writable store: accounts, headers, bodies, pins, audit, drafts.
pub mod write;

#[derive(Debug)]
pub enum StoreError {
    Sqlite(rusqlite::Error),
    /// A row the Swift decoder would have thrown on (`AccountStore.decode`).
    UnknownProvider(String),
    /// `StackRule.Kind` is a two-value enum in v3; anything else throws there.
    BadStackKind(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            StoreError::UnknownProvider(provider) => {
                write!(formatter, "unknown mail provider {provider:?}")
            }
            StoreError::BadStackKind(kind) => write!(formatter, "unknown stack rule kind {kind:?}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        StoreError::Sqlite(error)
    }
}
