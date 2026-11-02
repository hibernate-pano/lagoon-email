//! The triage classifier: one mail in, one suggestion out.
//!
//! The suggestion is **not** an action. It lands in the advice queue, where
//! the user reads it and decides; the click that archives or deletes is the
//! user's, in the action plane (constitution §2, rules 1 and 6).
//!
//! The classifier reads the mail's header - sender, subject, snippet - not
//! its body: a triage decision does not need the whole letter, and the
//! snippet is what the list screen already shows.

use super::gateway::{AiCompletion, AiError, AiGateway};

/// The system prompt.
///
/// The allowed values are spelled out because the queue only knows these
/// actions and categories: a suggestion the queue cannot show is a suggestion
/// the user never sees.
pub const CLASSIFY_SYSTEM: &str = "\
你是一个只读的邮件分诊助理。你只能阅读并给出建议，不能执行任何动作：不能发送、不能归档、不能删除、不能退订、不能标记已读。
只输出一个 JSON 对象，不要有任何多余文字：
{\"category\": \"personal|work|marketing|spam|notification|transactional|financial|logistics|newsletter|other\",
 \"action\": \"reply|wait|archive|delete|unsubscribe|remind|nothing\",
 \"confidence\": \"high|medium|low\",
 \"rationale\": \"一句话说明为什么这样建议，不超过 40 个字\",
 \"dueText\": \"有明确截止时间就写出来，没有就写空字符串\"}";

/// One suggestion.
#[derive(Debug, Clone, PartialEq)]
pub struct Classification {
    pub action: String,
    pub category: Option<String>,
    pub confidence: String,
    pub rationale: Option<String>,
    pub due_text: Option<String>,
}

/// A mail waiting to be classified.
#[derive(Debug, Clone)]
pub struct TriageTarget {
    pub remote_id: String,
    pub from_address: String,
    pub subject: Option<String>,
    pub snippet: Option<String>,
}

impl TriageTarget {
    /// The prompt: who wrote it, what it is about, what it says.
    pub fn prompt(&self) -> String {
        let mut prompt = String::new();
        prompt.push_str("发件人：");
        prompt.push_str(&self.from_address);
        prompt.push_str("\n主题：");
        prompt.push_str(self.subject.as_deref().unwrap_or("（无主题）"));
        if let Some(snippet) = &self.snippet {
            let snippet: String = snippet.chars().take(300).collect();
            if !snippet.trim().is_empty() {
                prompt.push_str("\n开头：");
                prompt.push_str(&snippet);
            }
        }
        prompt
    }
}

/// One classified mail, with what it cost.
#[derive(Debug, Clone)]
pub struct Classified {
    pub remote_id: String,
    pub classification: Classification,
    pub completion: AiCompletion,
}

/// Ask the model about a batch of mails.
///
/// The whole batch is one round of work: the caller decides how many mails
/// are worth a call. A failure is not fatal - the caller keeps the mails for
/// the next round - so this returns what it could classify.
pub async fn classify(ai: &AiGateway, targets: Vec<TriageTarget>) -> Vec<Classified> {
    let mut classified = Vec::new();
    for target in targets {
        let completion = match ai
            .complete("classify", CLASSIFY_SYSTEM, &target.prompt())
            .await
        {
            Ok(completion) => completion,
            Err(error) => {
                // One failure stops the batch: if the provider is down, the
                // next mail would fail too.
                tracing::warn!(err = %error, "triage.failed");
                break;
            }
        };
        classified.push(Classified {
            remote_id: target.remote_id,
            classification: parse_classification(&completion.text),
            completion,
        });
    }
    classified
}

/// Read the model's answer.
///
/// A model that answers with prose still answered: the text becomes the
/// reason, and the action falls back to "nothing" - the queue's way of
/// saying "look at this yourself".
pub fn parse_classification(raw: &str) -> Classification {
    let value = extract_json_object(raw)
        .and_then(|json| serde_json::from_str::<serde_json::Value>(&json).ok());
    let text_of = |key: &str| -> Option<String> {
        value
            .as_ref()
            .and_then(|value| value.get(key))
            .and_then(|value| value.as_str())
            .map(|raw| raw.trim().to_owned())
            .filter(|raw| !raw.is_empty())
    };
    let action = text_of("action")
        .filter(|action| crate::store::advice::ACTIONS.contains(&action.as_str()))
        .unwrap_or_else(|| "nothing".to_owned());
    let category = text_of("category")
        .filter(|category| crate::store::advice::CATEGORIES.contains(&category.as_str()));
    let confidence = text_of("confidence")
        .filter(|confidence| crate::store::advice::CONFIDENCES.contains(&confidence.as_str()))
        .unwrap_or_else(|| "low".to_owned());
    let rationale = text_of("rationale");
    let due_text = text_of("dueText");
    if rationale.is_none() && due_text.is_none() && value.is_none() {
        // Not JSON at all: the model's own words are the reason.
        let text = raw.trim();
        return Classification {
            action,
            category,
            confidence,
            rationale: if text.is_empty() {
                None
            } else {
                Some(text.to_owned())
            },
            due_text: None,
        };
    }
    Classification {
        action,
        category,
        confidence,
        rationale,
        due_text,
    }
}

/// The JSON object inside a model's answer.
fn extract_json_object(raw: &str) -> Option<String> {
    let start = raw.find('{')?;
    let end = raw.rfind('}')?;
    if end <= start {
        return None;
    }
    Some(raw[start..=end].to_owned())
}

/// The error the classifier reports when the AI cannot answer.
pub fn as_error(error: &AiError) -> String {
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_json_answer_becomes_a_suggestion() {
        let classification = parse_classification(
            r#"{"category":"work","action":"reply","confidence":"high","rationale":"对方在等你确认","dueText":""}"#,
        );
        assert_eq!(classification.action, "reply");
        assert_eq!(classification.category.as_deref(), Some("work"));
        assert_eq!(classification.confidence, "high");
        assert_eq!(classification.rationale.as_deref(), Some("对方在等你确认"));
        assert_eq!(classification.due_text, None);
    }

    #[test]
    fn an_action_the_queue_does_not_know_becomes_nothing() {
        // The queue can only show seven actions; a made-up one must not
        // become a suggestion the user cannot act on.
        let classification = parse_classification(
            r#"{"category":"work","action":"forward_to_boss","confidence":"high"}"#,
        );
        assert_eq!(classification.action, "nothing");
    }

    #[test]
    fn a_prose_answer_keeps_its_words_as_the_reason() {
        let classification = parse_classification("这看起来是账单，不需要回复。");
        assert_eq!(classification.action, "nothing");
        assert_eq!(
            classification.rationale.as_deref(),
            Some("这看起来是账单，不需要回复。")
        );
    }

    #[test]
    fn the_prompt_carries_the_header_and_nothing_more() {
        let target = TriageTarget {
            remote_id: "r1".to_owned(),
            from_address: "alice@example.invalid".to_owned(),
            subject: Some("Contract".to_owned()),
            snippet: Some("please confirm".to_owned()),
        };
        let prompt = target.prompt();
        assert!(prompt.contains("alice@example.invalid"));
        assert!(prompt.contains("Contract"));
        assert!(prompt.contains("please confirm"));
    }
}
