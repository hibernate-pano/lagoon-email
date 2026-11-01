//! Trace output without `tracing-subscriber`.
//!
//! The offline registry cache this crate must build against has `tracing` but
//! not `tracing-subscriber` (see README, "依赖与离线构建"). Rather than leave
//! every `tracing::error!` silently discarded - a server whose only failure
//! signal is an empty log is worse than no logging - this module installs a
//! minimal `Subscriber` that writes one line per event to stderr.
//!
//! The line shape follows v3's swift-log default (`<time> <level> <target> :
//! <message>`) so a diff of two processes' logs stays readable. Fields are
//! appended as `key=value`.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Metadata, Subscriber};

/// Install the stderr subscriber. Idempotent-ish: a second call is ignored by
/// the global dispatcher.
pub fn init() {
    let _ = tracing::subscriber::set_global_default(StderrSubscriber::default());
}

#[derive(Default)]
struct StderrSubscriber {
    next_span: AtomicU64,
}

impl Subscriber for StderrSubscriber {
    fn enabled(&self, _metadata: &Metadata<'_>) -> bool {
        // R1 is small enough that every event is worth keeping; filtering is a
        // `RUST_LOG` question for whoever wires a real subscriber later.
        true
    }

    fn new_span(&self, _span: &Attributes<'_>) -> Id {
        Id::from_u64(self.next_span.fetch_add(1, Ordering::Relaxed) + 1)
    }

    fn record(&self, _span: &Id, _values: &Record<'_>) {}

    fn record_follows_from(&self, _span: &Id, _follows: &Id) {}

    fn event(&self, event: &Event<'_>) {
        let mut visitor = FieldVisitor::default();
        event.record(&mut visitor);
        let metadata = event.metadata();
        let level = level_name(metadata.level());
        let mut line = String::with_capacity(96);
        let _ = write!(
            line,
            "{} {} {} : {}",
            crate::timefmt::iso8601_now(),
            level,
            metadata.target(),
            visitor.message
        );
        for (name, value) in &visitor.fields {
            let _ = write!(line, " {}={}", name, value);
        }
        eprintln!("{line}");
    }

    fn enter(&self, _span: &Id) {}

    fn exit(&self, _span: &Id) {}
}

#[derive(Default)]
struct FieldVisitor {
    message: String,
    fields: Vec<(String, String)>,
}

impl Visit for FieldVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let rendered = format!("{value:?}");
        if field.name() == "message" {
            self.message = rendered;
        } else {
            self.fields.push((field.name().to_owned(), rendered));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = value.to_owned();
        } else {
            self.fields.push((field.name().to_owned(), value.to_owned()));
        }
    }
}

fn level_name(level: &tracing::Level) -> &'static str {
    match *level {
        tracing::Level::TRACE => "trace",
        tracing::Level::DEBUG => "debug",
        tracing::Level::INFO => "info",
        tracing::Level::WARN => "warning",
        tracing::Level::ERROR => "error",
    }
}
