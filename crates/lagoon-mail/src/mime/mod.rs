//! RFC 5322 / MIME: headers, charset decoding, transfer encodings and the
//! recursive part walker, plus the builder for outbound messages.
//!
//! Nothing here throws. Mailboxes contain truncated, mislabeled and outright
//! broken messages, and the contract (v3 `MIMEParser`) is that the worst case
//! is a shorter string — never a failed request. The parser therefore returns
//! `ParsedMessage` for any byte slice, including one that is not a message at
//! all.
//!
//! The charset table is the incident-earned part: QQ mail is routinely GBK
//! (`charset="gb2312"` on the wire), and decoding it as Latin-1 turns every
//! CJK byte into mojibake. `encoding_rs` is the same WHATWG decoder table the
//! v3 build reached through CoreFoundation.

pub mod builder;
pub mod charset;
pub mod headers;
pub mod html;
pub mod parser;
pub mod unsubscribe;

pub use builder::{
    build_new_message, build_reply, OutboundAttachment, OutboundMessage, MAX_ATTACHMENT_BYTES,
};
pub use parser::{
    parse, parse_with_options, parse_with_policy, AttachmentDisposition, DecodePolicy,
    ParsedAttachment, ParsedMessage,
};
