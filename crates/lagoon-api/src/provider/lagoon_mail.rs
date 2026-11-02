//! The production provider: lagoon-mail behind the provider seam.
//!
//! This module is an adapter and nothing else. IMAP framing, TLS, charset
//! decoding, folder-role discovery and folder membership all live in
//! lagoon-mail; here we translate credentials, capabilities, change sets and
//! error kinds, and we never speak a protocol byte ourselves.
//!
//! Blocking by design: lagoon-mail's transport is blocking, so every provider
//! call runs on a blocking thread. The engine already assumes one provider call
//! at a time per account; spawn_blocking keeps that off the async reactor.

use std::sync::Arc;

use lagoon_mail::error::{MailError, MailErrorKind};
use lagoon_mail::imap::capabilities::MailCapabilities as MailCapabilitiesWire;
use lagoon_mail::imap::provider::{ImapProvider, ProviderCredentials, IDLE_BUDGET};
use lagoon_mail::preset::ProviderPreset;
use lagoon_mail::sync::SyncCursor as MailSyncCursor;
use lagoon_mail::transport::{Transport, TlsTransport};
use lagoon_mail::{ChangeSet, RemoteHeader as MailRemoteHeader};

use crate::provider::{
    BodyFuture, MailBody, MailBodyProvider, MailChangeSet, MailProvider, MailWriteProvider,
    ProbeFuture, ProbeOutcome, ProviderError, ProviderFactory, PullFuture, RemoteHeader,
    WriteFuture,
};
use crate::sync::SyncCursor;
use crate::token::ImapCredentials;
use crate::wire::MailCapabilities;

/// Builds transports. Production is implicit TLS; tests inject their script.
pub type TransportFactory = Arc<dyn Fn() -> Box<dyn Transport> + Send + Sync>;

#[derive(Clone)]
pub struct LagoonMailFactory {
    transport: TransportFactory,
}

impl LagoonMailFactory {
    /// The production factory: implicit TLS 993/465 with the platform trust
    /// store (lagoon-mail's TlsTransport does the verification).
    pub fn production() -> Self {
        Self {
            transport: Arc::new(|| Box::new(TlsTransport::new())),
        }
    }

    pub fn with_transport(transport: TransportFactory) -> Self {
        Self { transport }
    }
}

struct LagoonMailProvider {
    transport: TransportFactory,
    credentials: ProviderCredentials,
    preset: ProviderPreset,
}

impl LagoonMailProvider {
    fn map_error(error: &MailError) -> ProviderError {
        match error.kind() {
            MailErrorKind::AuthFailed => ProviderError::AuthFailed,
            MailErrorKind::NotConfigured => {
                ProviderError::NotConfigured(error.kind().label().to_owned())
            }
            MailErrorKind::Unreachable => {
                ProviderError::Unreachable(error.kind().label().to_owned())
            }
            other => ProviderError::Protocol(other.label().to_owned()),
        }
    }

}

fn convert_capabilities(capabilities: MailCapabilitiesWire) -> MailCapabilities {
    MailCapabilities {
        archive_folder: capabilities.archive_folder,
        idle: capabilities.idle,
        move_supported: capabilities.supports_move,
        server_snippet: capabilities.server_snippet,
        uidplus: capabilities.uidplus,
        sent_folder: capabilities.sent_folder,
        trash_folder: capabilities.trash_folder,
        archive_folder_name: capabilities.archive_folder_name,
    }
}

fn convert_header(header: MailRemoteHeader) -> RemoteHeader {
    RemoteHeader {
        remote_id: header.remote_id,
        thread_id: header.thread_id,
        from_address: header.from_address,
        from_name: header.from_name,
        subject: header.subject,
        snippet: header.snippet,
        received_at: crate::timefmt::to_stored(crate::timefmt::Timestamp::from_millis(
            header.received_at * 1000,
        )),
        is_read: header.is_read,
        message_id_header: header.message_id,
        in_reply_to: header.in_reply_to,
        references: header.references,
        list_unsubscribe: header.list_unsubscribe,
        unsubscribe_links: "[]".to_owned(),
    }
}

impl MailProvider for LagoonMailProvider {
    fn probe(&self) -> ProbeFuture<'_> {
        let preset = self.preset;
        let transport = Arc::clone(&self.transport);
        let credentials = self.credentials.clone();
        Box::pin(async move {
            let factory = Arc::clone(&transport);
            let outcome = tokio::task::spawn_blocking(move || {
                let mut provider =
                    ImapProvider::new(preset, credentials, Box::new(move || (factory)()));
                provider.probe().map(|()| provider.capabilities())
            })
            .await
            .map_err(|_| ProviderError::Protocol("join".to_owned()))?;
            match outcome {
                Ok(negotiated) => Ok(ProbeOutcome {
                    capabilities: negotiated.map(convert_capabilities),
                    archive_folder: None,
                }),
                Err(error) => Err(LagoonMailProvider::map_error(&error)),
            }
        })
    }

    fn pull_changes(&self, after: &SyncCursor) -> PullFuture<'_> {
        let preset = self.preset;
        let transport = Arc::clone(&self.transport);
        let credentials = self.credentials.clone();
        let cursor = MailSyncCursor {
            uid_next: after.last_uid.map(|uid| uid + 1).unwrap_or(0),
            uid_validity: after.uid_validity.unwrap_or(0),
        };
        Box::pin(async move {
            let factory = Arc::clone(&transport);
            let pulled = tokio::task::spawn_blocking(move || {
                let mut provider =
                    ImapProvider::new(preset, credentials, Box::new(move || (factory)()));
                // A server with IDLE blocks here (bounded by IDLE_BUDGET)
                // until something happens; a server without it returns
                // immediately and the loop falls back to polling.
                let changes = provider.pull_changes(cursor, IDLE_BUDGET)?;
                // Membership runs on the SAME session the pull just used:
                // one login per round, not four. A reset round means the UID
                // space changed, so membership of the old generation would be
                // meaningless and stays unknown.
                let membership = if changes.reset_required {
                    None
                } else {
                    Some(provider.remote_membership())
                };
                Ok::<_, MailError>((changes, membership))
            })
            .await
            .map_err(|_| ProviderError::Protocol("join".to_owned()))?
            .map_err(|error| LagoonMailProvider::map_error(&error))?;
            let (changes, membership) = pulled;
            let (inbox, archived, trashed) = match membership {
                Some(membership) if !changes.reset_required => (
                    membership.inbox_remote_ids(),
                    membership.archived_remote_ids(),
                    membership.trashed_remote_ids(),
                ),
                _ => (None, None, None),
            };
            Ok(convert_change_set(changes, inbox, archived, trashed))
        })
    }
}

fn convert_change_set(
    changes: ChangeSet,
    inbox: Option<Vec<String>>,
    archived: Option<Vec<String>>,
    trashed: Option<Vec<String>>,
) -> MailChangeSet {
    MailChangeSet {
        cursor: SyncCursor {
            uid_validity: Some(changes.cursor.uid_validity),
            last_uid: Some(changes.cursor.uid_next.saturating_sub(1)),
        },
        reset_required: changes.reset_required,
        upserts: changes.upserts.into_iter().map(convert_header).collect(),
        replied_message_ids: changes.replied_message_ids.into_iter().collect(),
        inbox_remote_ids: inbox,
        archived_remote_ids: archived,
        trashed_remote_ids: trashed,
        removed_remote_ids: Vec::new(),
        waited: changes.waited,
    }
}

impl ProviderFactory for LagoonMailFactory {
    fn make(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailProvider>> {
        Some(Arc::new(LagoonMailProvider {
            transport: Arc::clone(&self.transport),
            credentials: ProviderCredentials::new(&credentials.username, &credentials.auth_code),
            preset: ProviderPreset::qq(),
        }))
    }

    fn make_write(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailWriteProvider>> {
        Some(Arc::new(LagoonMailWrite {
            transport: Arc::clone(&self.transport),
            credentials: ProviderCredentials::new(&credentials.username, &credentials.auth_code),
            preset: ProviderPreset::qq(),
        }))
    }

    fn make_body(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailBodyProvider>> {
        Some(Arc::new(LagoonMailBody {
            transport: Arc::clone(&self.transport),
            credentials: ProviderCredentials::new(&credentials.username, &credentials.auth_code),
            preset: ProviderPreset::qq(),
        }))
    }
}

/// The body half: one blocking FETCH per call, on a fresh session.
///
/// v3 reads the cache first and only reaches the provider on a miss, so this is
/// the cold path: a body is fetched at most once per message.
struct LagoonMailBody {
    transport: TransportFactory,
    credentials: ProviderCredentials,
    preset: ProviderPreset,
}

impl MailBodyProvider for LagoonMailBody {
    fn fetch_body(&self, remote_id: &str) -> BodyFuture<'_> {
        let transport = Arc::clone(&self.transport);
        let credentials = self.credentials.clone();
        let preset = self.preset;
        let remote_id = remote_id.to_owned();
        Box::pin(async move {
            let fetched = tokio::task::spawn_blocking(move || {
                let mut provider =
                    ImapProvider::new(preset, credentials, Box::new(move || (transport)()));
                provider.fetch_body(&remote_id)
            })
            .await
            .map_err(|_| ProviderError::Protocol("join".to_owned()))?
            .map_err(|error| LagoonMailProvider::map_error(&error))?;
            Ok(convert_body(fetched))
        })
    }
}

fn convert_body(parsed: lagoon_mail::ParsedMessage) -> MailBody {
    MailBody {
        text: parsed.text,
        html: parsed.html,
        has_more: parsed.has_more,
        attachments: parsed
            .attachments
            .into_iter()
            .map(|attachment| crate::wire::Attachment {
                id: attachment.id,
                filename: attachment.filename,
                mime_type: attachment.mime_type,
                size: attachment.size as i64,
                content_id: attachment.content_id,
                disposition: match attachment.disposition {
                    lagoon_mail::AttachmentDisposition::Inline => crate::wire::Disposition::Inline,
                    lagoon_mail::AttachmentDisposition::Attachment => {
                        crate::wire::Disposition::Attachment
                    }
                },
            })
            .collect(),
        to: parsed.to,
        cc: parsed.cc,
    }
}

/// The write half of the adapter.
///
/// lagoon-mail's write verbs are blocking (`&mut self` on `ImapProvider`), and
/// v3 opens write connections on demand ("write connections opened as needed"),
/// so every verb runs on a blocking thread with a fresh provider: one LOGIN per
/// user action, never held across requests.
struct LagoonMailWrite {
    transport: TransportFactory,
    credentials: ProviderCredentials,
    preset: ProviderPreset,
}

impl LagoonMailWrite {
    fn run<F>(&self, verb: F) -> WriteFuture<'_>
    where
        F: FnOnce(&mut ImapProvider) -> Result<(), MailError> + Send + 'static,
    {
        let transport = Arc::clone(&self.transport);
        let credentials = self.credentials.clone();
        let preset = self.preset;
        Box::pin(async move {
            let outcome = tokio::task::spawn_blocking(move || {
                let mut provider =
                    ImapProvider::new(preset, credentials, Box::new(move || (transport)()));
                verb(&mut provider)
            })
            .await
            .map_err(|_| ProviderError::Protocol("join".to_owned()))?;
            outcome.map_err(|error| LagoonMailProvider::map_error(&error))
        })
    }
}

impl MailWriteProvider for LagoonMailWrite {
    fn set_read(&self, remote_id: &str, is_read: bool) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        self.run(move |provider| provider.set_read(&remote_id, is_read))
    }

    fn archive(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        self.run(move |provider| provider.archive(&remote_id))
    }

    fn unarchive(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        self.run(move |provider| provider.unarchive(&remote_id))
    }

    fn trash(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        self.run(move |provider| provider.trash(&remote_id))
    }

    fn restore_from_trash(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        self.run(move |provider| provider.restore_from_trash(&remote_id))
    }

    fn permanently_delete(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        self.run(move |provider| provider.permanently_delete(&remote_id))
    }

    fn empty_trash(&self) -> WriteFuture<'_> {
        self.run(|provider| provider.empty_trash())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_conversion_keeps_the_three_state() {
        let converted = convert_capabilities(MailCapabilitiesWire {
            archive_folder: Some(true),
            idle: true,
            supports_move: false,
            server_snippet: true,
            uidplus: Some(false),
            sent_folder: None,
            trash_folder: Some(true),
            archive_folder_name: Some("Archive".to_owned()),
        });
        assert_eq!(converted.archive_folder, Some(true));
        assert_eq!(converted.uidplus, Some(false));
        assert_eq!(converted.sent_folder, None, "unknown stays absent");
        assert_eq!(converted.trash_folder, Some(true));
        assert_eq!(converted.archive_folder_name.as_deref(), Some("Archive"));
        assert!(!converted.move_supported);
    }

    #[test]
    fn error_kinds_map_to_the_provider_codes() {
        assert!(matches!(
            LagoonMailProvider::map_error(&MailError::new(MailErrorKind::AuthFailed, "x")),
            ProviderError::AuthFailed
        ));
        assert!(matches!(
            LagoonMailProvider::map_error(&MailError::new(MailErrorKind::NotConfigured, "x")),
            ProviderError::NotConfigured(_)
        ));
        assert!(matches!(
            LagoonMailProvider::map_error(&MailError::new(MailErrorKind::Unreachable, "x")),
            ProviderError::Unreachable(_)
        ));
        assert!(matches!(
            LagoonMailProvider::map_error(&MailError::new(MailErrorKind::Protocol, "x")),
            ProviderError::Protocol(_)
        ));
    }
}
