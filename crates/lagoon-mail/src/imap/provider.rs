//! Account-level IMAP provider: connection reuse, folder roles, the UIDPLUS
//! gate, and the read-only sync seam.
//!
//! Ported from v3 `IMAPProvider.swift`, but deliberately without storage and
//! without the sync loop: R3.1 is the protocol layer. The provider still owns
//! the two rules that must never move down into a route or up into an engine:
//!
//! 1. **Folder roles are account data.** archive/trash/sent come from
//!    SPECIAL-USE or a leaf-name heuristic; only archive has a CREATE fallback.
//!    A missing Trash is `TrashUnavailable`, never an invented folder — inventing
//!    one would fake the delete/undo semantics the whole product rests on.
//! 2. **Permanent delete is UIDPLUS-only.** `permanently_delete` and
//!    `empty_trash` check the capability *before* issuing any command. Without
//!    UIDPLUS they return `capability-missing` and the wire stays untouched; the
//!    operation is never approximated with a plain EXPUNGE, which would remove
//!    every `\\Deleted` message in the folder (including another client's) and
//!    cannot be undone.
//!
//! Likewise the no-MOVE fallback is COPY + UID STORE \\Deleted + **UID**
//! EXPUNGE, and it refuses to run without UIDPLUS rather than degrade: v3's
//! `deleteExactly` fallback included the blanket EXPUNGE the R3 plan forbids.

use std::collections::HashSet;
use std::time::Duration;

use crate::error::{MailError, MailErrorKind};
use crate::imap::capabilities::{
    self, discover_roles, is_reserved_folder, FolderRoles, MailCapabilities, INBOX,
};
use crate::imap::client::{ImapClient, ImapFetchedHeader, ImapSelected, DEFAULT_HEADER_FIELDS};
use crate::imap::membership::{self, FolderMembership, RemoteMembership};
use crate::mime::headers::{
    decode_rfc2047, parse_from_header, parse_header_block, split_head_and_body,
};
use crate::mime::parser::{self, ParsedMessage};
use crate::preset::ProviderPreset;
use crate::sync::{self, ChangeSet, MailSyncReading, RemoteHeader, SyncCursor};
use crate::timefmt::now_unix;
use crate::transport::{TlsTransport, Transport};
use crate::MailFolder;

/// First-sync window, in **messages** (v3 `backfillWindow`).
///
/// A message count, never a UID range: IMAP burns a UID forever on every
/// expunge, move and append, so a mailbox archived from for years has a sparse
/// UID space where 500 slots hold far fewer messages. Measured against a real
/// QQ mailbox: 13733 UID slots, 265 messages, and the window reached only the
/// newest ~43 — the rest was silently never fetched while health read `ok`.
pub const BACKFILL_WINDOW: usize = 500;

/// The most Sent messages a single listing will return.
pub const SENT_WINDOW_MAX: usize = 500;

/// One IDLE stretch. The loop leaves IDLE, re-SELECTs and re-enters, so a long
/// wait never exceeds the protocol's IDLE ceiling.
pub const IDLE_BUDGET: Duration = Duration::from_secs(290);

/// Poll cadence when the server has no IDLE.
pub const POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Single-attachment cap, aligned with the 25 MB limit the big providers
/// enforce so the client gets a uniform UX.
pub const MAX_ATTACHMENT_BYTES: usize = crate::mime::builder::MAX_ATTACHMENT_BYTES;

/// Credentials held for the lifetime of the provider. Debug is redacted: a
/// derived `Debug` on this struct is how secrets reach a log line.
#[derive(Clone)]
pub struct ProviderCredentials {
    username: String,
    secret: String,
}

impl ProviderCredentials {
    pub fn new(username: impl Into<String>, secret: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            secret: secret.into(),
        }
    }

    pub fn username(&self) -> &str {
        &self.username
    }

    pub fn secret(&self) -> &str {
        &self.secret
    }
}

impl std::fmt::Debug for ProviderCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderCredentials")
            .field("username", &self.username)
            .field("secret", &"<redacted>")
            .finish()
    }
}

/// How a provider builds a fresh transport. Production uses implicit TLS; the
/// test suite injects a scripted fake. The factory (not a single transport) is
/// what lets the provider reconnect after a dead session.
pub type TransportFactory = Box<dyn Fn() -> Box<dyn Transport> + Send>;

/// The bytes of one attachment plus the metadata needed to set Content-Type /
/// Content-Disposition on the way out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchedAttachmentBytes {
    pub mime_type: String,
    pub filename: Option<String>,
    pub data: Vec<u8>,
}

/// One inline picture: the bytes plus the `Content-ID` the HTML refers to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchedInlineImage {
    /// The content id without the angle brackets, as the HTML's `cid:` uses it.
    pub content_id: String,
    pub mime_type: String,
    pub data: Vec<u8>,
}

pub struct ImapProvider {
    preset: ProviderPreset,
    credentials: ProviderCredentials,
    make_transport: TransportFactory,
    client: Option<ImapClient>,
    selected: Option<ImapSelected>,
    capabilities: Option<MailCapabilities>,
    roles: Option<FolderRoles>,
    /// Set when a CREATE for the default archive folder was refused. v3 kept
    /// this verdict for the provider's life; here it lasts for the session,
    /// which is the same protection without pinning a transient failure to the
    /// account forever.
    archive_create_refused: bool,
}

impl ImapProvider {
    pub fn new(
        preset: ProviderPreset,
        credentials: ProviderCredentials,
        make_transport: TransportFactory,
    ) -> Self {
        Self {
            preset,
            credentials,
            make_transport,
            client: None,
            selected: None,
            capabilities: None,
            roles: None,
            archive_create_refused: false,
        }
    }

    /// Production constructor: implicit TLS 993/465 with full certificate
    /// verification.
    pub fn tls(preset: ProviderPreset, credentials: ProviderCredentials) -> Self {
        Self::new(
            preset,
            credentials,
            Box::new(|| Box::new(TlsTransport::new()) as Box<dyn Transport>),
        )
    }

    pub fn preset(&self) -> ProviderPreset {
        self.preset
    }

    /// Negotiates the server's capabilities.
    ///
    /// `None` means the negotiation did not complete — a dead socket, a refused
    /// LIST. It does **not** mean "this server has no capabilities": a blip
    /// recorded as "no capabilities" turned a momentary network problem into a
    /// feature that stayed off for the life of the account.
    pub fn capabilities(&mut self) -> Option<MailCapabilities> {
        // Negotiated once per live session, cached like v3's
        // `cachedCapabilities`: a second call must not spend another LIST (or
        // another CREATE attempt).
        if let Some(capabilities) = &self.capabilities {
            return Some(capabilities.clone());
        }
        let negotiated = self.with_client(|client, selected| {
            *selected = None;
            capabilities::negotiate(client, true)
        });
        match negotiated {
            Ok(negotiated) => {
                self.roles = Some(negotiated.roles);
                self.capabilities = Some(negotiated.capabilities.clone());
                Some(negotiated.capabilities)
            }
            Err(_) => None,
        }
    }

    /// Connectivity + credential check used by the connect flow: login, role
    /// resolution (including the archive CREATE fallback) and a forced INBOX
    /// SELECT.
    pub fn probe(&mut self) -> Result<(), MailError> {
        let negotiated = self.with_client(|client, selected| {
            let negotiated = capabilities::negotiate(client, true)?;
            *selected = Some(client.select(INBOX)?);
            Ok(negotiated)
        })?;
        self.roles = Some(negotiated.roles);
        self.capabilities = Some(negotiated.capabilities);
        Ok(())
    }

    /// The inbox/archive/trash membership sets, read on **one** session.
    ///
    /// This is the replacement for lagoon-api opening three extra connections
    /// per pull round. The order is LIST (only when roles are not cached) →
    /// SELECT each folder → UID SEARCH ALL → a Message-ID header walk, all on
    /// the same authenticated connection. Reading membership is read-only, so
    /// neither MOVE nor UIDPLUS is required.
    ///
    /// Each folder is independently tri-state (see [`RemoteMembership`]).
    /// A folder that is missing, forbidden, larger than `budget`, or whose UID
    /// set cannot be mapped completely yields `None`; if the socket dies, the
    /// remaining folders are `None` too. A caller must treat `None` as unknown
    /// and must not delete local rows on that basis.
    ///
    /// Unlike [`Self::capabilities`], this never CREATEs a missing archive
    /// folder: a read path must not mutate the mailbox, and a just-created
    /// empty archive would be indistinguishable from "all archived mail is
    /// gone" (which would license a wrong delete).
    pub fn remote_membership(&mut self) -> RemoteMembership {
        self.remote_membership_with_budget(membership::DEFAULT_MEMBERSHIP_BUDGET)
    }

    /// Same as [`Self::remote_membership`] with an explicit walk budget.
    /// The budget bounds both the folder's `EXISTS` count and the `UID SEARCH
    /// ALL` result, so a huge mailbox is reported unknown instead of being
    /// walked for minutes.
    pub fn remote_membership_with_budget(&mut self, budget: usize) -> RemoteMembership {
        let cached_roles = self.roles.clone();
        let needs_roles = cached_roles.is_none();
        let mut session_dead = false;
        let outcome = self.with_client(|client, selected| {
            let roles = match cached_roles {
                Some(roles) => roles,
                None => {
                    let mailboxes = client.list_mailboxes()?;
                    discover_roles(&mailboxes)
                }
            };
            let inbox = collect_membership(client, selected, INBOX, budget, &mut session_dead);
            let archive = if session_dead {
                None
            } else {
                match roles.archive.as_deref() {
                    Some(folder) => {
                        collect_membership(client, selected, folder, budget, &mut session_dead)
                    }
                    None => None,
                }
            };
            let trash = if session_dead {
                None
            } else {
                match roles.trash.as_deref() {
                    Some(folder) => {
                        collect_membership(client, selected, folder, budget, &mut session_dead)
                    }
                    None => None,
                }
            };
            Ok((
                RemoteMembership {
                    inbox,
                    archive,
                    trash,
                },
                roles,
            ))
        });
        match outcome {
            Ok((membership, roles)) => {
                if needs_roles {
                    self.roles = Some(roles);
                }
                if session_dead {
                    self.drop_connection();
                }
                membership
            }
            Err(_) => {
                if session_dead {
                    self.drop_connection();
                }
                RemoteMembership::default()
            }
        }
    }

    /// Body on demand: plain text, optional HTML, attachment metadata +
    /// decoded bytes, and a truncation flag.
    /// Body on demand. `uid_hint` is the server UID sync already stored for
    /// this row: when it still points at the same message, the fetch is one
    /// `UID FETCH` instead of the search-then-full-scan resolution path.
    pub fn fetch_body(
        &mut self,
        remote_id: &str,
        uid_hint: Option<i64>,
    ) -> Result<ParsedMessage, MailError> {
        let raw = self.fetch_raw_message_with_hint(remote_id, uid_hint)?;
        Ok(parser::parse(&raw))
    }

    /// Body on demand with attachment bytes decoded (the download route's
    /// shape).
    pub fn fetch_body_with_attachments(
        &mut self,
        remote_id: &str,
    ) -> Result<ParsedMessage, MailError> {
        let raw = self.fetch_raw_message(remote_id)?;
        Ok(parser::parse_with_options(&raw, true))
    }

    /// One attachment's raw bytes by its provider-native id (the IMAP part
    /// path).
    pub fn fetch_attachment(
        &mut self,
        remote_id: &str,
        attachment_id: &str,
    ) -> Result<FetchedAttachmentBytes, MailError> {
        self.fetch_attachment_with_hint(remote_id, None, attachment_id)
    }

    /// One attachment's bytes, with the UID the sync loop stored for this row.
    ///
    /// The hint turns the fetch into one `UID FETCH`; without it the provider
    /// resolves the message by identity, which on QQ means a search that comes
    /// back empty followed by a whole-mailbox scan.
    ///
    /// Only the requested part is decoded. A mail that carries a 25 MB file
    /// must not pay for decoding it to answer a question about a small picture.
    pub fn fetch_attachment_with_hint(
        &mut self,
        remote_id: &str,
        uid_hint: Option<i64>,
        attachment_id: &str,
    ) -> Result<FetchedAttachmentBytes, MailError> {
        let raw = self.fetch_raw_message_with_hint(remote_id, uid_hint)?;
        // The download route DOES need the bytes, so decode them here (the body
        // route skips this via the default false).
        let parsed =
            parser::parse_with_policy(&raw, &parser::DecodePolicy::Part(attachment_id.to_owned()));
        let attachment = parsed
            .attachments
            .into_iter()
            .find(|attachment| attachment.id == attachment_id)
            .ok_or_else(MailError::attachment_not_found)?;
        if attachment.data.len() > MAX_ATTACHMENT_BYTES {
            return Err(MailError::too_large("attachment-too-large"));
        }
        Ok(FetchedAttachmentBytes {
            mime_type: attachment.mime_type,
            filename: attachment.filename,
            data: attachment.data,
        })
    }

    /// The message's inline pictures, with the content ids the HTML refers to.
    ///
    /// One fetch, one parse: the reader resolves every `cid:` in the body, so
    /// asking for the pictures one at a time would re-download the whole
    /// message for each of them.
    pub fn fetch_inline_images_with_hint(
        &mut self,
        remote_id: &str,
        uid_hint: Option<i64>,
    ) -> Result<Vec<FetchedInlineImage>, MailError> {
        let raw = self.fetch_raw_message_with_hint(remote_id, uid_hint)?;
        let parsed = parser::parse_with_policy(&raw, &parser::DecodePolicy::InlineImages);
        Ok(parsed
            .attachments
            .into_iter()
            // Inline *and* an image: the policy decoded exactly those, and a
            // file attachment that happens to carry a Content-ID is not a
            // `cid:` target (its bytes were not decoded either).
            .filter(|attachment| {
                attachment.disposition == parser::AttachmentDisposition::Inline
                    && attachment.mime_type.starts_with("image/")
            })
            .filter_map(|attachment| {
                let content_id = attachment.content_id?;
                Some(FetchedInlineImage {
                    content_id,
                    mime_type: attachment.mime_type,
                    data: attachment.data,
                })
            })
            .collect())
    }

    /// Original RFC 5322 message bytes (for .eml export).
    ///
    /// Archived and trashed messages are no longer in INBOX, but opening one
    /// must still work. A Message-ID is the only identity that survives a
    /// move, so after INBOX says gone the same id is re-resolved in the
    /// Archive and Trash role folders. Numeric/`uid:` ids are mailbox-local
    /// and are never chased across folders: a UID means something different
    /// (or nothing) in another mailbox.
    pub fn fetch_raw_message(&mut self, remote_id: &str) -> Result<Vec<u8>, MailError> {
        self.fetch_raw_message_with_hint(remote_id, None)
    }

    pub fn fetch_raw_message_with_hint(
        &mut self,
        remote_id: &str,
        uid_hint: Option<i64>,
    ) -> Result<Vec<u8>, MailError> {
        if let Some(uid) = uid_hint {
            match self.fetch_at_stored_uid(remote_id, uid) {
                Ok(Some(raw)) => return Ok(raw),
                // Stale hint (the UID is gone or now holds another message):
                // resolve by identity instead.
                Ok(None) => {}
                Err(error) => return Err(error),
            }
        }
        let miss = match self.with_inbox(|client, _selected| {
            let uid = resolve_uid(remote_id, client)?;
            client.fetch_full_body(uid)
        }) {
            Ok(raw) => return Ok(raw),
            Err(error) if error.kind() == MailErrorKind::MessageGone => error,
            Err(error) => return Err(error),
        };
        if is_mailbox_local_id(remote_id) {
            return Err(miss);
        }

        let roles = self.ensure_roles()?;
        let mut folders: Vec<String> = Vec::new();
        for folder in [roles.archive, roles.trash].into_iter().flatten() {
            if folder != INBOX && !folders.contains(&folder) {
                folders.push(folder);
            }
        }
        for folder in folders {
            let result = self.with_client(|client, selected| {
                *selected = Some(client.select(&folder)?);
                let uid = resolve_uid(remote_id, client)?;
                client.fetch_full_body(uid)
            });
            match result {
                Ok(raw) => return Ok(raw),
                // Not in this folder either; keep looking.
                Err(error) if error.kind() == MailErrorKind::MessageGone => continue,
                // A transport/auth failure is not evidence of absence: surface
                // it rather than finishing the search and reporting "gone".
                Err(error) => return Err(error),
            }
        }
        Err(miss)
    }

    /// The stored-UID fast path. Sync already read this message's UID off the
    /// wire, so opening its body is one `UID FETCH` instead of a server-side
    /// Message-ID search (which QQ answers empty) followed by a whole-mailbox
    /// header scan.
    ///
    /// A UID is scoped to one mailbox and one UIDVALIDITY. The local store
    /// wipes rows when UIDVALIDITY changes, but a stale row can still race a
    /// resync, and a UID that now holds a *different* message must never be
    /// served: the fetched bytes are checked against the Message-ID the row is
    /// keyed by. `Ok(None)` means "hint unusable, resolve by identity".
    fn fetch_at_stored_uid(
        &mut self,
        remote_id: &str,
        uid: i64,
    ) -> Result<Option<Vec<u8>>, MailError> {
        // A numeric/`uid:` id already *is* a UID; the hint adds nothing and
        // cannot be verified against a Message-ID.
        if is_mailbox_local_id(remote_id) {
            return Ok(None);
        }
        let raw = match self.with_inbox(|client, _selected| client.fetch_full_body(uid)) {
            Ok(raw) => raw,
            Err(error) if error.kind() == MailErrorKind::MessageGone => return Ok(None),
            Err(error) => return Err(error),
        };
        if message_id_of(&raw).as_deref() == Some(remote_id) {
            Ok(Some(raw))
        } else {
            Ok(None)
        }
    }

    /// Raw header values for one message (e.g. List-Unsubscribe at click time).
    pub fn fetch_raw_header_values(
        &mut self,
        remote_id: &str,
    ) -> Result<std::collections::BTreeMap<String, String>, MailError> {
        self.with_inbox(|client, _selected| {
            let uid = resolve_uid(remote_id, client)?;
            client
                .fetch_header(uid, &DEFAULT_HEADER_FIELDS)?
                .into_iter()
                .next()
                .map(|header| header.raw_headers)
                .ok_or_else(MailError::message_gone)
        })
    }

    pub fn set_read(&mut self, remote_id: &str, is_read: bool) -> Result<(), MailError> {
        self.with_inbox(|client, _selected| {
            let uid = resolve_uid(remote_id, client)?;
            if is_read {
                client.store(uid, &["\\Seen"], &[])
            } else {
                client.store(uid, &[], &["\\Seen"])
            }
        })
    }

    pub fn archive(&mut self, remote_id: &str) -> Result<(), MailError> {
        let folder = self
            .resolve_archive()?
            .ok_or_else(MailError::archive_unavailable)?;
        self.with_inbox(|client, _selected| {
            let uid = resolve_uid(remote_id, client)?;
            move_safely(client, uid, &folder)
        })
    }

    pub fn unarchive(&mut self, remote_id: &str) -> Result<(), MailError> {
        let folder = self
            .resolve_archive()?
            .ok_or_else(MailError::archive_unavailable)?;
        self.with_client(|client, selected| {
            *selected = Some(client.select(&folder)?);
            let uid = resolve_uid(remote_id, client)?;
            move_safely(client, uid, INBOX)?;
            *selected = None;
            Ok(())
        })
    }

    /// Delete = move to the server's Trash folder, never a hard expunge.
    pub fn trash(&mut self, remote_id: &str) -> Result<(), MailError> {
        let folder = self.resolve_trash()?;
        self.with_inbox(|client, _selected| {
            let uid = resolve_uid(remote_id, client)?;
            move_safely(client, uid, &folder)
        })
    }

    /// Undo delete: move back from Trash to INBOX.
    pub fn restore_from_trash(&mut self, remote_id: &str) -> Result<(), MailError> {
        let folder = self.resolve_trash()?;
        self.with_client(|client, selected| {
            *selected = Some(client.select(&folder)?);
            let uid = resolve_uid(remote_id, client)?;
            move_safely(client, uid, INBOX)?;
            *selected = None;
            Ok(())
        })
    }

    /// 彻底删除 one message. **Irreversible.**
    ///
    /// UIDPLUS is required before **any** command is issued: without it a
    /// permanent delete cannot be scoped to one message, and this method
    /// returns `capability-missing` with an untouched session. The two-step is
    /// the IMAP dance for "delete exactly this": flag `\\Deleted`, then
    /// UID-EXPUNGE that one uid. The flag alone does nothing — it is the
    /// EXPUNGE that removes.
    pub fn permanently_delete(&mut self, remote_id: &str) -> Result<(), MailError> {
        let folder = self.resolve_trash()?;
        self.with_client(|client, selected| {
            *selected = Some(client.select(&folder)?);
            let uid = resolve_uid(remote_id, client)?;
            if !client.capability()?.contains("UIDPLUS") {
                *selected = None;
                return Err(MailError::missing_capability("uidplus-missing"));
            }
            client.store(uid, &["\\Deleted"], &[])?;
            client.uid_expunge(uid)?;
            *selected = None;
            Ok(())
        })
    }

    /// 清空废纸篓: flag every UID in the Trash, then UID-EXPUNGE them as a set.
    /// Two round trips rather than a per-message loop, and — like the single
    /// path — never a blanket EXPUNGE. The UID set is read from *this* folder
    /// with *this* session's view.
    pub fn empty_trash(&mut self) -> Result<(), MailError> {
        let folder = self.resolve_trash()?;
        self.with_client(|client, selected| {
            *selected = Some(client.select(&folder)?);
            if !client.capability()?.contains("UIDPLUS") {
                *selected = None;
                return Err(MailError::missing_capability("uidplus-missing"));
            }
            let uids: Vec<i64> = client.all_uids()?.into_iter().collect();
            if uids.is_empty() {
                *selected = None;
                return Ok(());
            }
            for uid in &uids {
                client.store(*uid, &["\\Deleted"], &[])?;
            }
            client.uid_expunge_many(&uids)?;
            *selected = None;
            Ok(())
        })
    }

    /// The account's folders a message can be filed into. Reserved roles and
    /// their aliases are excluded; a name-only parent implied by a child path
    /// is still reported as having children (some servers omit `\\Noselect`
    /// parents from LIST entirely).
    pub fn list_folders(&mut self) -> Result<Vec<MailFolder>, MailError> {
        let mailboxes = self.with_client(|client, _| client.list_mailboxes())?;
        let mut child_paths = HashSet::new();
        for mailbox in &mailboxes {
            if let Some(position) = mailbox.name.rfind('/') {
                child_paths.insert(mailbox.name[..position].to_owned());
            }
        }
        let mut folders: Vec<MailFolder> = mailboxes
            .iter()
            .filter(|mailbox| !is_reserved_folder(mailbox))
            .filter_map(|mailbox| {
                let leaf = mailbox.name.rsplit('/').next()?;
                if leaf.is_empty() {
                    return None;
                }
                Some(MailFolder {
                    name: leaf.to_owned(),
                    path: mailbox.name.clone(),
                    has_children: child_paths.contains(&mailbox.name),
                })
            })
            .collect();
        folders.sort_by_key(|left| left.path.to_lowercase());
        Ok(folders)
    }

    /// Files a message into `folder`, creating it when `create_if_missing`.
    /// Returns `false` when the server refused and the message is **still where
    /// it was** — the caller must not claim success.
    pub fn move_message(
        &mut self,
        remote_id: &str,
        folder: &str,
        create_if_missing: bool,
    ) -> Result<bool, MailError> {
        let target = folder.trim();
        if target.is_empty() {
            return Ok(false);
        }
        self.with_inbox(|client, _selected| {
            // Not in the INBOX — it may be in Archive or Trash, where the UID
            // space belongs to a *different* folder. A UID is mailbox-local, so
            // reusing one here would move whatever message happens to hold that
            // UID in the INBOX. That is the worst outcome a move can have.
            let uid = resolve_uid(remote_id, client).map_err(|_| MailError::message_gone())?;

            if client.capability()?.contains("MOVE") {
                match client.move_to(uid, target) {
                    Ok(()) => return Ok(true),
                    // Advertised but refused; fall through to copy+delete rather
                    // than reporting a failure the fallback can still handle.
                    Err(error) if error.is_message_verdict() => {}
                    Err(error) => return Err(error),
                }
            }
            // The safe fallback needs UID EXPUNGE. Without UIDPLUS, copying and
            // leaving the original is not a move; refuse before any write.
            if !client.capability()?.contains("UIDPLUS") {
                return Err(MailError::unsafe_operation("move-needs-uidplus"));
            }
            match client.copy(uid, target) {
                Ok(()) => {}
                Err(error) if create_if_missing && error.is_message_verdict() => {
                    match client.create_mailbox(target) {
                        Ok(()) => {}
                        Err(error) if error.is_message_verdict() => return Ok(false),
                        Err(error) => return Err(error),
                    }
                    match client.copy(uid, target) {
                        Ok(()) => {}
                        Err(error) if error.is_message_verdict() => return Ok(false),
                        Err(error) => return Err(error),
                    }
                }
                Err(error) if error.is_message_verdict() => return Ok(false),
                Err(error) => return Err(error),
            }
            // Copy landed; the INBOX copy has to go or the message is in two
            // places. UID EXPUNGE removes exactly that one copy.
            client.store(uid, &["\\Deleted"], &[])?;
            client.uid_expunge(uid)?;
            Ok(true)
        })
    }

    /// Append already-sent RFC 5322 bytes to the account's Sent folder.
    ///
    /// The exact bytes SMTP delivered go in, so other clients see the message
    /// they would have seen had it been sent from them. A missing Sent folder
    /// is `sent-unavailable`; the caller has already delivered the mail and
    /// must not treat this as a failed send.
    pub fn append_to_sent(&mut self, raw: &[u8]) -> Result<(), MailError> {
        let folder = self.resolve_sent()?;
        self.with_client(|client, _selected| client.append(&folder, raw))
    }

    /// The newest headers in the account's Sent folder.
    pub fn list_sent(&mut self, limit: usize) -> Result<Vec<RemoteHeader>, MailError> {
        let folder = self.resolve_sent()?;
        let capped = limit.clamp(1, SENT_WINDOW_MAX);
        self.with_client(|client, selected| {
            let state = client.select(&folder)?;
            *selected = None;
            if state.exists == 0 {
                return Ok(Vec::new());
            }
            let fetched =
                client.fetch_newest_headers(capped, state.exists, &DEFAULT_HEADER_FIELDS)?;
            Ok(fetched.iter().map(remote_header).collect())
        })
    }

    /// Read-only pull used by the future sync engine. Protocol-level only: no
    /// storage, no loops, no backoff. `inbox_remote_ids` / `archived_remote_ids`
    /// / `trashed_remote_ids` / `removed_remote_ids` stay `None` here because
    /// proving a mailbox-wide membership set needs the store's UID mapping;
    /// `None` means "unknown" and the store must delete nothing on that basis.
    /// R3.4 fills those sets together with storage.
    pub fn pull_changes(
        &mut self,
        after: SyncCursor,
        wait_up_to: Duration,
    ) -> Result<ChangeSet, MailError> {
        self.with_client(|client, selected| {
            let state = client.select(INBOX)?;
            *selected = Some(state.clone());
            let mut state = state;
            let supports_idle = wait_up_to > Duration::ZERO
                && client
                    .capability()
                    .map(|capabilities| capabilities.contains("IDLE"))
                    .unwrap_or(false);
            // `waited` is only true when the IDLE really ran: a refused IDLE
            // returns at once, and reporting a wait that did not happen would
            // make the caller skip its own pause and spin.
            let mut waited = false;
            if supports_idle {
                // One bounded stretch; the event itself is not needed because
                // the FETCH below is the source of truth.
                waited = client.idle(wait_up_to).is_ok();
                state = client.select(INBOX)?;
                *selected = Some(state.clone());
            }
            let cursor = SyncCursor {
                uid_next: state.uid_next,
                uid_validity: state.uid_validity,
            };
            if after.uid_validity != 0 && after.uid_validity != state.uid_validity {
                // The UID space changed: every stored UID is meaningless. The
                // store must wipe before any of these numbers are reused.
                return Ok(ChangeSet {
                    reset_required: true,
                    cursor,
                    waited,
                    ..ChangeSet::default()
                });
            }
            let headers = if after.uid_next > 0 {
                client.fetch_headers_from_uid(after.uid_next, &DEFAULT_HEADER_FIELDS)?
            } else {
                client.fetch_newest_headers(
                    BACKFILL_WINDOW,
                    state.exists,
                    &DEFAULT_HEADER_FIELDS,
                )?
            };
            Ok(ChangeSet {
                upserts: headers.iter().map(remote_header).collect(),
                reset_required: false,
                cursor,
                waited,
                ..ChangeSet::default()
            })
        })
    }

    /// Hand the session back before the caller drops its last reference: QQ
    /// counts concurrent sessions per account, and a server-side session that
    /// lingers until its own timeout is a session the next connect cannot use.
    pub fn shutdown(&mut self) {
        self.drop_connection();
    }

    // ---- Internals ------------------------------------------------------

    fn ensure_client(&mut self) -> Result<(), MailError> {
        if self
            .client
            .as_ref()
            .map(|client| client.is_connected())
            .unwrap_or(false)
        {
            return Ok(());
        }
        if self.credentials.username().is_empty() || self.credentials.secret().is_empty() {
            return Err(MailError::not_configured("credentials-missing"));
        }
        let transport = (self.make_transport)();
        let mut client = ImapClient::new(transport);
        let (host, port) = self.preset.imap_endpoint();
        let mut failure = None;
        if let Err(error) = client.connect(host, port) {
            failure = Some(error);
        } else if let Err(error) =
            client.login(self.credentials.username(), self.credentials.secret())
        {
            failure = Some(error);
        } else if let Err(error) = client.send_id() {
            failure = Some(error);
        }
        if let Some(error) = failure {
            // A session that already failed on the socket must not spend the
            // full read timeout waiting for a LOGOUT reply that is never
            // coming. Only a server that is still talking gets the courtesy
            // round trip.
            if error.is_message_verdict() {
                client.logout();
            } else {
                client.disconnect();
            }
            return Err(error);
        }
        self.client = Some(client);
        self.selected = None;
        self.capabilities = None;
        self.roles = None;
        self.archive_create_refused = false;
        Ok(())
    }

    fn with_client<T>(
        &mut self,
        body: impl FnOnce(&mut ImapClient, &mut Option<ImapSelected>) -> Result<T, MailError>,
    ) -> Result<T, MailError> {
        self.ensure_client()?;
        let client = self.client.as_mut().expect("client connected above");
        let selected = &mut self.selected;
        let result = body(client, selected);
        if let Err(error) = &result {
            match error.kind() {
                MailErrorKind::Unreachable | MailErrorKind::AuthFailed => self.drop_connection(),
                MailErrorKind::MessageGone => self.selected = None,
                _ => {}
            }
        }
        result
    }

    fn with_inbox<T>(
        &mut self,
        body: impl FnOnce(&mut ImapClient, &mut Option<ImapSelected>) -> Result<T, MailError>,
    ) -> Result<T, MailError> {
        self.with_client(|client, selected| {
            select_inbox(client, selected)?;
            body(client, selected)
        })
    }

    fn drop_connection(&mut self) {
        if let Some(mut client) = self.client.take() {
            client.disconnect();
        }
        self.selected = None;
        self.roles = None;
    }

    fn ensure_roles(&mut self) -> Result<FolderRoles, MailError> {
        if let Some(roles) = &self.roles {
            return Ok(roles.clone());
        }
        let mailboxes = self.with_client(|client, _| client.list_mailboxes())?;
        let roles = discover_roles(&mailboxes);
        self.roles = Some(roles.clone());
        Ok(roles)
    }

    fn resolve_trash(&mut self) -> Result<String, MailError> {
        self.ensure_roles()?
            .trash
            .ok_or_else(MailError::trash_unavailable)
    }

    fn resolve_sent(&mut self) -> Result<String, MailError> {
        self.ensure_roles()?
            .sent
            .ok_or_else(MailError::sent_unavailable)
    }

    /// The archive role, with the one-time CREATE fallback. No CREATE for
    /// Trash/Sent: inventing them would fake delete and sent-listing semantics.
    fn resolve_archive(&mut self) -> Result<Option<String>, MailError> {
        let roles = self.ensure_roles()?;
        if let Some(name) = roles.archive {
            return Ok(Some(name));
        }
        if self.archive_create_refused {
            return Ok(None);
        }
        match self.with_client(|client, _| {
            client.create_mailbox(capabilities::DEFAULT_ARCHIVE_FOLDER_NAME)
        }) {
            Ok(()) => {
                let name = capabilities::DEFAULT_ARCHIVE_FOLDER_NAME.to_owned();
                if let Some(roles) = &mut self.roles {
                    roles.archive = Some(name.clone());
                }
                Ok(Some(name))
            }
            // A refusal is a verdict about the folder and is remembered as
            // "none"; a transport failure travels out so the next call retries
            // rather than latching a blip into a permanently disabled feature.
            Err(error) if error.is_message_verdict() => {
                self.archive_create_refused = true;
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }
}

impl MailSyncReading for ImapProvider {
    fn capabilities(&mut self) -> Option<MailCapabilities> {
        ImapProvider::capabilities(self)
    }

    fn pull_changes(
        &mut self,
        cursor: SyncCursor,
        wait_up_to: Duration,
    ) -> Result<ChangeSet, MailError> {
        ImapProvider::pull_changes(self, cursor, wait_up_to)
    }

    fn shutdown(&mut self) {
        ImapProvider::shutdown(self)
    }
}

/// One folder's membership, or `None` for every "cannot know" answer.
/// A transport/auth failure also marks the session dead so the caller stops
/// issuing commands to a socket that is already gone.
fn collect_membership(
    client: &mut ImapClient,
    selected: &mut Option<ImapSelected>,
    folder: &str,
    budget: usize,
    session_dead: &mut bool,
) -> Option<FolderMembership> {
    match membership::collect_folder(client, selected, folder, budget) {
        Ok(membership) => membership,
        Err(error) => {
            *selected = None;
            if matches!(
                error.kind(),
                MailErrorKind::Unreachable | MailErrorKind::AuthFailed
            ) {
                *session_dead = true;
            }
            None
        }
    }
}

fn select_inbox(
    client: &mut ImapClient,
    selected: &mut Option<ImapSelected>,
) -> Result<ImapSelected, MailError> {
    // The folder name is part of the check: `selected` may name Archive or
    // Trash after a move, and a UID from one of those means nothing in INBOX.
    if let Some(state) = selected {
        if state.mailbox == INBOX {
            return Ok(state.clone());
        }
    }
    let state = client.select(INBOX)?;
    *selected = Some(state.clone());
    Ok(state)
}

/// Numeric and `uid:` ids address a position inside one mailbox. They cannot
/// be re-resolved in another folder.
fn is_mailbox_local_id(remote_id: &str) -> bool {
    remote_id.parse::<i64>().is_ok()
        || remote_id
            .strip_prefix("uid:")
            .is_some_and(|rest| rest.parse::<i64>().is_ok())
}

/// UID is a mailbox-local position and can change after MOVE. New IMAP rows use
/// Message-ID as the stable identity; numeric values remain supported for rows
/// created before that migration (v3 `resolveUID`).
fn resolve_uid(remote_id: &str, client: &mut ImapClient) -> Result<i64, MailError> {
    if let Ok(uid) = remote_id.parse::<i64>() {
        return Ok(uid);
    }
    if let Some(rest) = remote_id.strip_prefix("uid:") {
        if let Ok(uid) = rest.parse::<i64>() {
            return Ok(uid);
        }
    }
    if let Some(uid) = client.search_uid_by_message_id(remote_id)? {
        return Ok(uid);
    }
    // QQ accepts HEADER SEARCH but can return an empty set even when the header
    // is present. The UID space is also sparse — a mailbox with 419 messages
    // can have UIDNEXT 13963 — so "the last N UIDs" is not a window on the
    // recent mail, it is a window on whatever happens to be near the newest
    // UID. The scan must cover the whole range the server reports.
    let headers = client.fetch_headers_from_uid(1, &["MESSAGE-ID"])?;
    for header in headers {
        if header
            .raw_headers
            .get("message-id")
            .map(|value| value.trim() == remote_id)
            .unwrap_or(false)
        {
            return Ok(header.uid);
        }
    }
    Err(MailError::message_gone())
}

/// The Message-ID a fetched raw message carries, if any. Used to check that a
/// stored UID still addresses the message the row is keyed by.
fn message_id_of(raw: &[u8]) -> Option<String> {
    let (header_block, _) = split_head_and_body(raw);
    parse_header_block(header_block)
        .get("message-id")
        .map(|value| value.trim().to_owned())
}

/// `UID MOVE` when the server has it, else COPY + UID STORE \\Deleted + UID
/// EXPUNGE. Never a plain EXPUNGE: that is folder-wide and can remove another
/// client's pending deletions.
fn move_safely(client: &mut ImapClient, uid: i64, target: &str) -> Result<(), MailError> {
    match client.move_to(uid, target) {
        Ok(()) => return Ok(()),
        Err(error) if error.is_message_verdict() => {}
        Err(error) => return Err(error),
    }
    if !client.capability()?.contains("UIDPLUS") {
        return Err(MailError::unsafe_operation("move-needs-uidplus"));
    }
    client.copy(uid, target)?;
    client.store(uid, &["\\Deleted"], &[])?;
    client.uid_expunge(uid)?;
    Ok(())
}

/// One wire header block → the provider-neutral row. RFC 2047 runs first: QQ
/// encodes Chinese subjects and display names as encoded-words.
fn remote_header(fetched: &ImapFetchedHeader) -> RemoteHeader {
    let decoded = |name: &str| -> Option<String> {
        fetched
            .raw_headers
            .get(name)
            .filter(|value| !value.is_empty())
            .map(|value| decode_rfc2047(value))
    };
    let unsubscribe = crate::mime::unsubscribe::parse_unsubscribe_headers(
        decoded("list-unsubscribe").as_deref(),
        decoded("list-unsubscribe-post").as_deref(),
    );
    let (from_address, from_name) = parse_from_header(decoded("from").as_deref().unwrap_or(""));
    let message_id = decoded("message-id");
    let references = decoded("references");
    RemoteHeader {
        remote_id: message_id
            .clone()
            .unwrap_or_else(|| format!("uid:{}", fetched.uid)),
        uid: fetched.uid,
        thread_id: sync::thread_id(references.as_deref(), message_id.as_deref(), fetched.uid),
        from_address,
        from_name,
        subject: decoded("subject"),
        snippet: None,
        received_at: fetched.internal_date.unwrap_or_else(now_unix),
        is_read: sync::is_read(&fetched.flags),
        // The boolean the briefing grouping uses, and the parsed links the
        // reader shows. Parsed here, at the one place a header block is turned
        // into a RemoteHeader, so the two can never disagree about whether the
        // mail offers a way out.
        list_unsubscribe: !unsubscribe.is_empty(),
        unsubscribe_links: unsubscribe.to_json(),
        message_id,
        in_reply_to: decoded("in-reply-to"),
        references,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credentials_debug_never_prints_the_secret() {
        let credentials = ProviderCredentials::new("user@example.com", "super-secret");
        let rendered = format!("{credentials:?}");
        assert!(!rendered.contains("super-secret"), "{rendered}");
        assert!(rendered.contains("redacted"), "{rendered}");
        assert_eq!(credentials.username(), "user@example.com");
        assert_eq!(credentials.secret(), "super-secret");
    }

    #[test]
    fn remote_header_uses_message_id_or_uid_identity() {
        let mut headers = std::collections::BTreeMap::new();
        headers.insert("message-id".to_owned(), "<m1@example.com>".to_owned());
        headers.insert(
            "from".to_owned(),
            "\"Chen, Qi\" <chen@example.com>".to_owned(),
        );
        headers.insert(
            "references".to_owned(),
            "<root@example.com> <m1@example.com>".to_owned(),
        );
        headers.insert("subject".to_owned(), "=?UTF-8?B?5L2g5aW9?=".to_owned());
        let fetched = ImapFetchedHeader {
            uid: 42,
            flags: vec!["\\Seen".to_owned()],
            internal_date: Some(1_789_034_400),
            raw_headers: headers,
        };
        let header = remote_header(&fetched);
        assert_eq!(header.remote_id, "<m1@example.com>");
        assert_eq!(header.uid, 42, "the wire UID must survive for body fetches");
        assert_eq!(header.thread_id, "<root@example.com>");
        assert_eq!(header.from_address, "chen@example.com");
        assert_eq!(header.from_name.as_deref(), Some("Chen, Qi"));
        assert_eq!(header.subject.as_deref(), Some("你好"));
        assert!(header.is_read);
        assert_eq!(header.received_at, 1_789_034_400);

        let bare = ImapFetchedHeader {
            uid: 7,
            flags: Vec::new(),
            internal_date: None,
            raw_headers: std::collections::BTreeMap::new(),
        };
        let header = remote_header(&bare);
        assert_eq!(header.remote_id, "uid:7");
        assert_eq!(header.uid, 7);
        assert!(!header.is_read);
    }
}
