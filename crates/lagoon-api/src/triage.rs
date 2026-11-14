//! The triage batch: two layers, one queue.
//!
//! What this module is for
//! -----------------------
//! `sync::triage` classifies the mail that arrives *while* a sync round is
//! running: it reads the upserts, keeps a bounded in-memory backlog, and asks
//! the model about three mails a round. That is the right shape for "new mail
//! arrived". It is the wrong shape for a mailbox that already holds hundreds of
//! letters nobody ever looked at - the backlog is process memory, so a restart
//! forgets it, and the window is the change set, so old mail never enters it.
//!
//! This worker is the other half: run once, walk the whole mailbox, stop when
//! it is done or when money or the user says stop.
//!
//! Two layers (plan D8)
//! --------------------
//! Layer 1 is the rules this build already ships - `List-Unsubscribe` and the
//! subscription-sender pattern. They cost nothing, they run in milliseconds,
//! and on the reference mailbox they settle 322 of 430 mails. Layer 2 is the
//! model, and it only ever sees what layer 1 could not decide. Paying a
//! provider to recognise `noreply@` is not thrift, it is buying a worse answer
//! for more money.
//!
//! Layer 1 running without a key is deliberate: a build with no AI configured
//! still triages the obvious mail. `stopped-unconfigured` describes layer 2.
//!
//! What it will not do
//! -------------------
//! It writes `advice` rows and `usage_log` rows. It does not write the mailbox
//! (no `MailProvider` is reachable from here), it does not send, and it does
//! not overwrite a decision the user already made - `upsert_ai`'s
//! `WHERE decision = 'pending'` is the guard and this module does not widen it.
//!
//! Why it calls `complete` instead of `classify`
//! ---------------------------------------------
//! `classify::classify` stops at the first provider error and returns only what
//! it parsed, so the caller cannot tell "the budget ran out" from "the provider
//! is down" from "the model wrote prose". Those three need different answers
//! (stop and say so / stop and say so / keep going), so this module talks to the
//! gateway directly and uses `parse_classification` for the text.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::ai::classify::{parse_classification, CLASSIFY_SYSTEM};
use crate::ai::gateway::{AiError, AiGateway};
use crate::store::advice::{HeuristicSuggestion, TriageCandidate};
use crate::timefmt;
use crate::uuid::Uuid;
use crate::{briefing, db, store};

/// How many mails one layer-2 round asks about.
///
/// Three concurrent calls, not a batch prompt (plan D4): a batch prompt has to
/// parse an array, and a partially parseable array silently drops suggestions.
/// A dropped suggestion looks exactly like "nothing to do here", which is the
/// failure mode this project refuses.
const AI_CONCURRENCY: usize = 3;

/// How many candidates one pass reads from the store.
///
/// The pass repeats until the queue is empty, so this bounds memory per pass
/// rather than the total work.
const PASS_SIZE: i64 = 500;

/// How many consecutive provider failures stop the loop.
///
/// The gateway has its own circuit breaker; this is the worker's "the provider
/// is down, stop burning time" threshold, and it exists so the run ends with a
/// stated reason instead of retrying forever.
const MAX_CONSECUTIVE_FAILURES: u32 = 5;

/// Why a run ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunState {
    Running,
    Done,
    /// The month's own cap is reached (plan §4.4: stated, never silent).
    StoppedBudget,
    /// Layer 2 has no key. Layer 1 has already finished.
    StoppedUnconfigured,
    /// The provider kept failing.
    StoppedError,
    /// The user asked it to stop.
    Cancelled,
}

impl RunState {
    pub fn as_str(self) -> &'static str {
        match self {
            RunState::Running => "running",
            RunState::Done => "done",
            RunState::StoppedBudget => "stopped-budget",
            RunState::StoppedUnconfigured => "stopped-unconfigured",
            RunState::StoppedError => "stopped-error",
            RunState::Cancelled => "cancelled",
        }
    }

    fn is_terminal(self) -> bool {
        self != RunState::Running
    }
}

/// Which layer the worker is in. `None` before a run starts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Heuristic,
    Ai,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Heuristic => "heuristic",
            Phase::Ai => "ai",
        }
    }
}

/// One run's progress.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TriageRun {
    pub started_at: String,
    pub phase: Option<Phase>,
    /// How many mails the current phase set out to look at. Layer 2's target is
    /// what layer 1 left behind, so it is only known once layer 1 ended.
    pub target: i64,
    pub done: i64,
    pub failed: i64,
    pub state: RunState,
    pub last_error: Option<String>,
}

/// What the status route answers.
///
/// Every number is a query result, never a counter kept on the side: the UI's
/// "310 left" and the worker's next pass read the same predicate, so they
/// cannot drift (constitution P3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TriageStatus {
    pub configured: bool,
    pub running: bool,
    pub suggested: i64,
    pub unsuggested: i64,
    pub heuristic_count: i64,
    pub ai_count: i64,
    pub spend_month_micro_usd: i64,
    pub cap_month_micro_usd: i64,
    pub run: Option<TriageRun>,
}

/// The cancellation flag a running pass checks between batches.
#[derive(Debug, Default)]
struct CancelToken(AtomicBool);

impl CancelToken {
    fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// A run is already in flight for this account.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlreadyRunning;

/// Releases an account when its run ends, panic or not.
///
/// The account was inserted into `running` before the worker was spawned, and
/// only the worker knows when it is done. A plain `remove` after `execute()`
/// would be skipped by a panic - and an account stuck in `running` answers
/// "already running" to every later request until the process restarts.
///
/// The same drop clears the account's cancel token: the token belongs to the
/// run that just ended, and the next `start` writes a fresh one anyway.
struct RunningGuard {
    running: Arc<Mutex<HashSet<Uuid>>>,
    cancel: Arc<Mutex<HashMap<Uuid, Arc<CancelToken>>>>,
    account_id: Uuid,
}

impl Drop for RunningGuard {
    fn drop(&mut self) {
        self.running
            .lock()
            .expect("triage running lock")
            .remove(&self.account_id);
        self.cancel
            .lock()
            .expect("triage cancel lock")
            .remove(&self.account_id);
    }
}

/// One mail's layer-2 outcome.
enum Outcome {
    Suggested {
        remote_id: String,
        action: String,
        category: Option<String>,
        confidence: String,
        rationale: Option<String>,
        due_text: Option<String>,
        model: String,
        prompt_tokens: u32,
        completion_tokens: u32,
        cost_micro_usd: i64,
    },
    Failed {
        remote_id: String,
        reason: String,
        kind: FailureKind,
    },
}

/// Why a layer-2 call failed, in the only three ways that change what the
/// worker does next.
enum FailureKind {
    /// The month's cap is reached: stop the run and say so.
    Budget,
    /// No provider or no key: stop the run and say so.
    Unconfigured,
    /// Anything else: count it, and stop only if it keeps happening.
    Other,
}

/// The worker: one per process, shared by the routes.
///
/// Locks are short-held and never held across an await: a run lock held across
/// a model call would make `status` wait for the network.
pub struct TriageWorker {
    db_path: PathBuf,
    ai: Arc<AiGateway>,
    budget_cap_usd: f64,
    /// One entry per account, not one entry for the process.
    ///
    /// Two accounts may run at the same time (`running` below is per account),
    /// so a single slot would let one account's progress overwrite the other's
    /// and make `status` answer with a run that belongs to a different mailbox.
    run: Arc<Mutex<HashMap<Uuid, TriageRun>>>,
    /// The cancel token of each account's run.
    ///
    /// Per account for the same reason: one shared token meant that stopping
    /// account A stopped whichever run started last (usually B) and left A
    /// running - the user asked for the opposite of what happened.
    cancel: Arc<Mutex<HashMap<Uuid, Arc<CancelToken>>>>,
    /// One run at a time, per account (plan §4.5): two workers would race on
    /// `upsert` and bill the same mail twice.
    running: Arc<Mutex<HashSet<Uuid>>>,
}

impl TriageWorker {
    pub fn new(db_path: PathBuf, ai: Arc<AiGateway>, budget_cap_usd: f64) -> Self {
        Self {
            db_path,
            ai,
            budget_cap_usd,
            run: Arc::new(Mutex::new(HashMap::new())),
            cancel: Arc::new(Mutex::new(HashMap::new())),
            running: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    /// Point the worker at a different gateway (tests bring their own keys).
    pub fn with_ai(mut self, ai: Arc<AiGateway>) -> Self {
        self.ai = ai;
        self
    }

    pub fn status(&self, account_id: Uuid) -> Result<Option<TriageStatus>, db::DbError> {
        let connection = db::open_writable(&self.db_path)?;
        // An account that does not exist is not "a mailbox with zero mail": it
        // is a different fact, and the route answers 404 for it. Reporting
        // zeros here would make a typo look like an empty inbox.
        if !store::accounts::exists(&connection, account_id)
            .map_err(|error| db::DbError::Task(error.to_string()))?
        {
            return Ok(None);
        }
        let (suggested, unsuggested) = store::advice::triage_counts(&connection, account_id)?;
        let (heuristic_count, ai_count) = store::advice::source_counts(&connection, account_id)?;
        let spend = store::usage::month_summary(&connection, &current_month())?.cost_micro_usd;
        let configured = self.ai.status().configured;
        // The run belongs to the account that was asked about. Another
        // account's run must never answer here: its progress belongs to a
        // different mailbox, and showing it next to this account's counts
        // would be a number nobody can trace back to a source.
        let run = self
            .run
            .lock()
            .expect("triage run lock")
            .get(&account_id)
            .cloned();
        Ok(Some(TriageStatus {
            configured,
            running: run.as_ref().is_some_and(|run| !run.state.is_terminal()),
            suggested,
            unsuggested,
            heuristic_count,
            ai_count,
            spend_month_micro_usd: spend,
            cap_month_micro_usd: (self.budget_cap_usd * 1_000_000.0).round() as i64,
            run,
        }))
    }

    /// Start a run, or answer `AlreadyRunning` so the route can hand back the
    /// run already going (a double click must not start a second worker).
    pub fn start(&self, account_id: Uuid, account_email: String) -> Result<(), AlreadyRunning> {
        {
            let mut running = self.running.lock().expect("triage running lock");
            if !running.insert(account_id) {
                return Err(AlreadyRunning);
            }
        }
        // A fresh token per run: cancelling the previous run must not cancel
        // this one.
        let token = Arc::new(CancelToken::default());
        self.cancel
            .lock()
            .expect("triage cancel lock")
            .insert(account_id, Arc::clone(&token));
        self.run.lock().expect("triage run lock").insert(
            account_id,
            TriageRun {
                started_at: timefmt::to_iso8601(timefmt::now()),
                phase: Some(Phase::Heuristic),
                target: 0,
                done: 0,
                failed: 0,
                state: RunState::Running,
                last_error: None,
            },
        );

        let batch = Batch {
            db_path: self.db_path.clone(),
            ai: Arc::clone(&self.ai),
            budget_cap_usd: self.budget_cap_usd,
            account_id,
            account_email,
            token,
            run: Arc::clone(&self.run),
        };
        let running = Arc::clone(&self.running);
        let cancel = Arc::clone(&self.cancel);
        // The run outlives the request: the route answers 202 and the UI polls,
        // because a batch over a few hundred mails takes minutes.
        tokio::spawn(async move {
            // The guard releases the account even if the worker panics: a
            // panic that left the account marked "running" would answer 409
            // `triage-already-running` until the app was restarted.
            let _guard = RunningGuard {
                running: Arc::clone(&running),
                cancel: Arc::clone(&cancel),
                account_id,
            };
            batch.execute().await;
        });
        Ok(())
    }

    /// Ask the current run to stop. Returns the status afterwards: the state
    /// becomes `cancelled` when the worker notices, not when this returns.
    pub fn cancel(&self, account_id: Uuid) -> Result<Option<TriageStatus>, db::DbError> {
        // Only this account's run is asked to stop.
        let token = self
            .cancel
            .lock()
            .expect("triage cancel lock")
            .get(&account_id)
            .cloned();
        if let Some(token) = token {
            token.cancel();
        }
        {
            let mut guard = self.run.lock().expect("triage run lock");
            if let Some(run) = guard.get_mut(&account_id) {
                // The worker also sets this; doing it here makes "I pressed
                // stop" visible immediately instead of after the current batch.
                if !run.state.is_terminal() {
                    run.state = RunState::Cancelled;
                }
            }
        }
        self.status(account_id)
    }
}

/// One account's batch: everything the spawned task needs, owned.
struct Batch {
    db_path: PathBuf,
    ai: Arc<AiGateway>,
    budget_cap_usd: f64,
    account_id: Uuid,
    account_email: String,
    token: Arc<CancelToken>,
    run: Arc<Mutex<HashMap<Uuid, TriageRun>>>,
}

impl Batch {
    async fn execute(&self) {
        match self.run_layers().await {
            Ok(()) => {}
            Err(reason) => self.finish_if_running(RunState::StoppedError, Some(reason)),
        }
    }

    async fn run_layers(&self) -> Result<(), String> {
        // Layer 1: free, whole mailbox, never touches the model.
        self.set_phase(Phase::Heuristic, 0);
        let settled = self.run_heuristic()?;
        self.add_done(settled);
        if self.stopped() {
            self.finish(RunState::Cancelled, None);
            return Ok(());
        }

        // Layer 2: only what layer 1 could not decide.
        if !self.ai.status().configured {
            self.finish(RunState::StoppedUnconfigured, None);
            return Ok(());
        }
        let remaining = self.unsuggested()?;
        self.set_phase(Phase::Ai, remaining);
        if remaining == 0 {
            self.finish(RunState::Done, None);
            return Ok(());
        }
        self.run_ai(remaining).await
    }

    /// The rules layer: write a suggestion for every mail a shipped rule can
    /// judge, and leave the rest untouched for the model.
    ///
    /// Returns how many mails it settled.
    fn run_heuristic(&self) -> Result<i64, String> {
        let mut settled = 0i64;
        loop {
            if self.stopped() {
                return Ok(settled);
            }
            let connection = db::open_writable(&self.db_path).map_err(|error| error.to_string())?;
            let candidates =
                store::advice::triage_candidates(&connection, self.account_id, PASS_SIZE)
                    .map_err(|error| error.to_string())?;
            if candidates.is_empty() {
                return Ok(settled);
            }
            let mut judged_this_pass = 0i64;
            for candidate in &candidates {
                let Some(judgement) = judge_by_rule(candidate) else {
                    continue;
                };
                store::advice::upsert_heuristic(
                    &connection,
                    self.account_id,
                    &candidate.remote_id,
                    &judgement,
                )
                .map_err(|error| error.to_string())?;
                judged_this_pass += 1;
                settled += 1;
            }
            // Every candidate in this pass was left for the model, so no
            // further pass can judge any of them either: stop rather than loop
            // over the same rows forever. The model layer picks them up next.
            if judged_this_pass == 0 {
                return Ok(settled);
            }
        }
    }

    /// The model layer: three concurrent calls per round, one mail each.
    async fn run_ai(&self, remaining: i64) -> Result<(), String> {
        let mut failures = 0u32;
        let mut seen: HashSet<String> = HashSet::new();
        let mut processed = 0i64;
        // The batch size is bounded by what is left, so a small mailbox does
        // not leave the loop after one round and call itself done.
        let target = remaining;

        while processed < target {
            if self.stopped() {
                self.finish(RunState::Cancelled, None);
                return Ok(());
            }
            // The cap is checked before reading the batch, so an exhausted
            // budget costs no work and is reported as such.
            if self.budget_spent()? {
                self.finish(RunState::StoppedBudget, None);
                return Ok(());
            }

            let batch = self.next_ai_batch(&seen)?;
            if batch.is_empty() {
                self.finish(RunState::Done, None);
                return Ok(());
            }
            let count = batch.len() as i64;
            let outcomes = self.classify_batch(batch).await;
            let mut wrote = 0i64;
            for outcome in outcomes {
                match outcome {
                    Outcome::Suggested {
                        remote_id,
                        action,
                        category,
                        confidence,
                        rationale,
                        due_text,
                        model,
                        prompt_tokens,
                        completion_tokens,
                        cost_micro_usd,
                    } => {
                        self.store_ai_suggestion(
                            &remote_id,
                            &action,
                            category.as_deref(),
                            &confidence,
                            rationale.as_deref(),
                            due_text.as_deref(),
                            &model,
                            prompt_tokens,
                            completion_tokens,
                            cost_micro_usd,
                        )?;
                        wrote += 1;
                        seen.insert(remote_id);
                    }
                    Outcome::Failed {
                        remote_id,
                        reason,
                        kind,
                    } => {
                        self.record_error(&reason);
                        seen.insert(remote_id);
                        match kind {
                            FailureKind::Budget => {
                                self.finish(RunState::StoppedBudget, Some(reason));
                                return Ok(());
                            }
                            FailureKind::Unconfigured => {
                                self.finish(RunState::StoppedUnconfigured, Some(reason));
                                return Ok(());
                            }
                            FailureKind::Other => {
                                failures += 1;
                                self.add_failed(1);
                                if failures >= MAX_CONSECUTIVE_FAILURES {
                                    self.finish(RunState::StoppedError, Some(reason));
                                    return Ok(());
                                }
                            }
                        }
                    }
                }
            }
            self.add_done(wrote);
            processed += count;
        }
        self.finish(RunState::Done, None);
        Ok(())
    }

    /// The next mails the model should look at, skipping anything this run
    /// already touched. A failed mail is retried by the *next* run, not this
    /// one: retrying inside the run is how a broken provider becomes a loop.
    fn next_ai_batch(&self, seen: &HashSet<String>) -> Result<Vec<TriageCandidate>, String> {
        let connection = db::open_writable(&self.db_path).map_err(|error| error.to_string())?;
        let candidates = store::advice::triage_candidates(&connection, self.account_id, PASS_SIZE)
            .map_err(|error| error.to_string())?;
        Ok(candidates
            .into_iter()
            .filter(|candidate| !seen.contains(&candidate.remote_id))
            .take(AI_CONCURRENCY * 4)
            .collect())
    }

    async fn classify_batch(&self, candidates: Vec<TriageCandidate>) -> Vec<Outcome> {
        let mut outcomes = Vec::with_capacity(candidates.len());
        // Three in flight at a time: a slow provider then delays three answers
        // rather than one, which is the difference between a 108-mail batch
        // taking three minutes and taking one.
        let mut set = tokio::task::JoinSet::new();
        for candidate in candidates {
            let ai = Arc::clone(&self.ai);
            set.spawn(async move { classify_one(ai, candidate).await });
            if set.len() >= AI_CONCURRENCY {
                if let Some(Ok(outcome)) = set.join_next().await {
                    outcomes.push(outcome);
                }
            }
        }
        while let Some(joined) = set.join_next().await {
            if let Ok(outcome) = joined {
                outcomes.push(outcome);
            }
        }
        outcomes
    }

    /// Store the suggestion and what it cost.
    ///
    /// The ledger write is not optional: the budget gate reads only this table,
    /// so a call that skips it is a call the product cannot see the price of.
    #[allow(clippy::too_many_arguments)]
    fn store_ai_suggestion(
        &self,
        remote_id: &str,
        action: &str,
        category: Option<&str>,
        confidence: &str,
        rationale: Option<&str>,
        due_text: Option<&str>,
        model: &str,
        prompt_tokens: u32,
        completion_tokens: u32,
        cost_micro_usd: i64,
    ) -> Result<(), String> {
        let connection = db::open_writable(&self.db_path).map_err(|error| error.to_string())?;
        store::advice::upsert_ai(
            &connection,
            self.account_id,
            remote_id,
            &store::advice::AiSuggestion {
                action,
                category,
                confidence,
                rationale,
                due_text,
                model,
            },
        )
        .map_err(|error| error.to_string())?;
        store::usage::record(
            &connection,
            &store::usage::UsageRecord {
                year_month: &current_month(),
                account_email: &self.account_email,
                capability: "classify",
                model,
                prompt_tokens,
                completion_tokens,
                cost_micro_usd,
            },
        )
        .map_err(|error| error.to_string())?;
        Ok(())
    }

    fn budget_spent(&self) -> Result<bool, String> {
        if self.budget_cap_usd <= 0.0 {
            return Ok(false);
        }
        let connection = db::open_writable(&self.db_path).map_err(|error| error.to_string())?;
        let spend = store::usage::month_summary(&connection, &current_month())
            .map_err(|error| error.to_string())?
            .cost_micro_usd;
        let cap = (self.budget_cap_usd * 1_000_000.0).round() as i64;
        Ok(spend >= cap)
    }

    fn unsuggested(&self) -> Result<i64, String> {
        let connection = db::open_writable(&self.db_path).map_err(|error| error.to_string())?;
        let (_, unsuggested) = store::advice::triage_counts(&connection, self.account_id)
            .map_err(|error| error.to_string())?;
        Ok(unsuggested)
    }

    fn stopped(&self) -> bool {
        self.token.is_cancelled()
    }

    fn set_phase(&self, phase: Phase, target: i64) {
        let mut guard = self.run.lock().expect("triage run lock");
        if let Some(run) = guard.get_mut(&self.account_id) {
            run.phase = Some(phase);
            run.target = target;
        }
    }

    fn add_done(&self, count: i64) {
        let mut guard = self.run.lock().expect("triage run lock");
        if let Some(run) = guard.get_mut(&self.account_id) {
            run.done += count;
        }
    }

    fn add_failed(&self, count: i64) {
        let mut guard = self.run.lock().expect("triage run lock");
        if let Some(run) = guard.get_mut(&self.account_id) {
            run.failed += count;
        }
    }

    fn record_error(&self, reason: &str) {
        let mut guard = self.run.lock().expect("triage run lock");
        if let Some(run) = guard.get_mut(&self.account_id) {
            run.last_error = Some(reason.to_owned());
        }
    }

    fn finish(&self, state: RunState, reason: Option<String>) {
        let mut guard = self.run.lock().expect("triage run lock");
        if let Some(run) = guard.get_mut(&self.account_id) {
            // A cancel that already landed wins over a later natural finish:
            // the user asked, and the report says so.
            if run.state == RunState::Cancelled && state != RunState::Cancelled {
                return;
            }
            run.state = state;
            if let Some(reason) = reason {
                run.last_error = Some(reason);
            }
        }
    }

    fn finish_if_running(&self, state: RunState, reason: Option<String>) {
        let mut guard = self.run.lock().expect("triage run lock");
        if let Some(run) = guard.get_mut(&self.account_id) {
            if !run.state.is_terminal() {
                run.state = state;
                run.last_error = reason;
            }
        }
    }
}

/// Ask the model about one mail. Free of `&self` so it can run on its own task.
async fn classify_one(ai: Arc<AiGateway>, candidate: TriageCandidate) -> Outcome {
    let prompt = prompt_for(&candidate);
    match ai.complete("classify", CLASSIFY_SYSTEM, &prompt).await {
        Ok(completion) => {
            let classification = parse_classification(&completion.text);
            Outcome::Suggested {
                remote_id: candidate.remote_id,
                action: classification.action,
                category: classification.category,
                confidence: classification.confidence,
                rationale: classification.rationale,
                due_text: classification.due_text,
                model: completion.model,
                prompt_tokens: completion.prompt_tokens,
                completion_tokens: completion.completion_tokens,
                cost_micro_usd: completion.cost_micro_usd,
            }
        }
        Err(error) => {
            let kind = match &error {
                AiError::BudgetExceeded => FailureKind::Budget,
                AiError::NotConfigured(_) | AiError::CreditExhausted => FailureKind::Unconfigured,
                _ => FailureKind::Other,
            };
            Outcome::Failed {
                remote_id: candidate.remote_id,
                reason: error.to_string(),
                kind,
            }
        }
    }
}

/// The prompt for one mail.
///
/// Header-only, and it says so. The subject is plaintext (contract §6 seals the
/// snippet, not the subject) and it is what the list screen shows, so the model
/// sees exactly what the user sees - no more, which keeps the claim truthful.
fn prompt_for(candidate: &TriageCandidate) -> String {
    let mut prompt = String::new();
    prompt.push_str("发件人：");
    prompt.push_str(&candidate.from_address);
    prompt.push_str("\n主题：");
    prompt.push_str(candidate.subject.as_deref().unwrap_or("（无主题）"));
    if candidate.list_unsubscribe {
        prompt.push_str("\n（这封带一键退订头）");
    }
    if candidate.has_cached_body {
        prompt.push_str("\n（正文已缓存，但本次判断只用了发件人与主题）");
    }
    prompt
}

/// One mail judged by a shipped rule, if a rule can judge it.
///
/// The rules are exactly the ones `briefing` already trusts, reused rather than
/// rewritten: two implementations of "is this a subscription sender" would drift
/// and the card and the feed would disagree.
///
/// Deliberately narrow. A rule may only speak when the answer is obvious from
/// the header alone. `briefing`'s `needsReply` is the *default* bucket -
/// "nothing else matched" - and treating it as a suggestion would turn every
/// remaining mail into "reply", which is not a judgement, it is noise.
fn judge_by_rule(candidate: &TriageCandidate) -> Option<HeuristicSuggestion<'_>> {
    // One-click wins over plain archive: the header says the publisher accepts
    // a machine request, and the decision board can then settle the whole
    // subscription in one click instead of leaving the mail behind.
    if candidate.one_click {
        return Some(HeuristicSuggestion {
            action: "unsubscribe",
            category: Some("newsletter"),
            rationale: "发布方声明支持一键退订（RFC 8058）",
        });
    }
    if candidate.list_unsubscribe {
        return Some(HeuristicSuggestion {
            action: "archive",
            category: Some("newsletter"),
            rationale: "带一键退订的群发邮件",
        });
    }
    if briefing::matches_subscription_sender(&candidate.from_address) {
        return Some(HeuristicSuggestion {
            action: "archive",
            category: Some("notification"),
            rationale: "订阅类发件人（noreply / newsletter / marketing）",
        });
    }
    None
}

fn current_month() -> String {
    chrono::Local::now().format("%Y-%m").to_string()
}

#[cfg(test)]
mod tests {
    //! The multi-account cases.
    //!
    //! Two accounts may run at the same time, and every piece of the worker's
    //! state used to be a single process-wide slot. The visible damage was
    //! that "stop account A" stopped whichever run started last, and that
    //! `status` answered with another mailbox's progress.

    use super::*;
    use std::path::Path;

    /// A directory under the system temp dir, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = format!(
                "lagoon-triage-{label}-{}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("clock")
                    .as_nanos(),
                COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("create temp dir");
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A real store, migrated by this build's own chain.
    ///
    /// The worker reads the store on every status call, so a test that wants
    /// to cancel a run needs a store that answers - not a path that fails.
    fn store_with_two_accounts(label: &str) -> (TempDir, Uuid, Uuid) {
        let temp = TempDir::new(label);
        let path = temp.0.join("lagoon.sqlite");
        crate::store::migrate::prepare(&path, None).expect("migrate the test store");

        let connection = crate::db::open_writable(&path).expect("open the test store");
        let mut ids = Vec::new();
        for (provider, user) in [("qq", "a@example.invalid"), ("qq", "b@example.invalid")] {
            let id = Uuid::new_v4();
            crate::store::write::upsert_account(
                &connection,
                &crate::store::write::NewAccount {
                    id,
                    provider,
                    oauth_user: user,
                    email: user,
                    credentials: None,
                    capabilities: "{}",
                    sync_state: "{}",
                },
            )
            .expect("insert the account");
            ids.push(id);
        }
        (temp, ids[0], ids[1])
    }

    fn worker(path: &Path) -> TriageWorker {
        let transport = Arc::new(crate::ai::fake::ScriptedTransport::new());
        let gateway = AiGateway::new(
            crate::ai::config::AiConfig::embedded().expect("the shipped config parses"),
            transport as Arc<dyn crate::ai::transport::AiTransport>,
        );
        TriageWorker::new(path.to_path_buf(), Arc::new(gateway), 0.0)
    }

    /// Stopping one account must stop that account and leave the other alone.
    ///
    /// Asked through the public surface: what `cancel(A)` reports for A and
    /// for B, not which private map entry moved.
    #[tokio::test]
    async fn cancelling_one_account_leaves_the_other_running() {
        let (temp, account_a, account_b) = store_with_two_accounts("cancel");
        let worker = worker(&temp.0.join("lagoon.sqlite"));

        worker
            .start(account_a, "a@example.invalid".into())
            .expect("start a");
        worker
            .start(account_b, "b@example.invalid".into())
            .expect("start b");

        // The user asks to stop A.
        let status_a = worker.cancel(account_a).expect("cancel a");
        let status_b = worker.status(account_b).expect("status b");

        let run_a = status_a.expect("a has a status").run.expect("a has a run");
        assert_eq!(
            run_a.state,
            RunState::Cancelled,
            "the account the user named must be the one that stops"
        );
        let run_b = status_b.expect("b has a status").run.expect("b has a run");
        assert_eq!(
            run_b.state,
            RunState::Running,
            "another mailbox's run must not stop because of this one"
        );
    }

    /// Each account's progress is its own: `status` answers with the run that
    /// belongs to the mailbox that was asked about.
    #[tokio::test]
    async fn each_account_keeps_its_own_run_record() {
        let (temp, account_a, account_b) = store_with_two_accounts("records");
        let worker = worker(&temp.0.join("lagoon.sqlite"));

        worker
            .start(account_a, "a@example.invalid".into())
            .expect("start a");
        worker
            .start(account_b, "b@example.invalid".into())
            .expect("start b");

        let status_a = worker.status(account_a).expect("status a").expect("exists");
        let status_b = worker.status(account_b).expect("status b").expect("exists");
        for (status, label) in [(status_a, "a"), (status_b, "b")] {
            let run = status.run.unwrap_or_else(|| panic!("{label} has a run"));
            assert_eq!(run.state, RunState::Running, "{label} is running");
            assert!(status.running, "{label} reports itself as running");
        }
    }

    /// The end-of-run guard releases the account even if the worker panicked:
    /// `running` and the account's cancel token both go, so a later request
    /// neither answers "already running" nor cancels with a dead token.
    #[test]
    fn running_guard_releases_the_account_and_its_token() {
        let running = Arc::new(Mutex::new(HashSet::new()));
        let cancel = Arc::new(Mutex::new(HashMap::new()));
        let account_id = Uuid::new_v4();
        running.lock().expect("running lock").insert(account_id);
        cancel
            .lock()
            .expect("cancel lock")
            .insert(account_id, Arc::new(CancelToken::default()));

        drop(RunningGuard {
            running: Arc::clone(&running),
            cancel: Arc::clone(&cancel),
            account_id,
        });

        assert!(
            !running.lock().expect("running lock").contains(&account_id),
            "the account must be reusable after the run ends"
        );
        assert!(
            !cancel
                .lock()
                .expect("cancel lock")
                .contains_key(&account_id),
            "a finished run's token must not outlive the run"
        );
    }
}
