//! A scripted AI transport for tests.
//!
//! Same shape as the mail fake: every call pops one scripted answer, and every
//! request is recorded so a test can assert exactly what would have been sent.
//! No socket, no DNS, no TLS - the CI never reaches the internet.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use super::transport::{AiFuture, AiReply, AiRequest, AiTransport, AiTransportError};

pub struct ScriptedTransport {
    script: Arc<Mutex<VecDeque<Result<AiReply, AiTransportError>>>>,
    calls: Arc<Mutex<Vec<AiRequest>>>,
}

impl ScriptedTransport {
    pub fn new() -> Self {
        Self {
            script: Arc::new(Mutex::new(VecDeque::new())),
            calls: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Script the next answers, in call order.
    pub fn script(&self, outcomes: Vec<Result<AiReply, AiTransportError>>) -> &Self {
        self.script.lock().expect("ai script lock").extend(outcomes);
        self
    }

    /// Every request the transport was asked to send, in order.
    pub fn calls(&self) -> Vec<AiRequest> {
        self.calls.lock().expect("ai calls lock").clone()
    }
}

impl Default for ScriptedTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl AiTransport for ScriptedTransport {
    fn chat(&self, request: AiRequest) -> AiFuture<'_> {
        self.calls
            .lock()
            .expect("ai calls lock")
            .push(request.clone());
        let next = self.script.lock().expect("ai script lock").pop_front();
        Box::pin(async move {
            match next {
                Some(result) => result,
                // An exhausted script is a test mistake: surfacing it beats an
                // empty answer that hides the extra call.
                None => Err(AiTransportError::Unreachable(
                    "fake ai script exhausted".to_owned(),
                )),
            }
        })
    }
}
