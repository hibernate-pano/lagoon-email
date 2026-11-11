//! The wire types, field for field.
//!
//! These are transcriptions of the shared `LagoonKit` types the v3 server and
//! the macOS client both decode (`recon/server-contract.md` §3.1): same keys,
//! same casing, same nullability. Two details carry most of the compatibility:
//!
//! * **A nil optional is an absent key, not `null`.** Foundation's synthesized
//!   `Encodable` skips nil optionals, and `recon/server-contract.md` §2 builds
//!   the "unknown versus false" contract on exactly that ("字段缺省即未知").
//!   Every optional here is `skip_serializing_if = "Option::is_none"` for that
//!   reason - `snippet: null` would be a different message from no `snippet`.
//! * **Dates are ISO-8601 with second precision.** [`crate::timefmt::Timestamp`]
//!   serialises itself; see that module for why the milliseconds disappear.

use serde::{Deserialize, Serialize};

use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

/// `MessageHeader` (`LagoonKit/MessageHeader.swift:3-30`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageHeader {
    pub id: Uuid,
    pub account_id: Uuid,
    pub remote_id: String,
    pub thread_id: String,
    pub from_address: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snippet: Option<String>,
    pub received_at: Timestamp,
    pub is_read: bool,
    pub is_archived: bool,
    pub is_deleted: bool,
    pub is_pinned: bool,
    pub is_sent: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id_header: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub in_reply_to: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub references: Option<String>,
}

/// `SyncCursor` (`LagoonKit/SyncCursor.swift:5-14`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncCursor {
    pub account_id: Uuid,
    pub last_fetched_at: Timestamp,
    pub total_unread: i64,
}

/// `SyncResponse` (`LagoonKit/SyncResponse.swift:4-15`).
///
/// `totalCount` counts the filter **ignoring** LIMIT, which is what lets the
/// client say "N more exist" instead of rendering a truncated list as complete.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncResponse {
    pub cursor: SyncCursor,
    pub messages: Vec<MessageHeader>,
    pub total_count: i64,
}

/// `SyncHealth` (`LagoonKit/SyncHealth.swift:5-41`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncHealth {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_sync_at: Option<Timestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

impl SyncHealth {
    /// v3 decodes an unrecognised `sync_status` as `.ok`
    /// (`AccountStore.decode`); the same fallback keeps the payload decodable
    /// for a client that only knows the five statuses.
    pub fn status_or_ok(raw: &str) -> String {
        const STATUSES: [&str; 5] = [
            "ok",
            "degraded",
            "needsReconnect",
            "error",
            "accountMissing",
        ];
        if STATUSES.contains(&raw) {
            raw.to_owned()
        } else {
            "ok".to_owned()
        }
    }
}

/// `MailCapabilities` (`LagoonKit/MailCapabilities.swift:31-118`).
///
/// The role flags are `Option<bool>` on purpose: absent means "not
/// determined", `false` means "determined: this server has none". Collapsing
/// the two is the data-loss-shaped bug the long comment on the Swift type
/// documents, so this copy keeps the distinction and the same defaults.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MailCapabilities {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive_folder: Option<bool>,
    #[serde(default)]
    pub idle: bool,
    #[serde(default, rename = "move")]
    pub move_supported: bool,
    #[serde(default)]
    pub server_snippet: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uidplus: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_folder: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trash_folder: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive_folder_name: Option<String>,
}

impl MailCapabilities {
    /// `MailCapabilities.unknown`: `archiveFolder` undetermined, the three
    /// plain bools false, every role flag absent.
    pub fn unknown() -> Self {
        Self::default()
    }
}

/// `ConnectedAccount` (`LagoonKit/ConnectedAccount.swift:13-20`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectedAccount {
    pub id: Uuid,
    pub provider: String,
    pub email: String,
    pub is_active: bool,
    pub unread_count: i64,
    pub sync_health: SyncHealth,
    pub capabilities: MailCapabilities,
}

/// One sidebar tally (`LagoonKit/FolderCounts.swift:14-22`).
#[derive(Debug, Clone, Serialize)]
pub struct FolderCount {
    pub id: String,
    pub count: i64,
}

/// `GET /api/folder-counts` response. Key order and membership follow
/// `FolderCounts.asCounts` - `sent` last, and always present here because this
/// server always computes it.
#[derive(Debug, Clone, Serialize)]
pub struct FolderCountsResponse {
    pub counts: Vec<FolderCount>,
}

impl FolderCountsResponse {
    pub fn new(
        live: i64,
        unread: i64,
        archived: i64,
        pinned: i64,
        deleted: i64,
        sent: i64,
    ) -> Self {
        Self {
            counts: vec![
                FolderCount {
                    id: "live".to_owned(),
                    count: live,
                },
                FolderCount {
                    id: "unread".to_owned(),
                    count: unread,
                },
                FolderCount {
                    id: "archived".to_owned(),
                    count: archived,
                },
                FolderCount {
                    id: "pinned".to_owned(),
                    count: pinned,
                },
                FolderCount {
                    id: "deleted".to_owned(),
                    count: deleted,
                },
                FolderCount {
                    id: "sent".to_owned(),
                    count: sent,
                },
            ],
        }
    }
}

/// `Attachment` (`LagoonKit/Briefing.swift:199-231`).
///
/// `Deserialize` is needed because the store keeps the attachment list as the
/// JSON of this same type (`message_bodies.attachments`); re-emitting the
/// decoded value is what keeps the response identical to v3's.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    pub mime_type: String,
    pub size: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_id: Option<String>,
    pub disposition: Disposition,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Disposition {
    Attachment,
    Inline,
}

/// `MessageBody` (`LagoonKit/Briefing.swift:124-193`).
///
/// `toAddress` is always absent on this route: v3's cache path passes
/// `toAddress: nil` unconditionally (`MessageRoutes.fetchBody`), and the
/// recipient list the client actually needs is `to`/`cc`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageBody {
    pub remote_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    pub from_address: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_address: Option<String>,
    pub received_at: Timestamp,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html: Option<String>,
    pub attachments: Vec<Attachment>,
    pub has_more: bool,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    /// The parsed `List-Unsubscribe` destinations, JSON text (an empty array
    /// when the sender offers no way out).
    ///
    /// Optional in the wire sense (§8: a new optional field is compatible), and
    /// it is a string rather than a typed array because the column is text and
    /// re-encoding it here would only add a failure mode.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unsubscribe_links: Option<String>,
}
