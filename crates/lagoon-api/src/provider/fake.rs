//! A scripted provider for tests.
//!
//! Every branch of the connect route maps to one FakeOutcome here, and every
//! sync round pops one scripted result from a queue. The whole status matrix
//! and the whole sync engine can be exercised without a mail server, a socket,
//! or protocol code.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use crate::sync::SyncCursor;
use crate::token::ImapCredentials;
use crate::wire::MailCapabilities;

use super::{
    AttachmentFuture, BodyFuture, InlineImagesFuture, MailAttachment, MailBody, MailBodyProvider,
    MailChangeSet, MailInlineImage, MailProvider, MailSendProvider, MailWriteProvider,
    OutgoingMail, ProbeFuture, ProbeOutcome, ProviderError, ProviderFactory, PullFuture, RawFuture,
    SendFuture, SentMail, WriteFuture,
};

/// The scripted answers of the body provider, in call order.
type BodyScript = Arc<Mutex<VecDeque<Result<MailBody, ProviderError>>>>;
/// The scripted answers of the raw-message surface, in call order.
type RawScript = Arc<Mutex<VecDeque<Result<Vec<u8>, ProviderError>>>>;
/// The scripted answers of the send provider, in call order.
type SendScript = Arc<Mutex<VecDeque<Result<SentMail, ProviderError>>>>;
/// The scripted answers of the attachment download surface, in call order.
///
/// `Ok(None)` is a scripted "this message has no such part" — a fact, not a
/// failure, and the route answers 404 for it.
type AttachmentScript = Arc<Mutex<VecDeque<Result<Option<MailAttachment>, ProviderError>>>>;
/// The scripted answers of the inline-image surface, in call order.
type InlineImagesScript = Arc<Mutex<VecDeque<Result<Vec<MailInlineImage>, ProviderError>>>>;
/// What an attachment download was asked for: `(attachment id, uid hint)`.
type AttachmentCall = (String, Option<i64>);
/// Every attachment download this provider was asked for, in call order.
type AttachmentCalls = Arc<Mutex<Vec<AttachmentCall>>>;

#[derive(Debug, Clone)]
pub enum FakeOutcome {
    Succeeds {
        capabilities: Option<MailCapabilities>,
        archive_folder: Option<String>,
    },
    AuthFails,
    Unreachable(String),
    NotConfigured(String),
}

impl FakeOutcome {
    pub fn succeeds() -> Self {
        FakeOutcome::Succeeds {
            capabilities: None,
            archive_folder: None,
        }
    }

    pub fn with_capabilities(capabilities: MailCapabilities) -> Self {
        FakeOutcome::Succeeds {
            capabilities: Some(capabilities),
            archive_folder: Some("Archive".to_owned()),
        }
    }
}

/// What the fake saw, so a test can prove the route probed with the submitted
/// code rather than the stored (possibly stale) blob.
#[derive(Debug, Clone, Default)]
pub struct FakeCalls {
    inner: Arc<Mutex<Vec<ImapCredentials>>>,
}

impl FakeCalls {
    pub fn all(&self) -> Vec<ImapCredentials> {
        self.inner.lock().expect("calls lock").clone()
    }
}

pub struct FakeProvider {
    outcome: FakeOutcome,
    script: Arc<Mutex<VecDeque<Result<MailChangeSet, ProviderError>>>>,
    cursors: Arc<Mutex<Vec<SyncCursor>>>,
}

impl MailProvider for FakeProvider {
    fn probe(&self) -> ProbeFuture<'_> {
        let outcome = self.outcome.clone();
        Box::pin(async move {
            match outcome {
                FakeOutcome::Succeeds {
                    capabilities,
                    archive_folder,
                } => Ok(ProbeOutcome {
                    capabilities,
                    archive_folder,
                }),
                FakeOutcome::AuthFails => Err(ProviderError::AuthFailed),
                FakeOutcome::Unreachable(message) => Err(ProviderError::Unreachable(message)),
                FakeOutcome::NotConfigured(message) => Err(ProviderError::NotConfigured(message)),
            }
        })
    }

    fn pull_changes(&self, after: &SyncCursor) -> PullFuture<'_> {
        self.cursors.lock().expect("cursor log").push(after.clone());
        let next = self.script.lock().expect("script lock").pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                // A test that pulls more rounds than it scripted made a
                // mistake; surfacing it as a provider failure beats an empty
                // success that hides the extra round.
                None => Err(ProviderError::NotConfigured(
                    "fake script exhausted".to_owned(),
                )),
            }
        })
    }
}

/// One scripted write-verb answer.
#[derive(Debug, Clone)]
pub enum FakeWriteOutcome {
    Ok,
    ArchiveUnavailable,
    DeleteUnavailable,
    NotInTrash,
    Unreachable(String),
    MessageGone,
}

/// What write verbs saw, in order: (verb, remoteId).
#[derive(Debug, Clone, Default)]
pub struct FakeWriteCalls {
    inner: Arc<Mutex<Vec<(String, String)>>>,
}

impl FakeWriteCalls {
    pub fn all(&self) -> Vec<(String, String)> {
        self.inner.lock().expect("write calls lock").clone()
    }
}

pub struct FakeWriteProvider {
    script: Arc<Mutex<VecDeque<FakeWriteOutcome>>>,
    calls: FakeWriteCalls,
}

impl FakeWriteProvider {
    fn next_outcome(&self, verb: &str, remote_id: &str) -> Result<(), ProviderError> {
        self.calls
            .inner
            .lock()
            .expect("write calls lock")
            .push((verb.to_owned(), remote_id.to_owned()));
        let next = self.script.lock().expect("write script lock").pop_front();
        match next {
            Some(FakeWriteOutcome::Ok) | None => Ok(()),
            Some(FakeWriteOutcome::ArchiveUnavailable) => {
                Err(ProviderError::Protocol("archive-unavailable".to_owned()))
            }
            Some(FakeWriteOutcome::DeleteUnavailable) => {
                Err(ProviderError::Protocol("delete-unavailable".to_owned()))
            }
            Some(FakeWriteOutcome::NotInTrash) => {
                Err(ProviderError::Protocol("not-in-trash".to_owned()))
            }
            Some(FakeWriteOutcome::Unreachable(message)) => {
                Err(ProviderError::Unreachable(message))
            }
            Some(FakeWriteOutcome::MessageGone) => Err(ProviderError::MessageGone),
        }
    }
}

impl MailWriteProvider for FakeWriteProvider {
    fn set_read(&self, remote_id: &str, _is_read: bool) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        Box::pin(async move { self.next_outcome("set_read", &remote_id) })
    }
    fn archive(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        Box::pin(async move { self.next_outcome("archive", &remote_id) })
    }
    fn unarchive(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        Box::pin(async move { self.next_outcome("unarchive", &remote_id) })
    }
    fn trash(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        Box::pin(async move { self.next_outcome("trash", &remote_id) })
    }
    fn restore_from_trash(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        Box::pin(async move { self.next_outcome("restore_from_trash", &remote_id) })
    }
    fn permanently_delete(&self, remote_id: &str) -> WriteFuture<'_> {
        let remote_id = remote_id.to_owned();
        Box::pin(async move { self.next_outcome("permanently_delete", &remote_id) })
    }
    fn empty_trash(&self) -> WriteFuture<'_> {
        Box::pin(async move { self.next_outcome("empty_trash", "") })
    }
}

/// A scripted body provider: each `fetch_body` pops the next answer.
pub struct FakeBodyProvider {
    script: BodyScript,
    raw_script: RawScript,
    calls: Arc<Mutex<usize>>,
    raw_calls: Arc<Mutex<usize>>,
    uids: Arc<Mutex<Vec<Option<i64>>>>,
    attachment_script: AttachmentScript,
    inline_images_script: InlineImagesScript,
    attachment_calls: AttachmentCalls,
    inline_images_calls: Arc<Mutex<usize>>,
}

impl MailBodyProvider for FakeBodyProvider {
    fn fetch_body(&self, _remote_id: &str, uid_hint: Option<i64>) -> BodyFuture<'_> {
        *self.calls.lock().expect("body calls lock") += 1;
        self.uids.lock().expect("body uid lock").push(uid_hint);
        let next = self.script.lock().expect("body script lock").pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                // Same rule as pull_changes: an exhausted script is a test
                // mistake, and surfacing it beats a silent empty body.
                None => Err(ProviderError::NotConfigured(
                    "fake body script exhausted".to_owned(),
                )),
            }
        })
    }

    fn fetch_raw(&self, _remote_id: &str, uid_hint: Option<i64>) -> RawFuture<'_> {
        *self.raw_calls.lock().expect("raw calls lock") += 1;
        self.uids.lock().expect("body uid lock").push(uid_hint);
        let next = self.raw_script.lock().expect("raw script lock").pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                None => Err(ProviderError::NotConfigured(
                    "fake raw script exhausted".to_owned(),
                )),
            }
        })
    }

    fn fetch_attachment(
        &self,
        remote_id: &str,
        uid_hint: Option<i64>,
        attachment_id: &str,
    ) -> AttachmentFuture<'_> {
        self.attachment_calls
            .lock()
            .expect("attachment calls lock")
            .push((remote_id.to_owned(), uid_hint));
        let _ = attachment_id;
        let next = self
            .attachment_script
            .lock()
            .expect("attachment script lock")
            .pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                None => Err(ProviderError::NotConfigured(
                    "fake attachment script exhausted".to_owned(),
                )),
            }
        })
    }

    fn fetch_inline_images(
        &self,
        _remote_id: &str,
        _uid_hint: Option<i64>,
    ) -> InlineImagesFuture<'_> {
        *self.inline_images_calls.lock().expect("inline calls lock") += 1;
        let next = self
            .inline_images_script
            .lock()
            .expect("inline images script lock")
            .pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                None => Err(ProviderError::NotConfigured(
                    "fake inline images script exhausted".to_owned(),
                )),
            }
        })
    }
}

/// A scripted send provider: each `send` pops the next answer and records the
/// outgoing message, so a test can assert exactly what would have been sent
/// without a socket.
pub struct FakeSendProvider {
    script: Arc<Mutex<VecDeque<Result<SentMail, ProviderError>>>>,
    calls: Arc<Mutex<Vec<OutgoingMail>>>,
}

impl MailSendProvider for FakeSendProvider {
    fn send(&self, mail: OutgoingMail) -> SendFuture<'_> {
        self.calls.lock().expect("send calls lock").push(mail);
        let next = self.script.lock().expect("send script lock").pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                // An exhausted script still succeeds with a predictable id:
                // send tests that do not care about the id stay short.
                None => Ok(SentMail {
                    provider_message_id: Some("<fake-sent@lagoon>".to_owned()),
                }),
            }
        })
    }
}

pub struct FakeProviderFactory {
    outcome: FakeOutcome,
    calls: FakeCalls,
    script: Arc<Mutex<VecDeque<Result<MailChangeSet, ProviderError>>>>,
    cursors: Arc<Mutex<Vec<SyncCursor>>>,
    write_script: Arc<Mutex<VecDeque<FakeWriteOutcome>>>,
    write_calls: FakeWriteCalls,
    body_script: BodyScript,
    body_calls: Arc<Mutex<usize>>,
    raw_script: RawScript,
    raw_calls: Arc<Mutex<usize>>,
    body_uids: Arc<Mutex<Vec<Option<i64>>>>,
    send_script: SendScript,
    send_calls: Arc<Mutex<Vec<OutgoingMail>>>,
    attachment_script: AttachmentScript,
    inline_images_script: InlineImagesScript,
    attachment_calls: AttachmentCalls,
    inline_images_calls: Arc<Mutex<usize>>,
}

impl FakeProviderFactory {
    pub fn new(outcome: FakeOutcome) -> Self {
        Self {
            outcome,
            calls: FakeCalls::default(),
            script: Arc::new(Mutex::new(VecDeque::new())),
            cursors: Arc::new(Mutex::new(Vec::new())),
            write_script: Arc::new(Mutex::new(VecDeque::new())),
            write_calls: FakeWriteCalls::default(),
            body_script: Arc::new(Mutex::new(VecDeque::new())),
            body_calls: Arc::new(Mutex::new(0)),
            raw_script: Arc::new(Mutex::new(VecDeque::new())),
            raw_calls: Arc::new(Mutex::new(0)),
            body_uids: Arc::new(Mutex::new(Vec::new())),
            send_script: Arc::new(Mutex::new(VecDeque::new())),
            send_calls: Arc::new(Mutex::new(Vec::new())),
            attachment_script: Arc::new(Mutex::new(VecDeque::new())),
            inline_images_script: Arc::new(Mutex::new(VecDeque::new())),
            attachment_calls: Arc::new(Mutex::new(Vec::new())),
            inline_images_calls: Arc::new(Mutex::new(0)),
        }
    }

    /// Script the next attachment answers, in call order.
    ///
    /// `Ok(None)` scripts "this message has no such part": the route answers
    /// 404 for it, which is different from a message that is gone.
    pub fn attachment_script(
        &self,
        answers: Vec<Result<Option<MailAttachment>, ProviderError>>,
    ) -> &Self {
        self.attachment_script
            .lock()
            .expect("attachment script lock")
            .extend(answers);
        self
    }

    /// Every attachment download this factory was asked for: (remoteId, uid).
    pub fn attachment_calls(&self) -> Vec<(String, Option<i64>)> {
        self.attachment_calls
            .lock()
            .expect("attachment calls lock")
            .clone()
    }

    /// Script the next inline-image answers, in call order.
    pub fn inline_images_script(
        &self,
        answers: Vec<Result<Vec<MailInlineImage>, ProviderError>>,
    ) -> &Self {
        self.inline_images_script
            .lock()
            .expect("inline images script lock")
            .extend(answers);
        self
    }

    /// How many times the inline-image surface was asked.
    pub fn inline_images_calls(&self) -> usize {
        *self.inline_images_calls.lock().expect("inline calls lock")
    }

    /// Script the next raw-message answers, in call order.
    pub fn raw_script(&self, raws: Vec<Result<Vec<u8>, ProviderError>>) -> &Self {
        self.raw_script
            .lock()
            .expect("raw script lock")
            .extend(raws);
        self
    }

    /// How many times a body provider was asked for raw bytes.
    pub fn raw_calls(&self) -> usize {
        *self.raw_calls.lock().expect("raw calls lock")
    }

    /// Script the next send answers, in call order.
    pub fn send_script(&self, sends: Vec<Result<SentMail, ProviderError>>) -> &Self {
        self.send_script
            .lock()
            .expect("send script lock")
            .extend(sends);
        self
    }

    /// Every outgoing message this factory was asked to deliver, in order.
    pub fn send_calls(&self) -> Vec<OutgoingMail> {
        self.send_calls.lock().expect("send calls lock").clone()
    }

    /// Script the next body-fetch answers, in call order.
    pub fn body_script(&self, bodies: Vec<Result<MailBody, ProviderError>>) -> &Self {
        self.body_script
            .lock()
            .expect("body script lock")
            .extend(bodies);
        self
    }

    /// How many times a body provider was asked for a body.
    pub fn body_calls(&self) -> usize {
        *self.body_calls.lock().expect("body calls lock")
    }

    /// The UID hint each body fetch received, in call order.
    pub fn body_uids(&self) -> Vec<Option<i64>> {
        self.body_uids.lock().expect("body uid lock").clone()
    }

    /// Script the next write-verb answers, in call order. An exhausted script
    /// answers Ok - a write test that cares asserts on the call log instead.
    pub fn write_script(&self, outcomes: Vec<FakeWriteOutcome>) -> &Self {
        self.write_script
            .lock()
            .expect("write script lock")
            .extend(outcomes);
        self
    }

    /// Every write verb this factory answered: (verb, remoteId) in order.
    pub fn write_calls(&self) -> FakeWriteCalls {
        self.write_calls.clone()
    }

    /// A provider that probes successfully and answers each pull with the next
    /// scripted round.
    pub fn scripted(rounds: Vec<Result<MailChangeSet, ProviderError>>) -> Self {
        Self {
            outcome: FakeOutcome::succeeds(),
            calls: FakeCalls::default(),
            script: Arc::new(Mutex::new(rounds.into_iter().collect())),
            cursors: Arc::new(Mutex::new(Vec::new())),
            write_script: Arc::new(Mutex::new(VecDeque::new())),
            write_calls: FakeWriteCalls::default(),
            body_script: Arc::new(Mutex::new(VecDeque::new())),
            body_calls: Arc::new(Mutex::new(0)),
            raw_script: Arc::new(Mutex::new(VecDeque::new())),
            raw_calls: Arc::new(Mutex::new(0)),
            body_uids: Arc::new(Mutex::new(Vec::new())),
            send_script: Arc::new(Mutex::new(VecDeque::new())),
            send_calls: Arc::new(Mutex::new(Vec::new())),
            attachment_script: Arc::new(Mutex::new(VecDeque::new())),
            inline_images_script: Arc::new(Mutex::new(VecDeque::new())),
            attachment_calls: Arc::new(Mutex::new(Vec::new())),
            inline_images_calls: Arc::new(Mutex::new(0)),
        }
    }

    /// Queue pull rounds for every provider this factory builds: the sync
    /// loop the connect route starts runs one round per connect.
    pub fn pull_rounds(&self, rounds: Vec<Result<MailChangeSet, ProviderError>>) -> &Self {
        self.script.lock().expect("script lock").extend(rounds);
        self
    }

    pub fn calls(&self) -> FakeCalls {
        self.calls.clone()
    }

    /// The cursor each pull received, in order.
    pub fn cursors(&self) -> Vec<SyncCursor> {
        self.cursors.lock().expect("cursor log").clone()
    }
}

impl ProviderFactory for FakeProviderFactory {
    fn make(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailProvider>> {
        self.calls
            .inner
            .lock()
            .expect("calls lock")
            .push(credentials.clone());
        Some(Arc::new(FakeProvider {
            outcome: self.outcome.clone(),
            script: Arc::clone(&self.script),
            cursors: Arc::clone(&self.cursors),
        }))
    }

    fn make_write(&self, credentials: &ImapCredentials) -> Option<Arc<dyn MailWriteProvider>> {
        self.calls
            .inner
            .lock()
            .expect("calls lock")
            .push(credentials.clone());
        Some(Arc::new(FakeWriteProvider {
            script: Arc::clone(&self.write_script),
            calls: self.write_calls.clone(),
        }))
    }

    fn make_body(&self, _credentials: &ImapCredentials) -> Option<Arc<dyn MailBodyProvider>> {
        Some(Arc::new(FakeBodyProvider {
            script: Arc::clone(&self.body_script),
            raw_script: Arc::clone(&self.raw_script),
            calls: Arc::clone(&self.body_calls),
            raw_calls: Arc::clone(&self.raw_calls),
            uids: Arc::clone(&self.body_uids),
            attachment_script: Arc::clone(&self.attachment_script),
            inline_images_script: Arc::clone(&self.inline_images_script),
            attachment_calls: Arc::clone(&self.attachment_calls),
            inline_images_calls: Arc::clone(&self.inline_images_calls),
        }))
    }

    fn make_send(&self, _credentials: &ImapCredentials) -> Option<Arc<dyn MailSendProvider>> {
        Some(Arc::new(FakeSendProvider {
            script: Arc::clone(&self.send_script),
            calls: Arc::clone(&self.send_calls),
        }))
    }
}
