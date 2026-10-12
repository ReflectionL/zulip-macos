//! Initial Zulip state registration, event long-polling, and domain reduction.

use std::{collections::BTreeMap, time::Duration};

use futures_util::StreamExt;
use reqwest::{Client, Response};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use thiserror::Error;

use crate::{
    auth::SecretString,
    server::{DEFAULT_REQUEST_TIMEOUT, ServerBaseUrl, ServerUrlError, secure_http_client},
};

const REGISTER_PATH: &str = "api/v1/register";
const EVENTS_PATH: &str = "api/v1/events";
const MAX_REGISTER_RESPONSE_BYTES: usize = 16 * 1_048_576;
const MAX_EVENTS_RESPONSE_BYTES: usize = 8 * 1_048_576;
const DEFAULT_LONGPOLL_TIMEOUT: Duration = Duration::from_secs(90);
const MIN_LONGPOLL_TIMEOUT_SECONDS: u64 = 5;
const MAX_LONGPOLL_TIMEOUT_SECONDS: u64 = 600;
const EVENT_TYPES_JSON: &str = concat!(
    r#"["message","subscription","realm_user","update_message","#,
    r#""delete_message","reaction","update_message_flags","heartbeat","restart"]"#
);

/// A server-allocated queue and its current acknowledgement cursor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EventQueue {
    /// Opaque queue identifier returned by Zulip.
    pub id: String,
    /// Highest event identifier included in the initial state.
    pub last_event_id: i64,
    /// Server-recommended client-side timeout for a long-poll request.
    pub longpoll_timeout: Duration,
    /// Seconds the server keeps an idle queue when that value is advertised.
    pub idle_timeout_seconds: Option<u64>,
}

/// A normalized organization user needed by navigation and message rendering.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UserSummary {
    /// Zulip user identifier.
    pub id: i64,
    /// Display name.
    pub full_name: String,
    /// Email address when visible to the current account.
    pub email: Option<String>,
    /// Whether the user is currently active.
    pub is_active: bool,
    /// Whether this user represents a bot.
    pub is_bot: bool,
}

/// A normalized subscribed channel.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ChannelSummary {
    /// Zulip stream identifier.
    pub id: i64,
    /// Channel display name.
    pub name: String,
    /// Server-provided display color.
    pub color: String,
    /// Whether the current user muted this channel.
    pub is_muted: bool,
}

/// A normalized message payload owned by the Rust domain layer.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct MessageSummary {
    /// Zulip message identifier.
    pub id: i64,
    /// Sender's Zulip user identifier.
    pub sender_id: i64,
    /// Sender display name.
    pub sender_full_name: String,
    /// Unix timestamp in seconds.
    pub timestamp: i64,
    /// Server-rendered, untrusted HTML awaiting `ContentBlock` normalization.
    pub content_html: String,
    /// Channel identifier for channel messages.
    pub stream_id: Option<i64>,
    /// Topic name for channel messages.
    pub topic: Option<String>,
    /// Recipient identifiers for direct messages.
    pub recipient_ids: Vec<i64>,
    /// Personal flags returned for this account, such as `read` and `starred`.
    pub flags: Vec<String>,
    /// Reactions currently attached to this message.
    pub reactions: Vec<ReactionSummary>,
}

/// One normalized reaction attached to a message.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ReactionSummary {
    /// Stable emoji name used by Zulip's reaction write API.
    pub emoji_name: String,
    /// Zulip identifier of the reacting user.
    pub user_id: i64,
}

/// Immutable state seeded by the atomic `register` response.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BootstrapState {
    /// Users visible to the account.
    pub users: Vec<UserSummary>,
    /// Channels subscribed by the account.
    pub channels: Vec<ChannelSummary>,
    /// Messages included by a compatible server's register response.
    pub messages: Vec<MessageSummary>,
}

/// Result of registering a live event queue.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RegisteredQueue {
    /// Queue transport metadata.
    pub queue: EventQueue,
    /// Initial normalized domain state.
    pub bootstrap: BootstrapState,
    /// Server API feature level.
    pub zulip_feature_level: u64,
}

/// A partial update to an already-known message.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MessageUpdate {
    /// Message being updated.
    pub message_id: i64,
    /// Replacement rendered content, when changed.
    pub content_html: Option<String>,
    /// Replacement topic, when changed.
    pub topic: Option<String>,
    /// Replacement channel identifier, when moved.
    pub stream_id: Option<i64>,
}

/// A partial update to one subscribed channel.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ChannelUpdate {
    /// Channel being updated.
    pub channel_id: i64,
    /// Replacement channel name, when present.
    pub name: Option<String>,
    /// Replacement channel color, when present.
    pub color: Option<String>,
    /// Replacement personal mute state, when present.
    pub is_muted: Option<bool>,
}

/// A partial update to one visible organization user.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct UserUpdate {
    /// User being updated.
    pub user_id: i64,
    /// Replacement display name, when present.
    pub full_name: Option<String>,
    /// Replacement API email, when present and visible.
    pub email: Option<String>,
    /// Replacement active state, when present.
    pub is_active: Option<bool>,
    /// Replacement bot state, when present.
    pub is_bot: Option<bool>,
}

/// Normalized live events accepted by [`SyncReducer`].
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SyncEvent {
    /// Queue keepalive carrying no domain mutation.
    Heartbeat {
        /// Monotonic queue-local event identifier.
        event_id: i64,
    },
    /// The server requests that clients discard the queue and reload state.
    ServerRestart {
        /// Monotonic queue-local event identifier.
        event_id: i64,
    },
    /// A newly delivered message.
    MessageAdded {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Normalized message.
        message: MessageSummary,
    },
    /// A content, topic, or channel move update.
    MessageUpdated {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Partial message changes.
        update: MessageUpdate,
    },
    /// One or more messages were deleted.
    MessagesDeleted {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Deleted message identifiers.
        message_ids: Vec<i64>,
    },
    /// A personal flag such as `read` or `starred` was added or removed.
    MessageFlagsUpdated {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// `true` for `add`, `false` for `remove`.
        added: bool,
        /// Zulip flag name.
        flag: String,
        /// Affected message identifiers.
        message_ids: Vec<i64>,
    },
    /// An emoji reaction was added to or removed from a message.
    ReactionChanged {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// `true` for `add`, `false` for `remove`.
        added: bool,
        /// Reacted message.
        message_id: i64,
        /// The reaction itself.
        reaction: ReactionSummary,
    },
    /// Channels were added to or refreshed in the subscription set.
    ChannelsUpserted {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Normalized channel values.
        channels: Vec<ChannelSummary>,
    },
    /// A personal or display property changed on one subscribed channel.
    ChannelUpdated {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Partial channel changes.
        update: ChannelUpdate,
    },
    /// Channels were removed from the subscription set.
    ChannelsRemoved {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Removed channel identifiers.
        channel_ids: Vec<i64>,
    },
    /// A visible organization user was added or refreshed.
    UserUpserted {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Normalized user.
        user: UserSummary,
    },
    /// Properties changed on a visible organization user.
    UserUpdated {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Partial user changes.
        update: UserUpdate,
    },
    /// A visible organization user was removed.
    UserRemoved {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Removed user identifier.
        user_id: i64,
    },
    /// A subscribed event type that does not yet affect the prototype domain.
    Unknown {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Server event type for diagnostics without retaining its payload.
        event_type: String,
    },
}

impl SyncEvent {
    /// Returns the queue-local event identifier used for ordering and deduplication.
    #[must_use]
    pub const fn event_id(&self) -> i64 {
        match self {
            Self::Heartbeat { event_id }
            | Self::ServerRestart { event_id }
            | Self::MessageAdded { event_id, .. }
            | Self::MessageUpdated { event_id, .. }
            | Self::MessagesDeleted { event_id, .. }
            | Self::MessageFlagsUpdated { event_id, .. }
            | Self::ReactionChanged { event_id, .. }
            | Self::ChannelsUpserted { event_id, .. }
            | Self::ChannelUpdated { event_id, .. }
            | Self::ChannelsRemoved { event_id, .. }
            | Self::UserUpserted { event_id, .. }
            | Self::UserUpdated { event_id, .. }
            | Self::UserRemoved { event_id, .. }
            | Self::Unknown { event_id, .. } => *event_id,
        }
    }
}

/// Immutable, bridge-safe projection of current sync state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SyncSnapshot {
    /// Increments once per published batch with domain changes.
    pub revision: u64,
    /// Highest accepted queue event identifier.
    pub last_event_id: i64,
    /// Users sorted by identifier.
    pub users: Vec<UserSummary>,
    /// Channels sorted by identifier.
    pub channels: Vec<ChannelSummary>,
    /// Messages sorted by identifier.
    pub messages: Vec<MessageSummary>,
}

/// Reduction statistics and at most one snapshot for a complete poll batch.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BatchOutcome {
    /// Events newer than the reducer cursor.
    pub accepted_events: usize,
    /// Duplicate or stale events ignored by the reducer.
    pub ignored_events: usize,
    /// Number of accepted heartbeats.
    pub heartbeats: usize,
    /// One immutable snapshot when the batch changed domain state.
    pub snapshot: Option<SyncSnapshot>,
}

/// Errors while registering or polling a Zulip event queue.
#[derive(Debug, Error)]
pub enum SyncError {
    /// The server root violated the shared transport policy.
    #[error(transparent)]
    InvalidServer(#[from] ServerUrlError),
    /// Email or API key input was empty or unsafe for Basic authentication.
    #[error("enter valid event queue credentials")]
    InvalidInput,
    /// DNS, TLS, timeout, redirect, or connection failure.
    #[error("could not synchronize with the Zulip server: {message}")]
    Transport {
        /// Sanitized transport error without a request URL.
        message: String,
    },
    /// The server rejected the stored credentials (HTTP 401).
    ///
    /// This is the only terminal synchronization failure: every other error is
    /// retried with backoff so a transient problem never ends the session.
    #[error("the Zulip server rejected the saved credentials; sign in again")]
    Unauthorized,
    /// The endpoint returned a non-success status.
    #[error("event synchronization returned HTTP {0}")]
    HttpStatus(u16),
    /// Zulip has garbage-collected the queue and requires registration again.
    #[error("the Zulip event queue expired")]
    BadEventQueue,
    /// A response exceeded the configured memory bound.
    #[error("event synchronization response is too large")]
    ResponseTooLarge,
    /// The server response could not be safely normalized.
    #[error("the server returned an invalid event response: {0}")]
    InvalidResponse(&'static str),
}

/// Authenticated transport for queue registration and one-at-a-time long polls.
///
/// The actor layer owns this value so its API key stays in Rust process memory
/// and its async methods never cross the FFI boundary.
#[derive(Debug)]
pub struct EventQueueClient {
    http: Client,
    base_url: ServerBaseUrl,
    email: String,
    api_key: SecretString,
}

impl EventQueueClient {
    /// Creates a client using the shared HTTPS/native-root redirect policy.
    ///
    /// # Errors
    ///
    /// Returns [`SyncError`] for invalid server roots, unsafe credentials, or
    /// HTTP client initialization failure.
    pub fn new(
        server: &str,
        email: impl Into<String>,
        api_key: SecretString,
    ) -> Result<Self, SyncError> {
        let base_url = ServerBaseUrl::parse(server)?;
        let email = email.into();
        if email.trim().is_empty()
            || email.contains(':')
            || email.chars().any(char::is_control)
            || api_key.expose_secret().is_empty()
        {
            return Err(SyncError::InvalidInput);
        }

        let http = secure_http_client(None).map_err(|message| SyncError::Transport { message })?;
        Ok(Self {
            http,
            base_url,
            email,
            api_key,
        })
    }

    /// Atomically registers a queue and normalizes its initial state.
    ///
    /// # Errors
    ///
    /// Returns [`SyncError`] for transport, status, size, or schema failures.
    pub async fn register(&self) -> Result<RegisteredQueue, SyncError> {
        let client_capabilities = json!({
            "bulk_message_deletion": true,
            "empty_topic_name": true,
            "notification_settings_null": true,
            "simplified_presence_events": true,
            "user_list_incomplete": true
        })
        .to_string();

        let response = self
            .http
            .post(self.base_url.endpoint(REGISTER_PATH))
            .timeout(DEFAULT_REQUEST_TIMEOUT)
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[
                ("apply_markdown", "true"),
                ("client_gravatar", "false"),
                ("slim_presence", "true"),
                ("include_subscribers", "false"),
                ("event_types", EVENT_TYPES_JSON),
                ("fetch_event_types", EVENT_TYPES_JSON),
                ("client_capabilities", client_capabilities.as_str()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: RegisterDocument =
            decode_response(response, MAX_REGISTER_RESPONSE_BYTES).await?;
        document.normalize()
    }

    /// Performs one blocking event poll using the timeout advertised at registration.
    ///
    /// The returned events are normalized but not acknowledged locally until
    /// the caller passes them to [`SyncReducer`].
    ///
    /// # Errors
    ///
    /// Returns [`SyncError`] for transport, status, size, or event schema failures.
    pub async fn poll(&self, queue: &EventQueue) -> Result<Vec<SyncEvent>, SyncError> {
        if queue.id.trim().is_empty() {
            return Err(SyncError::InvalidInput);
        }

        let response = self
            .http
            .get(self.base_url.endpoint(EVENTS_PATH))
            .timeout(queue.longpoll_timeout)
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .query(&[
                ("queue_id", queue.id.clone()),
                ("last_event_id", queue.last_event_id.to_string()),
                ("dont_block", "false".to_owned()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: EventsDocument = decode_response(response, MAX_EVENTS_RESPONSE_BYTES).await?;
        if document
            .result
            .as_deref()
            .is_some_and(|result| result != "success")
        {
            if document.code.as_deref() == Some("BAD_EVENT_QUEUE_ID") {
                return Err(SyncError::BadEventQueue);
            }
            return Err(SyncError::InvalidResponse("result was not success"));
        }
        if document
            .queue_id
            .as_deref()
            .is_some_and(|queue_id| queue_id != queue.id)
        {
            return Err(SyncError::InvalidResponse("queue identifier changed"));
        }

        // One event this client cannot interpret must not poison the queue: a
        // failed poll never advances the cursor, so the same event would be
        // redelivered forever. Degrade it to an ignorable event instead.
        Ok(document
            .events
            .into_iter()
            .map(|event| {
                let event_id = event.id;
                let event_type = event.event_type.clone();
                event.normalize().unwrap_or_else(|_| SyncEvent::Unknown {
                    event_id,
                    event_type: format!("{event_type}/malformed"),
                })
            })
            .collect())
    }
}

/// Validation failures for an exponential retry policy.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RecoveryPolicyError {
    /// Delay values must be at least one millisecond.
    #[error("recovery delays must be at least one millisecond")]
    ZeroDelay,
    /// The initial delay cannot be longer than the maximum delay.
    #[error("the initial recovery delay exceeds the maximum")]
    InitialExceedsMaximum,
    /// Jitter is limited to half of the base delay.
    #[error("recovery jitter must be at most 50 percent")]
    ExcessiveJitter,
}

/// Bounded exponential retry timings.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RecoveryPolicy {
    initial_delay: Duration,
    maximum_delay: Duration,
    jitter_percent: u8,
}

impl RecoveryPolicy {
    /// Validates retry timing and jitter settings.
    ///
    /// # Errors
    ///
    /// Returns [`RecoveryPolicyError`] for sub-millisecond delays, an inverted
    /// range, or jitter greater than 50 percent.
    pub fn new(
        initial_delay: Duration,
        maximum_delay: Duration,
        jitter_percent: u8,
    ) -> Result<Self, RecoveryPolicyError> {
        if initial_delay.as_millis() == 0 || maximum_delay.as_millis() == 0 {
            return Err(RecoveryPolicyError::ZeroDelay);
        }
        if initial_delay > maximum_delay {
            return Err(RecoveryPolicyError::InitialExceedsMaximum);
        }
        if jitter_percent > 50 {
            return Err(RecoveryPolicyError::ExcessiveJitter);
        }
        Ok(Self {
            initial_delay,
            maximum_delay,
            jitter_percent,
        })
    }
}

impl Default for RecoveryPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_secs(1),
            maximum_delay: Duration::from_mins(1),
            jitter_percent: 20,
        }
    }
}

#[derive(Debug)]
struct RetryBackoff {
    policy: RecoveryPolicy,
    attempt: u32,
    jitter_state: u64,
}

impl RetryBackoff {
    fn new(policy: RecoveryPolicy, jitter_seed: u64) -> Self {
        Self {
            policy,
            attempt: 0,
            jitter_state: if jitter_seed == 0 {
                0x9e37_79b9_7f4a_7c15
            } else {
                jitter_seed
            },
        }
    }

    fn next_delay(&mut self) -> Duration {
        let exponent = self.attempt.min(63);
        let multiplier = 1_u128 << exponent;
        let maximum_millis = self.policy.maximum_delay.as_millis();
        let base_millis = self
            .policy
            .initial_delay
            .as_millis()
            .saturating_mul(multiplier)
            .min(maximum_millis);
        let jitter_span = base_millis.saturating_mul(u128::from(self.policy.jitter_percent)) / 100;

        self.jitter_state ^= self.jitter_state << 13;
        self.jitter_state ^= self.jitter_state >> 7;
        self.jitter_state ^= self.jitter_state << 17;

        let jitter_width = jitter_span.saturating_mul(2).saturating_add(1);
        let jitter_offset = if jitter_width == 0 {
            0
        } else {
            u128::from(self.jitter_state) % jitter_width
        };
        let delayed_millis = base_millis
            .saturating_sub(jitter_span)
            .saturating_add(jitter_offset)
            .min(maximum_millis);
        self.attempt = self.attempt.saturating_add(1);

        Duration::from_millis(u64::try_from(delayed_millis).unwrap_or(u64::MAX))
    }

    fn reset(&mut self) {
        self.attempt = 0;
    }
}

/// Why the current event queue must be discarded and registered again.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResyncReason {
    /// The server garbage-collected the old queue.
    QueueExpired,
    /// A `restart` event requested a complete reload.
    ServerRestart,
}

/// Work the actor should retry after a returned delay.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryOperation {
    /// Poll the existing event queue again.
    Poll,
    /// Retry an atomic queue registration and full state replacement.
    FullResync(ResyncReason),
}

/// Result of one recovery-aware session advance.
#[derive(Debug)]
pub enum SyncCycle {
    /// A successful poll, with an optional changed snapshot.
    Events(BatchOutcome),
    /// A stale queue was atomically replaced with fresh state.
    Resynchronized {
        /// Trigger for the full reload.
        reason: ResyncReason,
        /// Complete immutable replacement snapshot.
        snapshot: SyncSnapshot,
    },
    /// A transient failure that the actor should retry after the given delay.
    RetryAfter {
        /// Exponential delay including bounded jitter.
        delay: Duration,
        /// Operation to run after waiting.
        operation: RetryOperation,
        /// Sanitized failure suitable for diagnostics.
        error: SyncError,
    },
    /// A non-retryable failure requiring user action or a new session.
    Fatal {
        /// Sanitized terminal error.
        error: SyncError,
    },
}

/// Recovery-aware owner of one queue, reducer, and retry state.
///
/// The Rust actor calls [`Self::advance`] and schedules returned retry delays.
/// This type never sleeps and does not cross the FFI boundary.
#[derive(Debug)]
pub struct SyncSession {
    client: EventQueueClient,
    queue: EventQueue,
    reducer: SyncReducer,
    backoff: RetryBackoff,
    pending_resync: Option<ResyncReason>,
}

impl SyncSession {
    /// Registers the initial queue and returns the first full snapshot.
    ///
    /// `jitter_seed` is non-secret and makes retry timing reproducible in
    /// deterministic tests while still allowing accounts to use distinct
    /// schedules in production.
    ///
    /// # Errors
    ///
    /// Returns [`SyncError`] when initial queue registration fails.
    pub async fn start(
        client: EventQueueClient,
        policy: RecoveryPolicy,
        jitter_seed: u64,
    ) -> Result<(Self, SyncSnapshot), SyncError> {
        let registered = client.register().await?;
        let reducer = SyncReducer::new(registered.queue.last_event_id, registered.bootstrap);
        let snapshot = reducer.snapshot();
        Ok((
            Self {
                client,
                queue: registered.queue,
                reducer,
                backoff: RetryBackoff::new(policy, jitter_seed),
                pending_resync: None,
            },
            snapshot,
        ))
    }

    /// Returns the active queue metadata for persistence and diagnostics.
    #[must_use]
    pub const fn queue(&self) -> &EventQueue {
        &self.queue
    }

    /// Returns the current immutable domain snapshot.
    #[must_use]
    pub fn snapshot(&self) -> SyncSnapshot {
        self.reducer.snapshot()
    }

    /// Polls or continues a pending full resynchronization.
    ///
    /// Queue expiry and fresh `restart` events immediately attempt an atomic
    /// registration. Transient failures return a delay instead of sleeping.
    pub async fn advance(&mut self) -> SyncCycle {
        if let Some(reason) = self.pending_resync {
            return self.attempt_resync(reason).await;
        }

        match self.client.poll(&self.queue).await {
            Ok(events) => {
                let restart_requested = events.iter().any(|event| {
                    matches!(event, SyncEvent::ServerRestart { .. })
                        && event.event_id() > self.reducer.last_event_id()
                });
                if restart_requested {
                    self.pending_resync = Some(ResyncReason::ServerRestart);
                    return self.attempt_resync(ResyncReason::ServerRestart).await;
                }

                self.backoff.reset();
                let outcome = self.reducer.apply_batch(events);
                self.queue.last_event_id = self.reducer.last_event_id();
                SyncCycle::Events(outcome)
            }
            Err(SyncError::BadEventQueue) => {
                self.pending_resync = Some(ResyncReason::QueueExpired);
                self.attempt_resync(ResyncReason::QueueExpired).await
            }
            Err(error) if is_retryable(&error) => SyncCycle::RetryAfter {
                delay: self.backoff.next_delay(),
                operation: RetryOperation::Poll,
                error,
            },
            Err(error) => SyncCycle::Fatal { error },
        }
    }

    async fn attempt_resync(&mut self, reason: ResyncReason) -> SyncCycle {
        match self.client.register().await {
            Ok(registered) => {
                let next_revision = self.reducer.revision().saturating_add(1);
                let new_reducer = SyncReducer::with_revision(
                    registered.queue.last_event_id,
                    registered.bootstrap,
                    next_revision,
                );
                let snapshot = new_reducer.snapshot();

                self.queue = registered.queue;
                self.reducer = new_reducer;
                self.pending_resync = None;
                self.backoff.reset();
                SyncCycle::Resynchronized { reason, snapshot }
            }
            Err(error) if is_retryable(&error) || matches!(error, SyncError::BadEventQueue) => {
                SyncCycle::RetryAfter {
                    delay: self.backoff.next_delay(),
                    operation: RetryOperation::FullResync(reason),
                    error,
                }
            }
            Err(error) => SyncCycle::Fatal { error },
        }
    }
}

/// Everything except a credential rejection or locally invalid configuration is
/// retried with backoff, so an unexpected server response degrades the
/// connection state instead of silently ending the session.
fn is_retryable(error: &SyncError) -> bool {
    !matches!(
        error,
        SyncError::Unauthorized | SyncError::InvalidInput | SyncError::InvalidServer(_)
    )
}

/// Ordered, idempotent reducer owned by the Rust core actor.
#[derive(Debug)]
pub struct SyncReducer {
    revision: u64,
    last_event_id: i64,
    users: BTreeMap<i64, UserSummary>,
    channels: BTreeMap<i64, ChannelSummary>,
    messages: BTreeMap<i64, MessageSummary>,
}

impl SyncReducer {
    /// Creates a reducer from the atomic state and cursor returned by `register`.
    #[must_use]
    pub fn new(last_event_id: i64, bootstrap: BootstrapState) -> Self {
        Self::with_revision(last_event_id, bootstrap, 1)
    }

    fn with_revision(last_event_id: i64, bootstrap: BootstrapState, revision: u64) -> Self {
        Self {
            revision,
            last_event_id,
            users: bootstrap
                .users
                .into_iter()
                .map(|user| (user.id, user))
                .collect(),
            channels: bootstrap
                .channels
                .into_iter()
                .map(|channel| (channel.id, channel))
                .collect(),
            messages: bootstrap
                .messages
                .into_iter()
                .map(|message| (message.id, message))
                .collect(),
        }
    }

    /// Returns an immutable projection of current state.
    #[must_use]
    pub fn snapshot(&self) -> SyncSnapshot {
        SyncSnapshot {
            revision: self.revision,
            last_event_id: self.last_event_id,
            users: self.users.values().cloned().collect(),
            channels: self.channels.values().cloned().collect(),
            messages: self.messages.values().cloned().collect(),
        }
    }

    /// Returns the current snapshot revision.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Returns the highest accepted event identifier.
    #[must_use]
    pub const fn last_event_id(&self) -> i64 {
        self.last_event_id
    }

    /// Reduces one poll response and publishes no more than one new snapshot.
    ///
    /// Events are sorted defensively. IDs need not be consecutive; duplicates
    /// and values older than the current cursor are ignored.
    #[must_use]
    pub fn apply_batch(&mut self, mut events: Vec<SyncEvent>) -> BatchOutcome {
        events.sort_by_key(SyncEvent::event_id);

        let mut accepted_events = 0;
        let mut ignored_events = 0;
        let mut heartbeats = 0;
        let mut domain_changed = false;

        for event in events {
            let event_id = event.event_id();
            if event_id <= self.last_event_id {
                ignored_events += 1;
                continue;
            }

            accepted_events += 1;
            domain_changed |= self.apply_event(event, &mut heartbeats);
            self.last_event_id = event_id;
        }

        let snapshot = if domain_changed {
            self.revision = self.revision.saturating_add(1);
            Some(self.snapshot())
        } else {
            None
        };

        BatchOutcome {
            accepted_events,
            ignored_events,
            heartbeats,
            snapshot,
        }
    }

    fn apply_flag_change(&mut self, added: bool, flag: &str, message_ids: &[i64]) -> bool {
        let mut changed = false;
        for message_id in message_ids {
            let Some(message) = self.messages.get_mut(message_id) else {
                continue;
            };
            let present = message.flags.iter().any(|existing| existing == flag);
            if added && !present {
                message.flags.push(flag.to_owned());
                changed = true;
            } else if !added && present {
                message.flags.retain(|existing| existing != flag);
                changed = true;
            }
        }
        changed
    }

    fn apply_reaction_change(
        &mut self,
        added: bool,
        message_id: i64,
        reaction: ReactionSummary,
    ) -> bool {
        let Some(message) = self.messages.get_mut(&message_id) else {
            return false;
        };
        let present = message.reactions.contains(&reaction);
        if added && !present {
            message.reactions.push(reaction);
            true
        } else if !added && present {
            message.reactions.retain(|existing| *existing != reaction);
            true
        } else {
            false
        }
    }

    fn apply_event(&mut self, event: SyncEvent, heartbeats: &mut usize) -> bool {
        match event {
            SyncEvent::Heartbeat { .. } => {
                *heartbeats += 1;
                false
            }
            SyncEvent::ServerRestart { .. } | SyncEvent::Unknown { .. } => false,
            SyncEvent::MessageAdded { message, .. } => {
                let previous = self.messages.insert(message.id, message.clone());
                previous.as_ref() != Some(&message)
            }
            SyncEvent::MessageUpdated { update, .. } => {
                let Some(message) = self.messages.get_mut(&update.message_id) else {
                    return false;
                };
                let previous = message.clone();
                if let Some(content_html) = update.content_html {
                    message.content_html = content_html;
                }
                if let Some(topic) = update.topic {
                    message.topic = Some(topic);
                }
                if let Some(stream_id) = update.stream_id {
                    message.stream_id = Some(stream_id);
                }
                *message != previous
            }
            SyncEvent::MessagesDeleted { message_ids, .. } => message_ids
                .into_iter()
                .any(|message_id| self.messages.remove(&message_id).is_some()),
            SyncEvent::MessageFlagsUpdated {
                added,
                flag,
                message_ids,
                ..
            } => self.apply_flag_change(added, &flag, &message_ids),
            SyncEvent::ReactionChanged {
                added,
                message_id,
                reaction,
                ..
            } => self.apply_reaction_change(added, message_id, reaction),
            SyncEvent::ChannelsUpserted { channels, .. } => {
                let mut changed = false;
                for channel in channels {
                    let previous = self.channels.insert(channel.id, channel.clone());
                    changed |= previous.as_ref() != Some(&channel);
                }
                changed
            }
            SyncEvent::ChannelUpdated { update, .. } => {
                let Some(channel) = self.channels.get_mut(&update.channel_id) else {
                    return false;
                };
                let previous = channel.clone();
                if let Some(name) = update.name {
                    channel.name = name;
                }
                if let Some(color) = update.color {
                    channel.color = color;
                }
                if let Some(is_muted) = update.is_muted {
                    channel.is_muted = is_muted;
                }
                *channel != previous
            }
            SyncEvent::ChannelsRemoved { channel_ids, .. } => channel_ids
                .into_iter()
                .any(|channel_id| self.channels.remove(&channel_id).is_some()),
            SyncEvent::UserUpserted { user, .. } => {
                let previous = self.users.insert(user.id, user.clone());
                previous.as_ref() != Some(&user)
            }
            SyncEvent::UserUpdated { update, .. } => {
                let Some(user) = self.users.get_mut(&update.user_id) else {
                    return false;
                };
                let previous = user.clone();
                if let Some(full_name) = update.full_name {
                    user.full_name = full_name;
                }
                if let Some(email) = update.email {
                    user.email = Some(email);
                }
                if let Some(is_active) = update.is_active {
                    user.is_active = is_active;
                }
                if let Some(is_bot) = update.is_bot {
                    user.is_bot = is_bot;
                }
                *user != previous
            }
            SyncEvent::UserRemoved { user_id, .. } => self.users.remove(&user_id).is_some(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct RegisterDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    queue_id: Option<String>,
    last_event_id: Option<i64>,
    #[serde(default)]
    event_queue_longpoll_timeout_seconds: Option<u64>,
    #[serde(default)]
    idle_queue_timeout_secs: Option<u64>,
    #[serde(default)]
    zulip_feature_level: u64,
    #[serde(default)]
    realm_users: Vec<UserDocument>,
    #[serde(default)]
    subscriptions: Vec<ChannelDocument>,
    #[serde(default)]
    messages: Vec<MessageDocument>,
}

impl RegisterDocument {
    fn normalize(self) -> Result<RegisteredQueue, SyncError> {
        if self
            .result
            .as_deref()
            .is_some_and(|result| result != "success")
        {
            if self.code.as_deref() == Some("BAD_EVENT_QUEUE_ID") {
                return Err(SyncError::BadEventQueue);
            }
            return Err(SyncError::InvalidResponse("result was not success"));
        }
        let queue_id = self
            .queue_id
            .filter(|value| !value.trim().is_empty())
            .ok_or(SyncError::InvalidResponse("missing queue identifier"))?;
        let last_event_id = self
            .last_event_id
            .ok_or(SyncError::InvalidResponse("missing event cursor"))?;
        let longpoll_timeout =
            self.event_queue_longpoll_timeout_seconds
                .map_or(DEFAULT_LONGPOLL_TIMEOUT, |seconds| {
                    Duration::from_secs(
                        seconds.clamp(MIN_LONGPOLL_TIMEOUT_SECONDS, MAX_LONGPOLL_TIMEOUT_SECONDS),
                    )
                });

        // A single unusable user, channel, or message must not make the whole
        // account impossible to register.
        let users = self
            .realm_users
            .into_iter()
            .filter_map(|user| user.normalize().ok())
            .collect();
        let channels = self
            .subscriptions
            .into_iter()
            .filter_map(|channel| channel.normalize().ok())
            .collect();
        let messages = self
            .messages
            .into_iter()
            .filter_map(|message| message.normalize().ok())
            .collect();

        Ok(RegisteredQueue {
            queue: EventQueue {
                id: queue_id,
                last_event_id,
                longpoll_timeout,
                idle_timeout_seconds: self.idle_queue_timeout_secs,
            },
            bootstrap: BootstrapState {
                users,
                channels,
                messages,
            },
            zulip_feature_level: self.zulip_feature_level,
        })
    }
}

#[derive(Debug, Deserialize)]
struct EventsDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    queue_id: Option<String>,
    #[serde(default)]
    events: Vec<EventDocument>,
}

#[derive(Debug, Deserialize)]
struct EventDocument {
    id: i64,
    #[serde(rename = "type")]
    event_type: String,
    #[serde(flatten)]
    payload: Map<String, Value>,
}

impl EventDocument {
    fn normalize(self) -> Result<SyncEvent, SyncError> {
        match self.event_type.as_str() {
            "heartbeat" => Ok(SyncEvent::Heartbeat { event_id: self.id }),
            "restart" => Ok(SyncEvent::ServerRestart { event_id: self.id }),
            "message" => {
                let message = value_field(&self.payload, "message")?;
                let message: MessageDocument = serde_json::from_value(message.clone())
                    .map_err(|_| SyncError::InvalidResponse("invalid message event"))?;
                Ok(SyncEvent::MessageAdded {
                    event_id: self.id,
                    message: message.normalize()?,
                })
            }
            "update_message" => Ok(SyncEvent::MessageUpdated {
                event_id: self.id,
                update: MessageUpdate {
                    message_id: integer_field(&self.payload, "message_id")?,
                    content_html: string_field(&self.payload, "rendered_content")
                        .or_else(|| string_field(&self.payload, "content")),
                    topic: string_field(&self.payload, "topic")
                        .or_else(|| string_field(&self.payload, "subject")),
                    stream_id: optional_integer_field(&self.payload, "stream_id")
                        .or_else(|| optional_integer_field(&self.payload, "new_stream_id")),
                },
            }),
            "delete_message" => {
                let mut message_ids = integer_array_field(&self.payload, "message_ids");
                if message_ids.is_empty()
                    && let Some(message_id) = optional_integer_field(&self.payload, "message_id")
                {
                    message_ids.push(message_id);
                }
                if message_ids.is_empty() {
                    return Err(SyncError::InvalidResponse(
                        "delete event had no message identifiers",
                    ));
                }
                Ok(SyncEvent::MessagesDeleted {
                    event_id: self.id,
                    message_ids,
                })
            }
            "update_message_flags" => {
                let flag = string_field(&self.payload, "flag")
                    .ok_or(SyncError::InvalidResponse("flag update missing flag name"))?;
                Ok(SyncEvent::MessageFlagsUpdated {
                    event_id: self.id,
                    added: string_field(&self.payload, "op").as_deref() != Some("remove"),
                    flag,
                    message_ids: integer_array_field(&self.payload, "messages"),
                })
            }
            "reaction" => {
                let reaction = ReactionDocument {
                    emoji_name: string_field(&self.payload, "emoji_name").unwrap_or_default(),
                    user_id: optional_integer_field(&self.payload, "user_id").unwrap_or(0),
                }
                .normalize()
                .ok_or(SyncError::InvalidResponse("invalid reaction event"))?;
                Ok(SyncEvent::ReactionChanged {
                    event_id: self.id,
                    added: string_field(&self.payload, "op").as_deref() != Some("remove"),
                    message_id: integer_field(&self.payload, "message_id")?,
                    reaction,
                })
            }
            "subscription" => self.normalize_subscription(),
            "realm_user" => self.normalize_user(),
            _ => Ok(SyncEvent::Unknown {
                event_id: self.id,
                event_type: self.event_type,
            }),
        }
    }

    fn normalize_subscription(self) -> Result<SyncEvent, SyncError> {
        let operation = string_field(&self.payload, "op").ok_or(SyncError::InvalidResponse(
            "subscription event missing operation",
        ))?;
        if operation == "update" {
            let channel_id = integer_field(&self.payload, "stream_id")?;
            let property = string_field(&self.payload, "property").ok_or(
                SyncError::InvalidResponse("subscription update missing property"),
            )?;
            let update = match property.as_str() {
                "is_muted" => ChannelUpdate {
                    channel_id,
                    is_muted: self.payload.get("value").and_then(Value::as_bool),
                    ..ChannelUpdate::default()
                },
                "name" => ChannelUpdate {
                    channel_id,
                    name: string_field(&self.payload, "value"),
                    ..ChannelUpdate::default()
                },
                "color" => ChannelUpdate {
                    channel_id,
                    color: string_field(&self.payload, "value"),
                    ..ChannelUpdate::default()
                },
                _ => {
                    return Ok(SyncEvent::Unknown {
                        event_id: self.id,
                        event_type: format!("subscription/update/{property}"),
                    });
                }
            };
            return Ok(SyncEvent::ChannelUpdated {
                event_id: self.id,
                update,
            });
        }
        if matches!(operation.as_str(), "peer_add" | "peer_remove") {
            return Ok(SyncEvent::Unknown {
                event_id: self.id,
                event_type: format!("subscription/{operation}"),
            });
        }

        let channel_values = self
            .payload
            .get("subscriptions")
            .or_else(|| self.payload.get("streams"))
            .and_then(Value::as_array)
            .ok_or(SyncError::InvalidResponse(
                "subscription event missing channels",
            ))?;

        if operation == "remove" {
            let channel_ids = channel_values
                .iter()
                .map(|value| {
                    value.get("stream_id").and_then(Value::as_i64).ok_or(
                        SyncError::InvalidResponse(
                            "subscription removal missing channel identifier",
                        ),
                    )
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(SyncEvent::ChannelsRemoved {
                event_id: self.id,
                channel_ids,
            })
        } else {
            let channels = channel_values
                .iter()
                .cloned()
                .map(|value| {
                    serde_json::from_value::<ChannelDocument>(value)
                        .map_err(|_| SyncError::InvalidResponse("invalid subscription event"))?
                        .normalize()
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(SyncEvent::ChannelsUpserted {
                event_id: self.id,
                channels,
            })
        }
    }

    fn normalize_user(self) -> Result<SyncEvent, SyncError> {
        let operation = string_field(&self.payload, "op")
            .ok_or(SyncError::InvalidResponse("user event missing operation"))?;
        let person = value_field(&self.payload, "person")?;
        if operation == "remove" {
            let user_id =
                person
                    .get("user_id")
                    .and_then(Value::as_i64)
                    .ok_or(SyncError::InvalidResponse(
                        "user removal missing user identifier",
                    ))?;
            Ok(SyncEvent::UserRemoved {
                event_id: self.id,
                user_id,
            })
        } else if operation == "update" {
            let user_id =
                person
                    .get("user_id")
                    .and_then(Value::as_i64)
                    .ok_or(SyncError::InvalidResponse(
                        "user update missing user identifier",
                    ))?;
            Ok(SyncEvent::UserUpdated {
                event_id: self.id,
                update: UserUpdate {
                    user_id,
                    full_name: person
                        .get("full_name")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    email: person
                        .get("new_email")
                        .or_else(|| person.get("email"))
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    is_active: person.get("is_active").and_then(Value::as_bool),
                    is_bot: person.get("is_bot").and_then(Value::as_bool),
                },
            })
        } else {
            let user: UserDocument = serde_json::from_value(person.clone())
                .map_err(|_| SyncError::InvalidResponse("invalid user event"))?;
            Ok(SyncEvent::UserUpserted {
                event_id: self.id,
                user: user.normalize()?,
            })
        }
    }
}

#[derive(Debug, Deserialize)]
struct UserDocument {
    user_id: i64,
    full_name: String,
    #[serde(default)]
    email: Option<String>,
    #[serde(default = "default_true")]
    is_active: bool,
    #[serde(default)]
    is_bot: bool,
}

impl UserDocument {
    fn normalize(self) -> Result<UserSummary, SyncError> {
        if self.full_name.trim().is_empty() {
            return Err(SyncError::InvalidResponse("user missing display name"));
        }
        Ok(UserSummary {
            id: self.user_id,
            full_name: self.full_name,
            email: self.email,
            is_active: self.is_active,
            is_bot: self.is_bot,
        })
    }
}

#[derive(Debug, Deserialize)]
struct ChannelDocument {
    stream_id: i64,
    name: String,
    #[serde(default = "default_channel_color")]
    color: String,
    #[serde(default)]
    is_muted: bool,
}

impl ChannelDocument {
    fn normalize(self) -> Result<ChannelSummary, SyncError> {
        if self.name.trim().is_empty() {
            return Err(SyncError::InvalidResponse("channel missing name"));
        }
        Ok(ChannelSummary {
            id: self.stream_id,
            name: self.name,
            color: self.color,
            is_muted: self.is_muted,
        })
    }
}

#[derive(Debug, Deserialize)]
struct MessageDocument {
    id: i64,
    sender_id: i64,
    #[serde(default)]
    sender_full_name: String,
    timestamp: i64,
    content: String,
    #[serde(rename = "type")]
    message_type: String,
    #[serde(default)]
    stream_id: Option<i64>,
    #[serde(default, alias = "subject")]
    topic: Option<String>,
    #[serde(default)]
    display_recipient: Value,
    #[serde(default)]
    flags: Vec<String>,
    #[serde(default)]
    reactions: Vec<ReactionDocument>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct ReactionDocument {
    emoji_name: String,
    user_id: i64,
}

impl ReactionDocument {
    pub(crate) fn normalize(self) -> Option<ReactionSummary> {
        if self.user_id <= 0
            || self.emoji_name.trim().is_empty()
            || self.emoji_name.chars().any(char::is_control)
        {
            return None;
        }
        Some(ReactionSummary {
            emoji_name: self.emoji_name,
            user_id: self.user_id,
        })
    }
}

impl MessageDocument {
    fn normalize(self) -> Result<MessageSummary, SyncError> {
        let is_channel = matches!(self.message_type.as_str(), "stream" | "channel");
        if !is_channel && self.message_type != "private" {
            return Err(SyncError::InvalidResponse("unknown message type"));
        }
        if is_channel && self.stream_id.is_none() {
            return Err(SyncError::InvalidResponse(
                "channel message missing channel identifier",
            ));
        }

        let recipient_ids = if is_channel {
            Vec::new()
        } else {
            self.display_recipient
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|recipient| recipient.get("id").and_then(Value::as_i64))
                .collect()
        };

        Ok(MessageSummary {
            id: self.id,
            sender_id: self.sender_id,
            sender_full_name: self.sender_full_name,
            timestamp: self.timestamp,
            content_html: self.content,
            stream_id: self.stream_id,
            topic: self.topic,
            recipient_ids,
            flags: self.flags,
            reactions: self
                .reactions
                .into_iter()
                .filter_map(ReactionDocument::normalize)
                .collect(),
        })
    }
}

fn default_true() -> bool {
    true
}

fn default_channel_color() -> String {
    "#888888".to_owned()
}

fn value_field<'a>(
    payload: &'a Map<String, Value>,
    name: &'static str,
) -> Result<&'a Value, SyncError> {
    payload
        .get(name)
        .ok_or(SyncError::InvalidResponse("event missing required field"))
}

fn integer_field(payload: &Map<String, Value>, name: &'static str) -> Result<i64, SyncError> {
    optional_integer_field(payload, name)
        .ok_or(SyncError::InvalidResponse("event missing integer field"))
}

fn optional_integer_field(payload: &Map<String, Value>, name: &str) -> Option<i64> {
    payload.get(name).and_then(Value::as_i64)
}

fn integer_array_field(payload: &Map<String, Value>, name: &str) -> Vec<i64> {
    payload
        .get(name)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_i64)
        .collect()
}

fn string_field(payload: &Map<String, Value>, name: &str) -> Option<String> {
    payload.get(name).and_then(Value::as_str).map(str::to_owned)
}

fn transport_error(error: reqwest::Error) -> SyncError {
    SyncError::Transport {
        message: error.without_url().to_string(),
    }
}

async fn decode_response<T: DeserializeOwned>(
    response: Response,
    maximum_bytes: usize,
) -> Result<T, SyncError> {
    let status = response.status();
    if response
        .content_length()
        .is_some_and(|length| length > u64::try_from(maximum_bytes).unwrap_or(u64::MAX))
    {
        return Err(SyncError::ResponseTooLarge);
    }

    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(transport_error)?;
        if bytes.len().saturating_add(chunk.len()) > maximum_bytes {
            return Err(SyncError::ResponseTooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }

    if !status.is_success() {
        let code = serde_json::from_slice::<ApiErrorDocument>(&bytes)
            .ok()
            .and_then(|error| error.code);
        if code.as_deref() == Some("BAD_EVENT_QUEUE_ID") {
            return Err(SyncError::BadEventQueue);
        }
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(SyncError::Unauthorized);
        }
        return Err(SyncError::HttpStatus(status.as_u16()));
    }

    serde_json::from_slice(&bytes).map_err(|_| SyncError::InvalidResponse("invalid JSON"))
}

#[derive(Debug, Deserialize)]
struct ApiErrorDocument {
    code: Option<String>,
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc,
        thread,
        time::Duration,
    };

    use reqwest::StatusCode;

    use super::{
        BootstrapState, ChannelSummary, EventQueueClient, MessageSummary, MessageUpdate,
        RecoveryPolicy, ResyncReason, RetryBackoff, RetryOperation, SyncCycle, SyncError,
        SyncEvent, SyncReducer, SyncSession, UserSummary,
    };
    use crate::auth::SecretString;

    const API_KEY: &str = "fixture-sync-key-do-not-log";

    #[tokio::test]
    async fn register_and_poll_follow_the_zulip_protocol() {
        let responses = vec![
            (
                StatusCode::OK,
                r##"{
                    "result":"success",
                    "queue_id":"queue-fixture",
                    "last_event_id":40,
                    "event_queue_longpoll_timeout_seconds":95,
                    "idle_queue_timeout_secs":600,
                    "zulip_feature_level":481,
                    "realm_users":[{
                        "user_id":7,
                        "full_name":"Maya Chen",
                        "email":"maya@example.com",
                        "is_active":true,
                        "is_bot":false
                    }],
                    "subscriptions":[{
                        "stream_id":5,
                        "name":"engineering",
                        "color":"#76ce90",
                        "is_muted":false
                    }]
                }"##
                .to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "queue_id":"queue-fixture",
                    "events":[
                        {"id":43,"type":"heartbeat"},
                        {
                            "id":47,
                            "type":"message",
                            "message":{
                                "id":9001,
                                "sender_id":7,
                                "sender_full_name":"Maya Chen",
                                "timestamp":1770000000,
                                "content":"<p>Hello</p>",
                                "type":"stream",
                                "stream_id":5,
                                "topic":"Rust core",
                                "display_recipient":"engineering"
                            }
                        },
                        {
                            "id":49,
                            "type":"subscription",
                            "op":"update",
                            "stream_id":5,
                            "property":"is_muted",
                            "value":true
                        },
                        {
                            "id":52,
                            "type":"realm_user",
                            "op":"update",
                            "person":{"user_id":7,"full_name":"Maya C."}
                        }
                    ]
                }"#
                .to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");

        let registered = client.register().await.expect("register queue");
        assert_eq!(registered.queue.id, "queue-fixture");
        assert_eq!(registered.queue.last_event_id, 40);
        assert_eq!(registered.queue.longpoll_timeout.as_secs(), 95);
        assert_eq!(registered.queue.idle_timeout_seconds, Some(600));
        assert_eq!(registered.zulip_feature_level, 481);
        assert_eq!(registered.bootstrap.users[0].full_name, "Maya Chen");
        assert_eq!(registered.bootstrap.channels[0].name, "engineering");

        let register_request = requests.recv().expect("register request");
        assert_register_request(&register_request);

        let events = client.poll(&registered.queue).await.expect("event poll");
        assert!(matches!(events[0], SyncEvent::Heartbeat { event_id: 43 }));
        assert!(matches!(
            &events[1],
            SyncEvent::MessageAdded { event_id: 47, message }
                if message.id == 9001 && message.topic.as_deref() == Some("Rust core")
        ));
        assert!(matches!(
            &events[2],
            SyncEvent::ChannelUpdated { event_id: 49, update }
                if update.channel_id == 5 && update.is_muted == Some(true)
        ));
        assert!(matches!(
            &events[3],
            SyncEvent::UserUpdated { event_id: 52, update }
                if update.user_id == 7 && update.full_name.as_deref() == Some("Maya C.")
        ));

        let poll_request = requests.recv().expect("poll request");
        assert_poll_request(&poll_request);
    }

    #[test]
    fn reducer_sorts_deduplicates_and_batches_one_snapshot() {
        let mut reducer = SyncReducer::new(
            10,
            BootstrapState {
                users: vec![fixture_user(7, "Maya")],
                channels: vec![fixture_channel(5, "engineering")],
                messages: vec![],
            },
        );
        let message = fixture_message(100, "<p>first</p>");

        let outcome = reducer.apply_batch(vec![
            SyncEvent::MessageUpdated {
                event_id: 15,
                update: MessageUpdate {
                    message_id: 100,
                    content_html: Some("<p>edited</p>".to_owned()),
                    topic: None,
                    stream_id: None,
                },
            },
            SyncEvent::Heartbeat { event_id: 12 },
            SyncEvent::MessageAdded {
                event_id: 14,
                message,
            },
            SyncEvent::Heartbeat { event_id: 12 },
        ]);

        assert_eq!(outcome.accepted_events, 3);
        assert_eq!(outcome.ignored_events, 1);
        assert_eq!(outcome.heartbeats, 1);
        let snapshot = outcome.snapshot.expect("one domain snapshot");
        assert_eq!(snapshot.revision, 2);
        assert_eq!(snapshot.last_event_id, 15);
        assert_eq!(snapshot.messages[0].content_html, "<p>edited</p>");
    }

    #[test]
    fn heartbeat_and_unknown_batches_advance_without_publishing() {
        let mut reducer = SyncReducer::new(20, BootstrapState::default());
        let outcome = reducer.apply_batch(vec![
            SyncEvent::Unknown {
                event_id: 24,
                event_type: "presence".to_owned(),
            },
            SyncEvent::Heartbeat { event_id: 27 },
        ]);

        assert_eq!(outcome.accepted_events, 2);
        assert_eq!(outcome.heartbeats, 1);
        assert!(outcome.snapshot.is_none());
        assert_eq!(reducer.snapshot().last_event_id, 27);
        assert_eq!(reducer.snapshot().revision, 1);
    }

    #[test]
    fn reducer_handles_channel_user_message_update_and_deletion() {
        let mut reducer = SyncReducer::new(
            0,
            BootstrapState {
                users: vec![fixture_user(7, "Old name")],
                channels: vec![fixture_channel(5, "old-channel")],
                messages: vec![fixture_message(100, "<p>old</p>")],
            },
        );

        let outcome = reducer.apply_batch(vec![
            SyncEvent::UserUpserted {
                event_id: 2,
                user: fixture_user(7, "New name"),
            },
            SyncEvent::ChannelsRemoved {
                event_id: 3,
                channel_ids: vec![5],
            },
            SyncEvent::ChannelsUpserted {
                event_id: 4,
                channels: vec![fixture_channel(8, "design")],
            },
            SyncEvent::MessagesDeleted {
                event_id: 8,
                message_ids: vec![100],
            },
        ]);

        let snapshot = outcome.snapshot.expect("domain changed");
        assert_eq!(snapshot.users[0].full_name, "New name");
        assert_eq!(snapshot.channels, vec![fixture_channel(8, "design")]);
        assert!(snapshot.messages.is_empty());
        assert_eq!(snapshot.last_event_id, 8);
    }

    #[tokio::test]
    async fn malformed_queue_and_event_payloads_are_rejected() {
        let (server, _) = spawn_mock(vec![(
            StatusCode::OK,
            r#"{"result":"success","last_event_id":1}"#.to_owned(),
        )]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        assert!(client.register().await.is_err());

        assert!(
            EventQueueClient::new(&server, "unsafe:email", SecretString::new(API_KEY)).is_err()
        );
    }

    #[test]
    fn exponential_backoff_is_bounded_jittered_and_deterministic() {
        let policy = RecoveryPolicy::new(Duration::from_secs(1), Duration::from_secs(8), 20)
            .expect("valid recovery policy");
        let mut first = RetryBackoff::new(policy, 42);
        let mut second = RetryBackoff::new(policy, 42);

        let first_delays = (0..8).map(|_| first.next_delay()).collect::<Vec<_>>();
        let second_delays = (0..8).map(|_| second.next_delay()).collect::<Vec<_>>();
        assert_eq!(first_delays, second_delays);
        assert!(
            first_delays
                .iter()
                .all(|delay| *delay <= Duration::from_secs(8))
        );
        assert!(
            first_delays[0] >= Duration::from_millis(800)
                && first_delays[0] <= Duration::from_millis(1_200)
        );

        first.reset();
        let reset_delay = first.next_delay();
        assert!(
            reset_delay >= Duration::from_millis(800)
                && reset_delay <= Duration::from_millis(1_200)
        );
    }

    #[tokio::test]
    async fn expired_queue_is_atomically_reregistered() {
        let responses = vec![
            (StatusCode::OK, register_body("old-queue", 10, "old")),
            (
                StatusCode::BAD_REQUEST,
                r#"{"result":"error","code":"BAD_EVENT_QUEUE_ID","msg":"Bad event queue id"}"#
                    .to_owned(),
            ),
            (StatusCode::OK, register_body("new-queue", 50, "fresh")),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, initial) = SyncSession::start(client, RecoveryPolicy::default(), 7)
            .await
            .expect("initial registration");
        assert_eq!(initial.channels[0].name, "old");

        let cycle = session.advance().await;
        let SyncCycle::Resynchronized { reason, snapshot } = cycle else {
            panic!("expired queue should resynchronize");
        };
        assert_eq!(reason, ResyncReason::QueueExpired);
        assert_eq!(snapshot.revision, 2);
        assert_eq!(snapshot.last_event_id, 50);
        assert_eq!(snapshot.channels[0].name, "fresh");
        assert_eq!(session.queue().id, "new-queue");

        assert!(requests.recv().expect("register").starts_with("POST "));
        assert!(requests.recv().expect("poll").starts_with("GET "));
        assert!(requests.recv().expect("reregister").starts_with("POST "));
    }

    #[tokio::test]
    async fn restart_event_forces_full_resynchronization() {
        let responses = vec![
            (StatusCode::OK, register_body("before-restart", 1, "old")),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "queue_id":"before-restart",
                    "events":[{"id":4,"type":"restart","server_generation":9}]
                }"#
                .to_owned(),
            ),
            (StatusCode::OK, register_body("after-restart", 20, "new")),
        ];
        let (server, _) = spawn_mock(responses);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, _) = SyncSession::start(client, RecoveryPolicy::default(), 11)
            .await
            .expect("initial registration");

        let cycle = session.advance().await;
        assert!(matches!(
            cycle,
            SyncCycle::Resynchronized {
                reason: ResyncReason::ServerRestart,
                snapshot
            } if snapshot.revision == 2 && snapshot.channels[0].name == "new"
        ));
        assert_eq!(session.queue().id, "after-restart");
    }

    #[tokio::test]
    async fn disconnect_returns_deterministic_retry_without_mutating_state() {
        let (server, _) = spawn_mock(vec![(
            StatusCode::OK,
            register_body("disconnected", 8, "cached"),
        )]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let policy = RecoveryPolicy::new(Duration::from_millis(100), Duration::from_secs(1), 0)
            .expect("valid policy");
        let (mut session, initial) = SyncSession::start(client, policy, 13)
            .await
            .expect("initial registration");

        let first = session.advance().await;
        assert!(matches!(
            first,
            SyncCycle::RetryAfter {
                delay,
                operation: RetryOperation::Poll,
                ..
            } if delay == Duration::from_millis(100)
        ));
        assert_eq!(session.snapshot(), initial);

        let second = session.advance().await;
        assert!(matches!(
            second,
            SyncCycle::RetryAfter {
                delay,
                operation: RetryOperation::Poll,
                ..
            } if delay == Duration::from_millis(200)
        ));
        assert_eq!(session.snapshot(), initial);
    }

    #[tokio::test]
    async fn flag_and_reaction_events_update_snapshot_messages() {
        let register = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "last_event_id":40,
            "realm_users":[],
            "subscriptions":[{"stream_id":5,"name":"general"}],
            "messages":[{
                "id":7,"sender_id":2,"sender_full_name":"Theo","timestamp":1,
                "content":"<p>hi</p>","type":"stream","stream_id":5,"subject":"t",
                "display_recipient":"general","flags":[]
            }]
        }"#
        .to_owned();
        let events = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "events":[
                {"id":41,"type":"update_message_flags","op":"add","flag":"read","messages":[7,99]},
                {"id":42,"type":"reaction","op":"add","message_id":7,
                 "emoji_name":"thumbs_up","user_id":2},
                {"id":43,"type":"reaction","op":"add","message_id":7,
                 "emoji_name":"thumbs_up","user_id":2}
            ]
        }"#
        .to_owned();
        let removal = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "events":[
                {"id":44,"type":"update_message_flags","op":"remove","flag":"read","messages":[7]},
                {"id":45,"type":"reaction","op":"remove","message_id":7,
                 "emoji_name":"thumbs_up","user_id":2}
            ]
        }"#
        .to_owned();
        let (server, _) = spawn_mock(vec![
            (StatusCode::OK, register),
            (StatusCode::OK, events),
            (StatusCode::OK, removal),
        ]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, _) = SyncSession::start(client, RecoveryPolicy::default(), 3)
            .await
            .expect("initial registration");

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("events expected");
        };
        let message = &outcome.snapshot.expect("changed").messages[0];
        assert_eq!(message.flags, ["read"]);
        assert_eq!(message.reactions.len(), 1, "duplicate reactions collapse");

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("events expected");
        };
        let message = &outcome.snapshot.expect("changed").messages[0];
        assert!(message.flags.is_empty());
        assert!(message.reactions.is_empty());
    }

    #[tokio::test]
    async fn only_a_credential_rejection_is_fatal() {
        let (server, _) = spawn_mock(vec![
            (StatusCode::OK, register_body("queue-fixture", 40, "old")),
            (
                StatusCode::UNAUTHORIZED,
                r#"{"result":"error","code":"UNAUTHORIZED","msg":"Invalid API key"}"#.to_owned(),
            ),
        ]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, _) = SyncSession::start(client, RecoveryPolicy::default(), 3)
            .await
            .expect("initial registration");

        assert!(matches!(
            session.advance().await,
            SyncCycle::Fatal {
                error: SyncError::Unauthorized
            }
        ));
    }

    #[tokio::test]
    async fn unexpected_server_responses_are_retried_not_fatal() {
        let (server, _) = spawn_mock(vec![
            (StatusCode::OK, register_body("queue-fixture", 40, "old")),
            (
                StatusCode::BAD_REQUEST,
                r#"{"result":"error","code":"BAD_REQUEST","msg":"nope"}"#.to_owned(),
            ),
            (StatusCode::OK, "not json".to_owned()),
            (
                StatusCode::OK,
                r#"{"result":"error","code":"SOMETHING_NEW","msg":"new"}"#.to_owned(),
            ),
        ]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, initial) = SyncSession::start(client, RecoveryPolicy::default(), 3)
            .await
            .expect("initial registration");

        for _ in 0..3 {
            assert!(matches!(
                session.advance().await,
                SyncCycle::RetryAfter {
                    operation: RetryOperation::Poll,
                    ..
                }
            ));
        }
        assert_eq!(session.snapshot(), initial);
    }

    #[tokio::test]
    async fn uninterpretable_events_are_skipped_and_advance_the_cursor() {
        let (server, _) = spawn_mock(vec![
            (StatusCode::OK, register_body("queue-fixture", 40, "old")),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "queue_id":"queue-fixture",
                    "events":[
                        {"id":41,"type":"message","message":{"id":1}},
                        {"id":42,"type":"delete_message"},
                        {"id":43,"type":"heartbeat"}
                    ]
                }"#
                .to_owned(),
            ),
        ]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, initial) = SyncSession::start(client, RecoveryPolicy::default(), 3)
            .await
            .expect("initial registration");

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("malformed events should not end the session");
        };
        assert_eq!(outcome.accepted_events, 3);
        assert!(outcome.snapshot.is_none());
        assert_eq!(session.queue().last_event_id, 43);
        assert_eq!(session.snapshot().channels, initial.channels);
    }

    #[tokio::test]
    async fn unusable_bootstrap_entries_do_not_block_registration() {
        let body = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "last_event_id":5,
            "realm_users":[
                {"user_id":1,"full_name":"Maya"},
                {"user_id":2,"full_name":"  "}
            ],
            "subscriptions":[
                {"stream_id":7,"name":"general"},
                {"stream_id":8,"name":""}
            ]
        }"#
        .to_owned();
        let (server, _) = spawn_mock(vec![(StatusCode::OK, body)]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let registered = client.register().await.expect("lenient registration");
        assert_eq!(registered.bootstrap.users.len(), 1);
        assert_eq!(registered.bootstrap.channels.len(), 1);
    }

    fn fixture_user(id: i64, full_name: &str) -> UserSummary {
        UserSummary {
            id,
            full_name: full_name.to_owned(),
            email: Some(format!("{id}@example.com")),
            is_active: true,
            is_bot: false,
        }
    }

    fn assert_register_request(request: &str) {
        assert!(request.starts_with("POST /api/v1/register HTTP/1.1"));
        assert!(request.contains("event_types="));
        assert!(request.contains("fetch_event_types="));
        assert!(request.contains("apply_markdown=true"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: basic ")
        );
    }

    fn assert_poll_request(request: &str) {
        assert!(request.starts_with("GET /api/v1/events?"));
        assert!(request.contains("queue_id=queue-fixture"));
        assert!(request.contains("last_event_id=40"));
        assert!(request.contains("dont_block=false"));
    }

    fn register_body(queue_id: &str, last_event_id: i64, channel_name: &str) -> String {
        format!(
            r##"{{
                "result":"success",
                "queue_id":"{queue_id}",
                "last_event_id":{last_event_id},
                "event_queue_longpoll_timeout_seconds":5,
                "zulip_feature_level":481,
                "realm_users":[],
                "subscriptions":[{{
                    "stream_id":5,
                    "name":"{channel_name}",
                    "color":"#76ce90",
                    "is_muted":false
                }}]
            }}"##
        )
    }

    fn fixture_channel(id: i64, name: &str) -> ChannelSummary {
        ChannelSummary {
            id,
            name: name.to_owned(),
            color: "#76ce90".to_owned(),
            is_muted: false,
        }
    }

    fn fixture_message(id: i64, content_html: &str) -> MessageSummary {
        MessageSummary {
            id,
            sender_id: 7,
            sender_full_name: "Maya".to_owned(),
            timestamp: 1_770_000_000,
            content_html: content_html.to_owned(),
            stream_id: Some(5),
            topic: Some("Rust core".to_owned()),
            recipient_ids: Vec::new(),
            flags: Vec::new(),
            reactions: Vec::new(),
        }
    }

    fn spawn_mock(responses: Vec<(StatusCode, String)>) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback mock server");
        let address = listener.local_addr().expect("mock server address");
        let (sender, receiver) = mpsc::channel();

        thread::spawn(move || {
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let _ = sender.send(request);

                let reason = status.canonical_reason().unwrap_or("Unknown");
                let response = format!(
                    "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    status.as_u16(),
                    reason,
                    body.len(),
                    body
                );
                stream
                    .write_all(response.as_bytes())
                    .expect("write response");
            }
        });

        (format!("http://{address}/"), receiver)
    }

    fn read_request(stream: &mut std::net::TcpStream) -> String {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        let mut expected_length = None;

        loop {
            let count = stream.read(&mut buffer).expect("read request");
            if count == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..count]);

            if expected_length.is_none()
                && let Some(header_end) =
                    request.windows(4).position(|window| window == b"\r\n\r\n")
            {
                let header_length = header_end + 4;
                let headers = String::from_utf8_lossy(&request[..header_length]);
                let content_length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                expected_length = Some(header_length + content_length);
            }

            if expected_length.is_some_and(|length| request.len() >= length) {
                break;
            }
        }

        String::from_utf8_lossy(&request).into_owned()
    }
}
