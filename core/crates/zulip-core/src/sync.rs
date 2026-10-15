//! Initial Zulip state registration, event long-polling, and domain reduction.

use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};

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
/// How much longer than the server's long-poll timeout the client waits.
const LONGPOLL_GRACE: Duration = Duration::from_secs(20);
const MAX_LONGPOLL_TIMEOUT_SECONDS: u64 = 600;
/// How many of the newest live messages the snapshot keeps. Every snapshot is
/// copied to the app and processed in full, so an unbounded list made each new
/// event slower the longer the app ran. Conversations are fetched from the
/// server, not read from here; older messages only drop out of the snapshot.
const MAX_SNAPSHOT_MESSAGES: usize = 1_000;
/// How many read message identifiers the reducer remembers.
const MAX_RECENTLY_READ: usize = 4_096;
const EVENT_TYPES_JSON: &str = concat!(
    r#"["message","subscription","realm_user","update_message","#,
    r#""delete_message","reaction","update_message_flags","typing","user_settings","#,
    r#""user_topic","user_status","heartbeat","restart"]"#
);
/// Initial state additionally includes organization settings (for the icon);
/// realm change events are not consumed, so they are not subscribed to.
const FETCH_EVENT_TYPES_JSON: &str = concat!(
    r#"["message","recent_private_conversations","subscription","realm_user","realm","update_message","#,
    r#""delete_message","reaction","update_message_flags","user_settings","user_topic","#,
    r#""user_status","heartbeat","restart"]"#
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
    /// Avatar image location, absolute or relative to the server, when known.
    #[serde(default)]
    pub avatar_url: Option<String>,
}

/// What a user says about themselves: Zulip's "user status", a short text and
/// an emoji, either of which may be empty.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct UserStatus {
    /// Zulip user identifier.
    pub user_id: i64,
    /// Free text such as "In a meeting"; empty when none.
    #[serde(default)]
    pub status_text: String,
    /// Emoji name; empty when the status has no emoji.
    #[serde(default)]
    pub emoji_name: String,
    /// Zulip's emoji code (dash-joined code points for Unicode emoji).
    #[serde(default)]
    pub emoji_code: String,
    /// `unicode_emoji`, `realm_emoji` or `zulip_extra_emoji`.
    #[serde(default)]
    pub reaction_type: String,
}

impl UserStatus {
    /// Whether the status says nothing, which is how Zulip clears one.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.status_text.is_empty() && self.emoji_name.is_empty()
    }
}

/// A change to one user's status; absent fields are unchanged.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct UserStatusUpdate {
    /// User whose status changed.
    pub user_id: i64,
    /// Replacement text, when present (empty clears it).
    pub status_text: Option<String>,
    /// Replacement emoji name, code and type, when present (an empty name clears it).
    pub emoji: Option<(String, String, String)>,
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
    /// The channel's own desktop-notification choice; `None` follows the
    /// account-wide default.
    #[serde(default)]
    pub desktop_notifications: Option<bool>,
}

/// How the account treats one topic, overriding its channel's setting.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum TopicVisibility {
    /// The topic is muted.
    Muted,
    /// The topic is unmuted inside a muted channel.
    Unmuted,
    /// The topic is followed.
    Followed,
}

/// A personal visibility choice for one topic.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TopicPolicy {
    /// Channel identifier.
    pub stream_id: i64,
    /// Topic name as the server reports it.
    pub topic: String,
    /// The account's choice.
    pub visibility: TopicVisibility,
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
    /// Unix timestamp in seconds of the last edit, absent when never edited.
    #[serde(default)]
    pub last_edit_timestamp: Option<i64>,
}

/// One normalized reaction attached to a message.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ReactionSummary {
    /// Stable emoji name used by Zulip's reaction write API.
    pub emoji_name: String,
    /// Zulip's code for the emoji: dash-joined hexadecimal code points for a
    /// Unicode emoji, an identifier for custom emoji. Empty for old cache rows.
    #[serde(default)]
    pub emoji_code: String,
    /// `unicode_emoji`, `realm_emoji` or `zulip_extra_emoji`; empty for old cache rows.
    #[serde(default)]
    pub reaction_type: String,
    /// Zulip identifier of the reacting user.
    pub user_id: i64,
}

/// A one-to-one or group direct-message conversation and its newest message.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecentDirectConversation {
    /// Other participants, as reported by the server.
    pub user_ids: Vec<i64>,
    /// Identifier of the newest message in the conversation.
    pub max_message_id: i64,
}

/// One unread message and the conversation it belongs to.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnreadMessage {
    /// Zulip message identifier.
    pub id: i64,
    /// Channel identifier for channel messages.
    pub stream_id: Option<i64>,
    /// Topic name for channel messages.
    pub topic: Option<String>,
    /// Direct-message participants as the source reported them, sorted. The
    /// current user may or may not be listed; consumers normalize.
    pub user_ids: Vec<i64>,
    /// Whether the message mentions the current user (directly or by wildcard).
    pub mentioned: bool,
}

/// The unread messages of one conversation, counted.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct UnreadBucket {
    /// Channel identifier for channel conversations.
    pub stream_id: Option<i64>,
    /// Topic name for channel conversations.
    pub topic: Option<String>,
    /// Direct-message participants as reported, sorted.
    pub user_ids: Vec<i64>,
    /// Number of unread messages.
    pub count: u32,
    /// How many of them mention the current user.
    pub mention_count: u32,
}

/// Where somebody is typing a message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TypingScope {
    /// A direct-message conversation: every participant the event names.
    Direct {
        /// Recipients as reported by the server (the sender may be included).
        user_ids: Vec<i64>,
    },
    /// A topic in a channel.
    Topic {
        /// Channel identifier.
        stream_id: i64,
        /// Topic name; empty for the channel's general chat.
        topic: String,
    },
}

/// One person starting or stopping typing.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TypingNotice {
    /// `true` for `start`, `false` for `stop`.
    pub started: bool,
    /// Who is typing.
    pub sender_id: i64,
    /// Where they are typing.
    pub scope: TypingScope,
}

/// Whether the account lets others see that it is typing.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TypingPreferences {
    /// `send_private_message_typing_notifications`.
    pub direct: bool,
    /// `send_stream_typing_notifications`.
    pub channel: bool,
}

impl Default for TypingPreferences {
    /// Servers that predate the settings send direct-message typing and know
    /// nothing of channel typing.
    fn default() -> Self {
        Self {
            direct: true,
            channel: false,
        }
    }
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
    /// Organization icon location, absolute or relative to the server.
    pub realm_icon_url: Option<String>,
    /// Direct-message conversations ordered by the server, newest first.
    pub recent_direct_conversations: Vec<RecentDirectConversation>,
    /// Messages the account has not read yet, from the server's unread index.
    pub unread: Vec<UnreadMessage>,
    /// Typing-notification privacy settings of the account.
    pub typing_preferences: TypingPreferences,
    /// Muted, unmuted and followed topics.
    pub topic_policies: Vec<TopicPolicy>,
    /// `enable_stream_desktop_notifications`: whether channels without their own
    /// choice notify for every message.
    pub channel_notifications_default: bool,
    /// Every user's status that says something.
    pub user_statuses: Vec<UserStatus>,
    /// Whether the account hides its presence (`presence_enabled` turned off).
    pub invisible: bool,
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
    /// Every message a topic or channel move applies to (includes `message_id`).
    pub message_ids: Vec<i64>,
    /// Replacement rendered content, when changed.
    pub content_html: Option<String>,
    /// Unix timestamp in seconds of the edit, when the event reports one.
    pub edit_timestamp: Option<i64>,
    /// Replacement topic, when changed.
    pub topic: Option<String>,
    /// Replacement channel identifier, when moved.
    pub stream_id: Option<i64>,
    /// Channel the message was in before this update, when the event names it.
    pub origin_stream_id: Option<i64>,
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
    /// Replacement desktop-notification choice, when the update carries one
    /// (the inner `None` returns to the account-wide default).
    pub desktop_notifications: Option<Option<bool>>,
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
    /// Replacement avatar location, when present.
    pub avatar_url: Option<String>,
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
        /// Channel the messages were in, when the event names it.
        stream_id: Option<i64>,
    },
    /// Somebody started or stopped typing.
    Typing {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// The notice itself.
        notice: TypingNotice,
    },
    /// The account changed whether it sends typing notifications.
    TypingPreferenceChanged {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// `true` for channel typing, `false` for direct-message typing.
        channel: bool,
        /// The new setting.
        enabled: bool,
    },
    /// The account's default for channel desktop notifications changed.
    ChannelNotificationDefaultChanged {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// The new setting.
        enabled: bool,
    },
    /// Someone set, changed or cleared their status.
    UserStatusChanged {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// The fields that changed.
        update: UserStatusUpdate,
    },
    /// The account turned invisible mode on or off.
    InvisibleChanged {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Whether the account now hides its presence.
        invisible: bool,
    },
    /// The account muted, unmuted, followed or reset one topic.
    TopicPolicyChanged {
        /// Monotonic queue-local event identifier.
        event_id: i64,
        /// Channel identifier.
        stream_id: i64,
        /// Topic name.
        topic: String,
        /// The new choice; `None` returns the topic to its channel's setting.
        visibility: Option<TopicVisibility>,
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
        /// What the server says about messages marked unread, so they can be
        /// counted even when this client never loaded them.
        details: Vec<UnreadMessage>,
        /// The server's "mark everything as read": `message_ids` is then empty.
        all: bool,
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
            | Self::Typing { event_id, .. }
            | Self::TypingPreferenceChanged { event_id, .. }
            | Self::ChannelNotificationDefaultChanged { event_id, .. }
            | Self::UserStatusChanged { event_id, .. }
            | Self::InvisibleChanged { event_id, .. }
            | Self::TopicPolicyChanged { event_id, .. }
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
    /// Organization icon location, absolute or relative to the server.
    pub realm_icon_url: Option<String>,
    /// Direct-message conversations known at registration, newest first.
    pub recent_direct_conversations: Vec<RecentDirectConversation>,
    /// Unread messages grouped by conversation, ordered by conversation.
    pub unread: Vec<UnreadBucket>,
    /// Muted, unmuted and followed topics.
    pub topic_policies: Vec<TopicPolicy>,
    /// Whether channels without their own choice notify for every message.
    pub channel_notifications_default: bool,
    /// Statuses that say something, sorted by user.
    pub user_statuses: Vec<UserStatus>,
    /// Whether the account hides its presence.
    pub invisible: bool,
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
    /// Channels whose topic lists a rename, move or deletion may have changed.
    pub topic_changed_streams: Vec<i64>,
    /// People who started or stopped typing, oldest first.
    pub typing: Vec<TypingNotice>,
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
            "stream_typing_notifications": true,
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
                ("fetch_event_types", FETCH_EVENT_TYPES_JSON),
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
            // The server answers an idle poll with a heartbeat at its own timeout;
            // giving up at exactly that moment would race the heartbeat and turn
            // a quiet queue into a retry with back-off (and late notifications).
            .timeout(queue.longpoll_timeout + LONGPOLL_GRACE)
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

    /// Returns whether the account shares that it is typing.
    #[must_use]
    pub const fn typing_preferences(&self) -> TypingPreferences {
        self.reducer.typing_preferences()
    }

    /// Returns the newest message identifier this session knows of, read or
    /// unread, or 0 when it knows none.
    #[must_use]
    pub fn newest_message_id(&self) -> i64 {
        self.reducer.newest_message_id()
    }

    /// Adds messages fetched outside the event queue, such as those that arrived
    /// while a lost queue was being replaced. Returns the new snapshot when any
    /// of them was not already known.
    pub fn add_fetched_messages(&mut self, messages: Vec<MessageSummary>) -> Option<SyncSnapshot> {
        self.reducer.add_fetched_messages(messages)
    }

    /// Applies a read this client made itself, once the server accepted it.
    /// Returns the new snapshot when it changed any unread count.
    pub fn mark_read_locally(&mut self, message_ids: &[i64]) -> Option<SyncSnapshot> {
        self.reducer.mark_read_locally(message_ids)
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
    realm_icon_url: Option<String>,
    recent_direct_conversations: Vec<RecentDirectConversation>,
    unread: BTreeMap<i64, UnreadMessage>,
    /// Messages known to have been read, newest last and bounded, so a copy
    /// fetched before the read (and applied after it) cannot make one unread again.
    recently_read: BTreeSet<i64>,
    topic_changed_streams: BTreeSet<i64>,
    typing_preferences: TypingPreferences,
    typing_notices: Vec<TypingNotice>,
    topic_policies: BTreeMap<(i64, String), TopicPolicy>,
    channel_notifications_default: bool,
    user_statuses: BTreeMap<i64, UserStatus>,
    invisible: bool,
}

/// Zulip compares topic names case-insensitively.
fn topic_policy_key(stream_id: i64, topic: &str) -> (i64, String) {
    (stream_id, topic.to_lowercase())
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
            realm_icon_url: bootstrap.realm_icon_url,
            recent_direct_conversations: bootstrap.recent_direct_conversations,
            unread: bootstrap
                .unread
                .into_iter()
                .map(|message| (message.id, message))
                .collect(),
            recently_read: BTreeSet::new(),
            topic_changed_streams: BTreeSet::new(),
            typing_preferences: bootstrap.typing_preferences,
            typing_notices: Vec::new(),
            topic_policies: bootstrap
                .topic_policies
                .into_iter()
                .map(|policy| (topic_policy_key(policy.stream_id, &policy.topic), policy))
                .collect(),
            channel_notifications_default: bootstrap.channel_notifications_default,
            user_statuses: bootstrap
                .user_statuses
                .into_iter()
                .filter(|status| !status.is_empty())
                .map(|status| (status.user_id, status))
                .collect(),
            invisible: bootstrap.invisible,
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
            realm_icon_url: self.realm_icon_url.clone(),
            recent_direct_conversations: self.recent_direct_conversations.clone(),
            unread: self.unread_buckets(),
            topic_policies: self.topic_policies.values().cloned().collect(),
            channel_notifications_default: self.channel_notifications_default,
            user_statuses: self.user_statuses.values().cloned().collect(),
            invisible: self.invisible,
        }
    }

    /// Applies a status change; a status left saying nothing is dropped.
    fn apply_user_status(&mut self, update: UserStatusUpdate) -> bool {
        let previous = self.user_statuses.get(&update.user_id).cloned();
        let mut status = previous.clone().unwrap_or_else(|| UserStatus {
            user_id: update.user_id,
            ..UserStatus::default()
        });
        if let Some(text) = update.status_text {
            status.status_text = text;
        }
        if let Some((name, code, reaction_type)) = update.emoji {
            if name.is_empty() {
                status.emoji_name = String::new();
                status.emoji_code = String::new();
                status.reaction_type = String::new();
            } else {
                status.emoji_name = name;
                status.emoji_code = code;
                status.reaction_type = reaction_type;
            }
        }
        if status.is_empty() {
            return self.user_statuses.remove(&update.user_id).is_some();
        }
        let changed = previous.as_ref() != Some(&status);
        self.user_statuses.insert(update.user_id, status);
        changed
    }

    /// Counts the unread messages per conversation.
    fn unread_buckets(&self) -> Vec<UnreadBucket> {
        type Key = (Option<i64>, Option<String>, Vec<i64>);
        let mut buckets: BTreeMap<Key, (u32, u32)> = BTreeMap::new();
        for message in self.unread.values() {
            let key = (
                message.stream_id,
                message.topic.clone(),
                message.user_ids.clone(),
            );
            let entry = buckets.entry(key).or_default();
            entry.0 = entry.0.saturating_add(1);
            if message.mentioned {
                entry.1 = entry.1.saturating_add(1);
            }
        }
        buckets
            .into_iter()
            .map(
                |((stream_id, topic, user_ids), (count, mention_count))| UnreadBucket {
                    stream_id,
                    topic,
                    user_ids,
                    count,
                    mention_count,
                },
            )
            .collect()
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

    /// Returns whether the account shares that it is typing.
    #[must_use]
    pub const fn typing_preferences(&self) -> TypingPreferences {
        self.typing_preferences
    }

    /// Drops the oldest live messages beyond [`MAX_SNAPSHOT_MESSAGES`].
    fn trim_messages(&mut self) {
        while self.messages.len() > MAX_SNAPSHOT_MESSAGES {
            self.messages.pop_first();
        }
    }

    /// Returns the newest known message identifier, read or unread, or 0.
    #[must_use]
    pub fn newest_message_id(&self) -> i64 {
        let message = self.messages.last_key_value().map_or(0, |(id, _)| *id);
        let unread = self.unread.last_key_value().map_or(0, |(id, _)| *id);
        message.max(unread)
    }

    /// Stores messages that did not come through the event queue. Messages
    /// already known are left as they are, so a late fetch cannot undo an edit
    /// or flag change the queue delivered first.
    pub fn add_fetched_messages(&mut self, messages: Vec<MessageSummary>) -> Option<SyncSnapshot> {
        let mut changed = false;
        for mut message in messages {
            if self.messages.contains_key(&message.id) {
                continue;
            }
            // The fetch can answer after the user read the message; the read
            // flag event only ever clears the index, so it must win here.
            if self.recently_read.contains(&message.id)
                && !message.flags.iter().any(|flag| flag == "read")
            {
                message.flags.push("read".to_owned());
            }
            self.track_unread(&message);
            self.messages.insert(message.id, message);
            changed = true;
        }
        self.trim_messages();
        changed.then(|| {
            self.revision = self.revision.saturating_add(1);
            self.snapshot()
        })
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

        // A rename or deletion changes the channel's topic list even when none of
        // the affected messages is stored here, and the snapshot carries that list.
        domain_changed |= !self.topic_changed_streams.is_empty();
        self.trim_messages();
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
            topic_changed_streams: std::mem::take(&mut self.topic_changed_streams)
                .into_iter()
                .collect(),
            typing: std::mem::take(&mut self.typing_notices),
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

    fn mark_everything_read(&mut self) -> bool {
        let mut changed = !self.unread.is_empty();
        self.unread.clear();
        for message in self.messages.values_mut() {
            if !message.flags.iter().any(|flag| flag == "read") {
                message.flags.push("read".to_owned());
                changed = true;
            }
        }
        changed
    }

    fn delete_messages(&mut self, message_ids: &[i64], stream_id: Option<i64>) -> bool {
        let mut changed = false;
        self.topic_changed_streams.extend(stream_id);
        for message_id in message_ids {
            if let Some(stream_id) = self.messages.get(message_id).and_then(|m| m.stream_id) {
                self.topic_changed_streams.insert(stream_id);
            }
            changed |= self.messages.remove(message_id).is_some();
            changed |= self.unread.remove(message_id).is_some();
        }
        changed
    }

    fn remove_channels(&mut self, channel_ids: &[i64]) -> bool {
        let unread_before = self.unread.len();
        self.unread.retain(|_, message| {
            message
                .stream_id
                .is_none_or(|stream_id| !channel_ids.contains(&stream_id))
        });
        let mut changed = self.unread.len() != unread_before;
        for channel_id in channel_ids {
            changed |= self.channels.remove(channel_id).is_some();
        }
        changed
    }

    fn note_read(&mut self, message_ids: &[i64]) {
        self.recently_read.extend(message_ids.iter().copied());
        while self.recently_read.len() > MAX_RECENTLY_READ {
            self.recently_read.pop_first();
        }
    }

    /// Applies a read this client made itself once the server accepted it.
    /// The server announces a read through the event queue, but only for
    /// messages that were unread there: a message this side still counts as
    /// unread (a lost or reordered event) would otherwise stay unread for good,
    /// because reading it again announces nothing.
    pub fn mark_read_locally(&mut self, message_ids: &[i64]) -> Option<SyncSnapshot> {
        let mut changed = self.apply_flag_change(true, "read", message_ids);
        changed |= self.apply_read_change(true, message_ids, &[]);
        changed.then(|| {
            self.revision = self.revision.saturating_add(1);
            self.snapshot()
        })
    }

    /// Records or clears the unread entry for a freshly delivered message.
    fn track_unread(&mut self, message: &MessageSummary) -> bool {
        if message.flags.iter().any(|flag| flag == "read") {
            return self.unread.remove(&message.id).is_some();
        }
        let entry = unread_message(message);
        self.unread.insert(message.id, entry.clone()) != Some(entry)
    }

    /// Applies a `read` flag change to the unread index. Marking unread uses the
    /// loaded message when there is one and the server's details otherwise.
    fn apply_read_change(
        &mut self,
        added: bool,
        message_ids: &[i64],
        details: &[UnreadMessage],
    ) -> bool {
        let mut changed = false;
        if added {
            self.note_read(message_ids);
            for message_id in message_ids {
                changed |= self.unread.remove(message_id).is_some();
            }
            return changed;
        }
        for message_id in message_ids {
            self.recently_read.remove(message_id);
            let entry = self.messages.get(message_id).map_or_else(
                || {
                    details
                        .iter()
                        .find(|detail| detail.id == *message_id)
                        .cloned()
                },
                |message| Some(unread_message(message)),
            );
            if let Some(entry) = entry {
                changed |= self.unread.insert(*message_id, entry.clone()) != Some(entry);
            }
        }
        changed
    }

    /// Applies an edit, topic rename or channel move to messages and the unread
    /// index. A move can span many messages; a content edit names exactly one.
    fn apply_message_update(&mut self, update: &MessageUpdate) -> bool {
        let mut changed = false;
        if update.topic.is_some()
            || (update.stream_id.is_some() && update.stream_id != update.origin_stream_id)
        {
            self.topic_changed_streams
                .extend(update.origin_stream_id.into_iter().chain(update.stream_id));
        }
        if let Some(content_html) = &update.content_html
            && let Some(message) = self.messages.get_mut(&update.message_id)
            && message.content_html != *content_html
        {
            message.content_html.clone_from(content_html);
            // Only a content change counts as an edit; a topic or channel move
            // arrives without new content.
            if let Some(edited_at) = update.edit_timestamp {
                message.last_edit_timestamp = Some(edited_at);
            }
            changed = true;
        }
        if update.topic.is_none() && update.stream_id.is_none() {
            return changed;
        }
        let mut targets = update.message_ids.clone();
        if !targets.contains(&update.message_id) {
            targets.push(update.message_id);
        }
        for message_id in targets {
            if let Some(message) = self.messages.get_mut(&message_id) {
                if let Some(topic) = &update.topic
                    && message.topic.as_ref() != Some(topic)
                {
                    message.topic = Some(topic.clone());
                    changed = true;
                }
                if let Some(stream_id) = update.stream_id
                    && message.stream_id != Some(stream_id)
                {
                    message.stream_id = Some(stream_id);
                    changed = true;
                }
            }
            if let Some(entry) = self.unread.get_mut(&message_id) {
                if let Some(topic) = &update.topic
                    && entry.topic.as_ref() != Some(topic)
                {
                    entry.topic = Some(topic.clone());
                    changed = true;
                }
                if let Some(stream_id) = update.stream_id
                    && entry.stream_id != Some(stream_id)
                {
                    entry.stream_id = Some(stream_id);
                    changed = true;
                }
            }
        }
        changed
    }

    /// Typing is transient: reported with the batch, never part of a snapshot.
    fn record_typing(&mut self, notice: TypingNotice) -> bool {
        self.typing_notices.push(notice);
        false
    }

    fn set_topic_policy(
        &mut self,
        stream_id: i64,
        topic: String,
        visibility: Option<TopicVisibility>,
    ) -> bool {
        let key = topic_policy_key(stream_id, &topic);
        match visibility {
            Some(visibility) => {
                let policy = TopicPolicy {
                    stream_id,
                    topic,
                    visibility,
                };
                self.topic_policies.insert(key, policy.clone()) != Some(policy)
            }
            None => self.topic_policies.remove(&key).is_some(),
        }
    }

    fn set_typing_preference(&mut self, channel: bool, enabled: bool) -> bool {
        if channel {
            self.typing_preferences.channel = enabled;
        } else {
            self.typing_preferences.direct = enabled;
        }
        false
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
        // A reaction is identified by its emoji name and user; cache rows written
        // before emoji codes were stored carry no code to compare.
        let same = |existing: &ReactionSummary| {
            existing.emoji_name == reaction.emoji_name && existing.user_id == reaction.user_id
        };
        let present = message.reactions.iter().any(same);
        if added && !present {
            message.reactions.push(reaction);
            true
        } else if !added && present {
            message.reactions.retain(|existing| !same(existing));
            true
        } else {
            false
        }
    }

    #[allow(clippy::too_many_lines)]
    fn apply_event(&mut self, event: SyncEvent, heartbeats: &mut usize) -> bool {
        match event {
            SyncEvent::Heartbeat { .. } => {
                *heartbeats += 1;
                false
            }
            SyncEvent::ServerRestart { .. } | SyncEvent::Unknown { .. } => false,
            SyncEvent::MessageAdded { message, .. } => {
                let unread_changed = self.track_unread(&message);
                let previous = self.messages.insert(message.id, message.clone());
                unread_changed || previous.as_ref() != Some(&message)
            }
            SyncEvent::MessageUpdated { update, .. } => self.apply_message_update(&update),
            SyncEvent::Typing { notice, .. } => self.record_typing(notice),
            SyncEvent::TypingPreferenceChanged {
                channel, enabled, ..
            } => self.set_typing_preference(channel, enabled),
            SyncEvent::ChannelNotificationDefaultChanged { enabled, .. } => {
                let changed = self.channel_notifications_default != enabled;
                self.channel_notifications_default = enabled;
                changed
            }
            SyncEvent::UserStatusChanged { update, .. } => self.apply_user_status(update),
            SyncEvent::InvisibleChanged { invisible, .. } => {
                let changed = self.invisible != invisible;
                self.invisible = invisible;
                changed
            }
            SyncEvent::TopicPolicyChanged {
                stream_id,
                topic,
                visibility,
                ..
            } => self.set_topic_policy(stream_id, topic, visibility),
            SyncEvent::MessagesDeleted {
                message_ids,
                stream_id,
                ..
            } => self.delete_messages(&message_ids, stream_id),
            SyncEvent::MessageFlagsUpdated {
                added,
                flag,
                message_ids,
                details,
                all,
                ..
            } => {
                let mut changed = self.apply_flag_change(added, &flag, &message_ids);
                if flag == "read" {
                    changed |= self.apply_read_change(added, &message_ids, &details);
                    if added && all {
                        changed |= self.mark_everything_read();
                    }
                }
                changed
            }
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
                if let Some(choice) = update.desktop_notifications {
                    channel.desktop_notifications = choice;
                }
                *channel != previous
            }
            SyncEvent::ChannelsRemoved { channel_ids, .. } => self.remove_channels(&channel_ids),
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
                if let Some(avatar_url) = update.avatar_url {
                    user.avatar_url = Some(avatar_url);
                }
                *user != previous
            }
            SyncEvent::UserRemoved { user_id, .. } => self.users.remove(&user_id).is_some(),
        }
    }
}

/// The unread-index entry that describes `message`.
fn unread_message(message: &MessageSummary) -> UnreadMessage {
    let is_channel = message.stream_id.is_some();
    let mut user_ids = if is_channel {
        Vec::new()
    } else {
        message.recipient_ids.clone()
    };
    user_ids.sort_unstable();
    user_ids.dedup();
    UnreadMessage {
        id: message.id,
        stream_id: message.stream_id,
        topic: if is_channel {
            message.topic.clone()
        } else {
            None
        },
        user_ids,
        mentioned: message
            .flags
            .iter()
            .any(|flag| flag == "mentioned" || flag == "wildcard_mentioned"),
    }
}

/// Reads the server's `unread_msgs` index. Unrecognized shapes are skipped so
/// they can never make registration fail.
fn parse_unread_messages(value: Option<&Value>) -> Vec<UnreadMessage> {
    let Some(index) = value.and_then(Value::as_object) else {
        return Vec::new();
    };
    let mentioned: Vec<i64> = index
        .get("mentions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_i64)
        .collect();
    let mut unread = BTreeMap::new();
    let mut add = |ids: &Value, stream_id: Option<i64>, topic: Option<String>, user_ids: &[i64]| {
        let mut user_ids = user_ids.to_vec();
        user_ids.sort_unstable();
        user_ids.dedup();
        for id in ids
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_i64)
        {
            unread.insert(
                id,
                UnreadMessage {
                    id,
                    stream_id,
                    topic: topic.clone(),
                    user_ids: user_ids.clone(),
                    mentioned: mentioned.contains(&id),
                },
            );
        }
    };
    for entry in index
        .get("streams")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(stream_id) = entry.get("stream_id").and_then(Value::as_i64) else {
            continue;
        };
        let topic = entry
            .get("topic")
            .or_else(|| entry.get("subject"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        add(
            entry.get("unread_message_ids").unwrap_or(&Value::Null),
            Some(stream_id),
            Some(topic),
            &[],
        );
    }
    for entry in index
        .get("pms")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(other) = entry
            .get("other_user_id")
            .or_else(|| entry.get("sender_id"))
            .and_then(Value::as_i64)
        else {
            continue;
        };
        add(
            entry.get("unread_message_ids").unwrap_or(&Value::Null),
            None,
            None,
            &[other],
        );
    }
    for entry in index
        .get("huddles")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let user_ids: Vec<i64> = entry
            .get("user_ids_string")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .split(',')
            .filter_map(|id| id.trim().parse().ok())
            .collect();
        if user_ids.is_empty() {
            continue;
        }
        add(
            entry.get("unread_message_ids").unwrap_or(&Value::Null),
            None,
            None,
            &user_ids,
        );
    }
    unread.into_values().collect()
}

/// Reads the `message_details` that accompany a "marked unread" flag event.
fn parse_unread_details(payload: &Map<String, Value>) -> Vec<UnreadMessage> {
    let Some(details) = payload.get("message_details").and_then(Value::as_object) else {
        return Vec::new();
    };
    details
        .iter()
        .filter_map(|(id, detail)| {
            let id = id.parse::<i64>().ok()?;
            let mentioned = ["mentioned", "wildcard_mentioned"]
                .iter()
                .any(|name| detail.get(name).and_then(Value::as_bool) == Some(true));
            match detail.get("type").and_then(Value::as_str)? {
                "stream" | "channel" => Some(UnreadMessage {
                    id,
                    stream_id: Some(detail.get("stream_id")?.as_i64()?),
                    topic: Some(
                        detail
                            .get("topic")
                            .or_else(|| detail.get("subject"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                    ),
                    user_ids: Vec::new(),
                    mentioned,
                }),
                "private" => {
                    let mut user_ids: Vec<i64> = detail
                        .get("user_ids")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_i64)
                        .collect();
                    user_ids.sort_unstable();
                    user_ids.dedup();
                    Some(UnreadMessage {
                        id,
                        stream_id: None,
                        topic: None,
                        user_ids,
                        mentioned,
                    })
                }
                _ => None,
            }
        })
        .collect()
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
    #[serde(default)]
    realm_icon_url: Option<String>,
    #[serde(default)]
    recent_private_conversations: Vec<RecentConversationDocument>,
    #[serde(default)]
    unread_msgs: Option<Value>,
    #[serde(default)]
    user_settings: Option<Value>,
    #[serde(default)]
    user_topics: Vec<UserTopicDocument>,
    /// Statuses keyed by user identifier (as a string).
    #[serde(default)]
    user_status: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct UserTopicDocument {
    stream_id: i64,
    #[serde(default)]
    topic_name: String,
    #[serde(default)]
    visibility_policy: i64,
}

impl UserTopicDocument {
    fn normalize(self) -> Option<TopicPolicy> {
        Some(TopicPolicy {
            stream_id: self.stream_id,
            topic: self.topic_name,
            visibility: topic_visibility(self.visibility_policy)?,
        })
    }
}

/// Maps Zulip's `visibility_policy` (0 inherit, 1 muted, 2 unmuted, 3 followed).
fn topic_visibility(policy: i64) -> Option<TopicVisibility> {
    match policy {
        1 => Some(TopicVisibility::Muted),
        2 => Some(TopicVisibility::Unmuted),
        3 => Some(TopicVisibility::Followed),
        _ => None,
    }
}

#[derive(Debug, Deserialize)]
struct RecentConversationDocument {
    #[serde(default)]
    user_ids: Vec<i64>,
    #[serde(default)]
    max_message_id: i64,
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
        let unread = parse_unread_messages(self.unread_msgs.as_ref());
        let typing_preferences = parse_typing_preferences(self.user_settings.as_ref());
        let channel_notifications_default = self
            .user_settings
            .as_ref()
            .and_then(|settings| settings.get("enable_stream_desktop_notifications"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let topic_policies = self
            .user_topics
            .into_iter()
            .filter_map(UserTopicDocument::normalize)
            .collect();
        let user_statuses = parse_user_statuses(self.user_status.as_ref());
        // Servers before `presence_enabled` existed had no invisible mode.
        let invisible = self
            .user_settings
            .as_ref()
            .and_then(|settings| settings.get("presence_enabled"))
            .and_then(Value::as_bool)
            .is_some_and(|enabled| !enabled);

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
                realm_icon_url: self.realm_icon_url.filter(|value| !value.trim().is_empty()),
                recent_direct_conversations: {
                    let mut conversations = self
                        .recent_private_conversations
                        .into_iter()
                        .filter(|item| item.max_message_id > 0)
                        .map(|item| RecentDirectConversation {
                            user_ids: item.user_ids,
                            max_message_id: item.max_message_id,
                        })
                        .collect::<Vec<_>>();
                    conversations.sort_by_key(|item| std::cmp::Reverse(item.max_message_id));
                    conversations
                },
                unread,
                typing_preferences,
                topic_policies,
                channel_notifications_default,
                user_statuses,
                invisible,
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
                let mut message: MessageDocument = serde_json::from_value(message.clone())
                    .map_err(|_| SyncError::InvalidResponse("invalid message event"))?;
                // The personal flags (`read`, `mentioned`, ...) travel beside the
                // message in the event, not inside it.
                for flag in string_array_field(&self.payload, "flags") {
                    if !message.flags.contains(&flag) {
                        message.flags.push(flag);
                    }
                }
                Ok(SyncEvent::MessageAdded {
                    event_id: self.id,
                    message: message.normalize()?,
                })
            }
            "update_message" => Ok(SyncEvent::MessageUpdated {
                event_id: self.id,
                update: MessageUpdate {
                    message_id: integer_field(&self.payload, "message_id")?,
                    message_ids: integer_array_field(&self.payload, "message_ids"),
                    content_html: string_field(&self.payload, "rendered_content")
                        .or_else(|| string_field(&self.payload, "content")),
                    edit_timestamp: optional_integer_field(&self.payload, "edit_timestamp"),
                    topic: string_field(&self.payload, "topic")
                        .or_else(|| string_field(&self.payload, "subject")),
                    // `stream_id` names the channel before a move; `new_stream_id`
                    // is only present when the message moved.
                    stream_id: optional_integer_field(&self.payload, "new_stream_id")
                        .or_else(|| optional_integer_field(&self.payload, "stream_id")),
                    origin_stream_id: optional_integer_field(&self.payload, "stream_id"),
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
                    stream_id: optional_integer_field(&self.payload, "stream_id"),
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
                    details: parse_unread_details(&self.payload),
                    all: self.payload.get("all").and_then(Value::as_bool) == Some(true),
                })
            }
            "reaction" => {
                let reaction = ReactionDocument {
                    emoji_name: string_field(&self.payload, "emoji_name").unwrap_or_default(),
                    emoji_code: string_field(&self.payload, "emoji_code").unwrap_or_default(),
                    reaction_type: string_field(&self.payload, "reaction_type").unwrap_or_default(),
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
            "typing" => Ok(self.normalize_typing()),
            "user_settings" => Ok(self.normalize_user_setting()),
            "user_topic" => Ok(self.normalize_user_topic()),
            "user_status" => Ok(self.normalize_user_status()),
            _ => Ok(SyncEvent::Unknown {
                event_id: self.id,
                event_type: self.event_type,
            }),
        }
    }

    fn normalize_typing(self) -> SyncEvent {
        let unknown = |event_id: i64| SyncEvent::Unknown {
            event_id,
            event_type: "typing".to_owned(),
        };
        let Some(sender_id) = self
            .payload
            .get("sender")
            .and_then(|sender| sender.get("user_id"))
            .and_then(Value::as_i64)
        else {
            return unknown(self.id);
        };
        let scope = match string_field(&self.payload, "message_type").as_deref() {
            Some("stream") => {
                let (Some(stream_id), Some(topic)) = (
                    optional_integer_field(&self.payload, "stream_id"),
                    string_field(&self.payload, "topic")
                        .or_else(|| string_field(&self.payload, "subject")),
                ) else {
                    return unknown(self.id);
                };
                TypingScope::Topic { stream_id, topic }
            }
            Some("direct" | "private") => TypingScope::Direct {
                user_ids: self
                    .payload
                    .get("recipients")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|recipient| recipient.get("user_id").and_then(Value::as_i64))
                    .collect(),
            },
            _ => return unknown(self.id),
        };
        SyncEvent::Typing {
            event_id: self.id,
            notice: TypingNotice {
                started: string_field(&self.payload, "op").as_deref() != Some("stop"),
                sender_id,
                scope,
            },
        }
    }

    fn normalize_user_topic(self) -> SyncEvent {
        let unknown = |event_id: i64| SyncEvent::Unknown {
            event_id,
            event_type: "user_topic".to_owned(),
        };
        let (Some(stream_id), Some(topic), Some(policy)) = (
            optional_integer_field(&self.payload, "stream_id"),
            string_field(&self.payload, "topic_name"),
            optional_integer_field(&self.payload, "visibility_policy"),
        ) else {
            return unknown(self.id);
        };
        SyncEvent::TopicPolicyChanged {
            event_id: self.id,
            stream_id,
            topic,
            visibility: topic_visibility(policy),
        }
    }

    fn normalize_user_status(self) -> SyncEvent {
        let Some(user_id) = optional_integer_field(&self.payload, "user_id") else {
            return SyncEvent::Unknown {
                event_id: self.id,
                event_type: self.event_type,
            };
        };
        // Only the fields that changed are present.
        let emoji = string_field(&self.payload, "emoji_name").map(|name| {
            (
                name,
                string_field(&self.payload, "emoji_code").unwrap_or_default(),
                string_field(&self.payload, "reaction_type")
                    .unwrap_or_else(|| "unicode_emoji".to_owned()),
            )
        });
        SyncEvent::UserStatusChanged {
            event_id: self.id,
            update: UserStatusUpdate {
                user_id,
                status_text: string_field(&self.payload, "status_text"),
                emoji,
            },
        }
    }

    fn normalize_user_setting(self) -> SyncEvent {
        if string_field(&self.payload, "property").as_deref() == Some("presence_enabled") {
            return match self.payload.get("value").and_then(Value::as_bool) {
                Some(enabled) => SyncEvent::InvisibleChanged {
                    event_id: self.id,
                    invisible: !enabled,
                },
                None => SyncEvent::Unknown {
                    event_id: self.id,
                    event_type: self.event_type,
                },
            };
        }
        if string_field(&self.payload, "property").as_deref()
            == Some("enable_stream_desktop_notifications")
        {
            return match self.payload.get("value").and_then(Value::as_bool) {
                Some(enabled) => SyncEvent::ChannelNotificationDefaultChanged {
                    event_id: self.id,
                    enabled,
                },
                None => SyncEvent::Unknown {
                    event_id: self.id,
                    event_type: self.event_type,
                },
            };
        }
        let channel = match string_field(&self.payload, "property").as_deref() {
            Some("send_private_message_typing_notifications") => false,
            Some("send_stream_typing_notifications") => true,
            _ => {
                return SyncEvent::Unknown {
                    event_id: self.id,
                    event_type: self.event_type,
                };
            }
        };
        match self.payload.get("value").and_then(Value::as_bool) {
            Some(enabled) => SyncEvent::TypingPreferenceChanged {
                event_id: self.id,
                channel,
                enabled,
            },
            None => SyncEvent::Unknown {
                event_id: self.id,
                event_type: self.event_type,
            },
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
                "desktop_notifications" => ChannelUpdate {
                    channel_id,
                    desktop_notifications: Some(self.payload.get("value").and_then(Value::as_bool)),
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
                    avatar_url: person
                        .get("avatar_url")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
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
    #[serde(default)]
    avatar_url: Option<String>,
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
            avatar_url: self.avatar_url.filter(|value| !value.trim().is_empty()),
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
    #[serde(default)]
    desktop_notifications: Option<bool>,
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
            desktop_notifications: self.desktop_notifications,
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
    #[serde(default)]
    last_edit_timestamp: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct ReactionDocument {
    emoji_name: String,
    #[serde(default)]
    emoji_code: String,
    #[serde(default)]
    reaction_type: String,
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
            emoji_code: self.emoji_code,
            reaction_type: self.reaction_type,
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
            last_edit_timestamp: self.last_edit_timestamp,
        })
    }
}

fn default_true() -> bool {
    true
}

fn default_channel_color() -> String {
    "#888888".to_owned()
}

/// Reads a `register` response's `user_status` map. Entries that are not
/// objects or say nothing are skipped.
fn parse_user_statuses(value: Option<&Value>) -> Vec<UserStatus> {
    let Some(entries) = value.and_then(Value::as_object) else {
        return Vec::new();
    };
    let text = |entry: &Value, name: &str| {
        entry
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let mut statuses = entries
        .iter()
        .filter_map(|(key, entry)| {
            let user_id = key.parse().ok()?;
            entry.as_object()?;
            let emoji_name = text(entry, "emoji_name");
            let reaction_type = if emoji_name.is_empty() {
                String::new()
            } else {
                Some(text(entry, "reaction_type"))
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| "unicode_emoji".to_owned())
            };
            Some(UserStatus {
                user_id,
                status_text: text(entry, "status_text"),
                emoji_code: if emoji_name.is_empty() {
                    String::new()
                } else {
                    text(entry, "emoji_code")
                },
                emoji_name,
                reaction_type,
            })
        })
        .filter(|status| !status.is_empty())
        .collect::<Vec<_>>();
    statuses.sort_by_key(|status| status.user_id);
    statuses
}

/// Reads the typing privacy settings from a `register` response's `user_settings`.
fn parse_typing_preferences(settings: Option<&Value>) -> TypingPreferences {
    let defaults = TypingPreferences::default();
    let flag = |name: &str, fallback: bool| {
        settings
            .and_then(|value| value.get(name))
            .and_then(Value::as_bool)
            .unwrap_or(fallback)
    };
    TypingPreferences {
        direct: flag("send_private_message_typing_notifications", defaults.direct),
        channel: flag("send_stream_typing_notifications", defaults.channel),
    }
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

fn string_array_field(payload: &Map<String, Value>, name: &str) -> Vec<String> {
    payload
        .get(name)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|value| value.as_str().map(str::to_owned))
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
        SyncEvent, SyncReducer, SyncSession, TopicVisibility, TypingNotice, TypingPreferences,
        TypingScope, UnreadBucket, UserSummary, Value, parse_unread_messages,
    };
    use crate::auth::SecretString;

    const API_KEY: &str = "fixture-sync-key-do-not-log";

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
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
                        "is_bot":false,
                        "avatar_url":"/user_avatars/2/maya.png?x=1"
                    }],
                    "realm_icon_url":"https://cdn.example.com/icon.png",
                    "recent_private_conversations":[
                        {"max_message_id":120,"user_ids":[7]},
                        {"max_message_id":300,"user_ids":[7,9]},
                        {"max_message_id":0,"user_ids":[4]}
                    ],
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
        assert_eq!(
            registered.bootstrap.users[0].avatar_url.as_deref(),
            Some("/user_avatars/2/maya.png?x=1")
        );
        assert_eq!(
            registered.bootstrap.realm_icon_url.as_deref(),
            Some("https://cdn.example.com/icon.png")
        );
        assert_eq!(
            registered
                .bootstrap
                .recent_direct_conversations
                .iter()
                .map(|item| (item.max_message_id, item.user_ids.clone()))
                .collect::<Vec<_>>(),
            vec![(300, vec![7, 9]), (120, vec![7])]
        );
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
                realm_icon_url: None,
                recent_direct_conversations: Vec::new(),
                unread: Vec::new(),
                typing_preferences: TypingPreferences::default(),
                ..BootstrapState::default()
            },
        );
        let message = fixture_message(100, "<p>first</p>");

        let outcome = reducer.apply_batch(vec![
            SyncEvent::MessageUpdated {
                event_id: 15,
                update: MessageUpdate {
                    message_id: 100,
                    message_ids: Vec::new(),
                    content_html: Some("<p>edited</p>".to_owned()),
                    edit_timestamp: Some(1_770_000_100),
                    topic: None,
                    stream_id: None,
                    origin_stream_id: None,
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
        assert_eq!(
            snapshot.messages[0].last_edit_timestamp,
            Some(1_770_000_100)
        );
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
                realm_icon_url: None,
                recent_direct_conversations: Vec::new(),
                unread: Vec::new(),
                typing_preferences: TypingPreferences::default(),
                ..BootstrapState::default()
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
                stream_id: None,
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
                 "emoji_name":"thumbs_up","emoji_code":"1f44d",
                 "reaction_type":"unicode_emoji","user_id":2},
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
        assert_eq!(message.reactions[0].emoji_code, "1f44d");
        assert_eq!(message.reactions[0].reaction_type, "unicode_emoji");

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("events expected");
        };
        let message = &outcome.snapshot.expect("changed").messages[0];
        assert!(message.flags.is_empty());
        assert!(message.reactions.is_empty());
    }

    #[tokio::test]
    #[allow(clippy::too_many_lines)]
    async fn unread_index_events_and_message_flags_drive_unread_counts() {
        let register = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "last_event_id":10,
            "realm_users":[],
            "subscriptions":[{"stream_id":5,"name":"general"}],
            "unread_msgs":{
                "count":5,
                "pms":[{"other_user_id":7,"sender_id":7,"unread_message_ids":[21,22]}],
                "streams":[{"stream_id":5,"topic":"launch","unread_message_ids":[31,32]}],
                "huddles":[{"user_ids_string":"3,7,9","unread_message_ids":[41]}],
                "mentions":[32]
            }
        }"#
        .to_owned();
        let events = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "events":[
                {"id":11,"type":"message","flags":["mentioned"],"message":{
                    "id":50,"sender_id":2,"sender_full_name":"Theo","timestamp":1,
                    "content":"<p>hi</p>","type":"stream","stream_id":5,"subject":"launch",
                    "display_recipient":"general"}},
                {"id":12,"type":"message","flags":["read"],"message":{
                    "id":51,"sender_id":1,"sender_full_name":"Me","timestamp":2,
                    "content":"<p>mine</p>","type":"stream","stream_id":5,"subject":"launch",
                    "display_recipient":"general"}},
                {"id":13,"type":"message","flags":[],"message":{
                    "id":52,"sender_id":7,"sender_full_name":"Maya","timestamp":3,
                    "content":"<p>dm</p>","type":"private",
                    "display_recipient":[{"id":1},{"id":7}]}},
                {"id":14,"type":"update_message_flags","op":"add","flag":"read","messages":[31,21]}
            ]
        }"#
        .to_owned();
        let later = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "events":[
                {"id":15,"type":"update_message_flags","op":"remove","flag":"read","messages":[60],
                 "message_details":{"60":{"type":"stream","stream_id":5,"topic":"ops","mentioned":true}}},
                {"id":16,"type":"delete_message","message_id":22},
                {"id":17,"type":"update_message","message_id":50,"message_ids":[32,50],
                 "stream_id":5,"subject":"launch-2","orig_subject":"launch"}
            ]
        }"#
        .to_owned();
        let everything = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "events":[
                {"id":18,"type":"update_message_flags","op":"add","flag":"read",
                 "all":true,"messages":[]}
            ]
        }"#
        .to_owned();
        let (server, _) = spawn_mock(vec![
            (StatusCode::OK, register),
            (StatusCode::OK, events),
            (StatusCode::OK, later),
            (StatusCode::OK, everything),
        ]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, initial) = SyncSession::start(client, RecoveryPolicy::default(), 3)
            .await
            .expect("initial registration");

        let bucket =
            |stream_id, topic: &str, user_ids: &[i64], count, mention_count| UnreadBucket {
                stream_id,
                topic: (stream_id.is_some()).then(|| topic.to_owned()),
                user_ids: user_ids.to_vec(),
                count,
                mention_count,
            };
        assert_eq!(
            initial.unread,
            vec![
                bucket(None, "", &[3, 7, 9], 1, 0),
                bucket(None, "", &[7], 2, 0),
                bucket(Some(5), "launch", &[], 2, 1),
            ]
        );

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("events expected");
        };
        let snapshot = outcome.snapshot.expect("changed");
        let mentioned = snapshot
            .messages
            .iter()
            .find(|message| message.id == 50)
            .expect("message 50");
        assert_eq!(mentioned.flags, ["mentioned"], "event-level flags are kept");
        assert_eq!(
            snapshot.unread,
            vec![
                bucket(None, "", &[1, 7], 1, 0),
                bucket(None, "", &[3, 7, 9], 1, 0),
                bucket(None, "", &[7], 1, 0),
                bucket(Some(5), "launch", &[], 2, 2),
            ],
            "own read message is not counted; read flags clear the index"
        );

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("events expected");
        };
        assert_eq!(
            outcome.snapshot.expect("changed").unread,
            vec![
                bucket(None, "", &[1, 7], 1, 0),
                bucket(None, "", &[3, 7, 9], 1, 0),
                bucket(Some(5), "launch-2", &[], 2, 2),
                bucket(Some(5), "ops", &[], 1, 1),
            ],
            "details seed unloaded messages; deletes and topic moves reach the index"
        );

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("events expected");
        };
        let snapshot = outcome.snapshot.expect("changed");
        assert!(
            snapshot.unread.is_empty(),
            "mark all as read clears the index"
        );
        assert!(
            snapshot
                .messages
                .iter()
                .all(|message| message.flags.iter().any(|flag| flag == "read"))
        );
    }

    #[test]
    fn malformed_unread_index_never_blocks_registration() {
        let value = serde_json::json!({
            "streams": [{"topic": "no stream id"}, {"stream_id": 1, "unread_message_ids": "x"}],
            "pms": [{"unread_message_ids": [1]}],
            "huddles": [{"user_ids_string": "", "unread_message_ids": [2]}],
            "mentions": "nope"
        });
        assert!(parse_unread_messages(Some(&value)).is_empty());
        assert!(parse_unread_messages(Some(&Value::Null)).is_empty());
        assert!(parse_unread_messages(None).is_empty());
    }

    #[test]
    fn renames_and_deletions_report_the_channels_whose_topics_changed() {
        let mut reducer = SyncReducer::new(
            0,
            BootstrapState {
                messages: vec![fixture_message(1, "<p>a</p>")],
                ..BootstrapState::default()
            },
        );
        let quiet = reducer.apply_batch(vec![SyncEvent::MessageUpdated {
            event_id: 1,
            update: MessageUpdate {
                message_id: 1,
                content_html: Some("<p>edited</p>".to_owned()),
                stream_id: Some(5),
                origin_stream_id: Some(5),
                ..MessageUpdate::default()
            },
        }]);
        assert!(quiet.topic_changed_streams.is_empty());

        let renamed = reducer.apply_batch(vec![SyncEvent::MessageUpdated {
            event_id: 2,
            update: MessageUpdate {
                message_id: 1,
                topic: Some("renamed".to_owned()),
                stream_id: Some(5),
                origin_stream_id: Some(5),
                ..MessageUpdate::default()
            },
        }]);
        assert_eq!(renamed.topic_changed_streams, vec![5]);

        // The deleted message is known, so its channel is found even when the
        // event names none; an unknown message still reports the event's channel.
        let deleted = reducer.apply_batch(vec![
            SyncEvent::MessagesDeleted {
                event_id: 3,
                message_ids: vec![1],
                stream_id: None,
            },
            SyncEvent::MessagesDeleted {
                event_id: 4,
                message_ids: vec![99],
                stream_id: Some(8),
            },
        ]);
        assert_eq!(deleted.topic_changed_streams, vec![5, 8]);
        assert!(
            reducer
                .apply_batch(vec![SyncEvent::Heartbeat { event_id: 5 }])
                .topic_changed_streams
                .is_empty()
        );
    }

    #[test]
    fn the_snapshot_keeps_only_the_newest_messages() {
        let mut reducer = SyncReducer::new(0, BootstrapState::default());
        let events = (1..=i64::try_from(super::MAX_SNAPSHOT_MESSAGES).expect("small") + 5)
            .map(|id| SyncEvent::MessageAdded {
                event_id: id,
                message: fixture_message(id, "<p>m</p>"),
            })
            .collect();
        let snapshot = reducer
            .apply_batch(events)
            .snapshot
            .expect("messages added");
        assert_eq!(snapshot.messages.len(), super::MAX_SNAPSHOT_MESSAGES);
        assert_eq!(snapshot.messages[0].id, 6);
        assert_eq!(reducer.newest_message_id(), 1_005);
    }

    #[test]
    fn messages_fetched_after_a_queue_gap_join_the_snapshot_once() {
        let mut reducer = SyncReducer::new(
            0,
            BootstrapState {
                messages: vec![fixture_message(1, "<p>a</p>")],
                unread: vec![super::UnreadMessage {
                    id: 3,
                    stream_id: Some(5),
                    topic: Some("Rust core".to_owned()),
                    user_ids: Vec::new(),
                    mentioned: false,
                }],
                ..BootstrapState::default()
            },
        );
        assert_eq!(reducer.newest_message_id(), 3);

        let snapshot = reducer
            .add_fetched_messages(vec![
                fixture_message(1, "<p>stale</p>"),
                fixture_message(3, "<p>c</p>"),
            ])
            .expect("a new message");
        assert_eq!(snapshot.revision, 2);
        let contents: Vec<_> = snapshot
            .messages
            .iter()
            .map(|message| message.content_html.as_str())
            .collect();
        assert_eq!(contents, vec!["<p>a</p>", "<p>c</p>"]);
        assert_eq!(snapshot.unread[0].count, 1);
        assert!(
            reducer
                .add_fetched_messages(vec![fixture_message(3, "<p>c</p>")])
                .is_none()
        );
    }

    fn unread_entry(id: i64) -> super::UnreadMessage {
        super::UnreadMessage {
            id,
            stream_id: Some(5),
            topic: Some("Rust core".to_owned()),
            user_ids: Vec::new(),
            mentioned: false,
        }
    }

    #[test]
    fn a_fetch_that_answers_after_the_read_does_not_make_the_message_unread_again() {
        let mut reducer = SyncReducer::new(
            0,
            BootstrapState {
                unread: vec![unread_entry(3)],
                ..BootstrapState::default()
            },
        );
        let read = reducer.apply_batch(vec![SyncEvent::MessageFlagsUpdated {
            event_id: 1,
            added: true,
            flag: "read".to_owned(),
            message_ids: vec![3],
            details: Vec::new(),
            all: false,
        }]);
        assert!(read.snapshot.expect("changed").unread.is_empty());

        // The fetch was answered before the read, so its copy still lacks the flag.
        let snapshot = reducer
            .add_fetched_messages(vec![fixture_message(3, "<p>c</p>")])
            .expect("a new message");
        assert!(snapshot.unread.is_empty());
        assert_eq!(snapshot.messages[0].flags, ["read"]);
    }

    #[test]
    fn a_read_this_client_made_clears_a_message_the_queue_never_cleared() {
        let mut reducer = SyncReducer::new(
            0,
            BootstrapState {
                messages: vec![fixture_message(1, "<p>a</p>")],
                unread: vec![unread_entry(1), unread_entry(2)],
                ..BootstrapState::default()
            },
        );
        let snapshot = reducer.mark_read_locally(&[1]).expect("changed");
        assert_eq!(snapshot.unread[0].count, 1);
        assert_eq!(snapshot.messages[0].flags, ["read"]);
        assert!(
            reducer.mark_read_locally(&[1]).is_none(),
            "nothing left to change"
        );
        assert!(
            reducer.mark_read_locally(&[9]).is_none(),
            "unknown ids change nothing"
        );
        let snapshot = reducer.mark_read_locally(&[2]).expect("changed");
        assert!(snapshot.unread.is_empty());
    }

    #[test]
    fn channel_moves_prefer_the_new_channel_and_apply_to_every_message() {
        let mut reducer = SyncReducer::new(
            0,
            BootstrapState {
                messages: vec![
                    fixture_message(1, "<p>a</p>"),
                    fixture_message(2, "<p>b</p>"),
                ],
                ..BootstrapState::default()
            },
        );
        let outcome = reducer.apply_batch(vec![SyncEvent::MessageUpdated {
            event_id: 1,
            update: MessageUpdate {
                message_id: 1,
                message_ids: vec![1, 2],
                content_html: None,
                edit_timestamp: Some(1_770_000_200),
                topic: Some("moved".to_owned()),
                stream_id: Some(9),
                origin_stream_id: Some(5),
            },
        }]);
        assert_eq!(outcome.topic_changed_streams, vec![5, 9]);
        let snapshot = outcome.snapshot.expect("changed");
        assert!(snapshot.messages.iter().all(|message| {
            message.stream_id == Some(9) && message.topic.as_deref() == Some("moved")
        }));
        // A move is not a content edit.
        assert!(
            snapshot
                .messages
                .iter()
                .all(|message| message.last_edit_timestamp.is_none())
        );
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
    async fn typing_events_and_settings_are_reported_without_a_snapshot() {
        let register = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "last_event_id":40,
            "realm_users":[],
            "subscriptions":[],
            "user_settings":{
                "send_private_message_typing_notifications":false,
                "send_stream_typing_notifications":true
            }
        }"#;
        let (server, requests) = spawn_mock(vec![
            (StatusCode::OK, register.to_owned()),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "queue_id":"queue-fixture",
                    "events":[
                        {"id":41,"type":"typing","op":"start","message_type":"direct",
                         "sender":{"user_id":22,"email":"theo@example.com"},
                         "recipients":[{"user_id":9,"email":"maya@example.com"},
                                       {"user_id":22,"email":"theo@example.com"}]},
                        {"id":42,"type":"typing","op":"start","message_type":"stream",
                         "sender":{"user_id":22,"email":"theo@example.com"},
                         "stream_id":5,"topic":"macOS"},
                        {"id":43,"type":"typing","op":"stop","message_type":"stream",
                         "sender":{"user_id":22,"email":"theo@example.com"},
                         "stream_id":5,"topic":"macOS"},
                        {"id":44,"type":"typing","op":"start","message_type":"mystery"},
                        {"id":45,"type":"user_settings","op":"update",
                         "property":"send_private_message_typing_notifications","value":true}
                    ]
                }"#
                .to_owned(),
            ),
        ]);
        let client = EventQueueClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("sync client");
        let (mut session, _) = SyncSession::start(client, RecoveryPolicy::default(), 3)
            .await
            .expect("initial registration");
        assert_eq!(
            session.typing_preferences(),
            TypingPreferences {
                direct: false,
                channel: true
            }
        );

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("typing events are ordinary events");
        };
        assert!(outcome.snapshot.is_none(), "typing is not domain state");
        assert_eq!(outcome.typing.len(), 3);
        assert_eq!(
            outcome.typing[0],
            TypingNotice {
                started: true,
                sender_id: 22,
                scope: TypingScope::Direct {
                    user_ids: vec![9, 22]
                },
            }
        );
        assert_eq!(
            outcome.typing[1].scope,
            TypingScope::Topic {
                stream_id: 5,
                topic: "macOS".to_owned()
            }
        );
        assert!(!outcome.typing[2].started);
        assert!(session.typing_preferences().direct);

        let register_request = requests.recv().expect("register request");
        assert!(register_request.contains("stream_typing_notifications"));
        assert!(register_request.contains("typing"));
    }

    #[tokio::test]
    async fn notification_settings_and_topic_policies_follow_the_server() {
        let register = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "last_event_id":40,
            "realm_users":[],
            "subscriptions":[
                {"stream_id":5,"name":"engineering","desktop_notifications":true},
                {"stream_id":6,"name":"random","desktop_notifications":null},
                {"stream_id":7,"name":"general"}
            ],
            "user_settings":{"enable_stream_desktop_notifications":false},
            "user_topics":[
                {"stream_id":5,"topic_name":"Build Farm","last_updated":1,"visibility_policy":1},
                {"stream_id":6,"topic_name":"deploys","last_updated":2,"visibility_policy":3},
                {"stream_id":6,"topic_name":"inherit","last_updated":3,"visibility_policy":0}
            ]
        }"#;
        let (server, requests) = spawn_mock(vec![
            (StatusCode::OK, register.to_owned()),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "queue_id":"queue-fixture",
                    "events":[
                        {"id":41,"type":"subscription","op":"update","stream_id":6,
                         "property":"desktop_notifications","value":true},
                        {"id":42,"type":"subscription","op":"update","stream_id":5,
                         "property":"desktop_notifications","value":null},
                        {"id":43,"type":"user_settings","op":"update",
                         "property":"enable_stream_desktop_notifications","value":true},
                        {"id":44,"type":"user_topic","stream_id":5,"topic_name":"build farm",
                         "last_updated":9,"visibility_policy":0},
                        {"id":45,"type":"user_topic","stream_id":7,"topic_name":"Lunch",
                         "last_updated":9,"visibility_policy":1}
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

        let choices = initial
            .channels
            .iter()
            .map(|channel| channel.desktop_notifications)
            .collect::<Vec<_>>();
        assert_eq!(choices, vec![Some(true), None, None]);
        assert!(!initial.channel_notifications_default);
        assert_eq!(
            initial
                .topic_policies
                .iter()
                .map(|policy| (policy.stream_id, policy.topic.as_str(), policy.visibility))
                .collect::<Vec<_>>(),
            vec![
                (5, "Build Farm", TopicVisibility::Muted),
                (6, "deploys", TopicVisibility::Followed),
            ]
        );

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("settings events are ordinary events");
        };
        let snapshot = outcome.snapshot.expect("changed");
        let choices = snapshot
            .channels
            .iter()
            .map(|channel| channel.desktop_notifications)
            .collect::<Vec<_>>();
        assert_eq!(choices, vec![None, Some(true), None]);
        assert!(snapshot.channel_notifications_default);
        // The reset is matched case-insensitively; the new mute is added.
        assert_eq!(
            snapshot
                .topic_policies
                .iter()
                .map(|policy| (policy.stream_id, policy.topic.as_str(), policy.visibility))
                .collect::<Vec<_>>(),
            vec![
                (6, "deploys", TopicVisibility::Followed),
                (7, "Lunch", TopicVisibility::Muted),
            ]
        );

        let register_request = requests.recv().expect("register request");
        assert!(register_request.contains("user_topic"));
    }

    #[tokio::test]
    async fn user_statuses_and_invisible_mode_follow_the_server() {
        let register = r#"{
            "result":"success",
            "queue_id":"queue-fixture",
            "last_event_id":50,
            "realm_users":[],
            "subscriptions":[],
            "user_settings":{"presence_enabled":false},
            "user_status":{
                "7":{"status_text":"In a meeting","emoji_name":"calendar",
                     "emoji_code":"1f4c6","reaction_type":"unicode_emoji"},
                "8":{"away":true},
                "9":{"status_text":"Lunch"},
                "x":{"status_text":"ignored"}
            }
        }"#;
        let (server, requests) = spawn_mock(vec![
            (StatusCode::OK, register.to_owned()),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "queue_id":"queue-fixture",
                    "events":[
                        {"id":51,"type":"user_status","user_id":7,"emoji_name":"",
                         "emoji_code":"","reaction_type":""},
                        {"id":52,"type":"user_status","user_id":9,"status_text":""},
                        {"id":53,"type":"user_status","user_id":10,"status_text":"Commuting",
                         "emoji_name":"bus","emoji_code":"1f68c","reaction_type":"unicode_emoji"},
                        {"id":54,"type":"user_settings","op":"update",
                         "property":"presence_enabled","value":true}
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

        assert!(initial.invisible);
        assert_eq!(
            initial
                .user_statuses
                .iter()
                .map(|status| (
                    status.user_id,
                    status.status_text.as_str(),
                    status.emoji_name.as_str(),
                    status.emoji_code.as_str(),
                    status.reaction_type.as_str()
                ))
                .collect::<Vec<_>>(),
            vec![
                (7, "In a meeting", "calendar", "1f4c6", "unicode_emoji"),
                (9, "Lunch", "", "", ""),
            ]
        );

        let SyncCycle::Events(outcome) = session.advance().await else {
            panic!("status events are ordinary events");
        };
        let snapshot = outcome.snapshot.expect("changed");
        assert!(!snapshot.invisible);
        // 7 keeps only the text, 9 said nothing any more, 10 is new.
        assert_eq!(
            snapshot
                .user_statuses
                .iter()
                .map(|status| (
                    status.user_id,
                    status.status_text.as_str(),
                    status.emoji_name.as_str()
                ))
                .collect::<Vec<_>>(),
            vec![(7, "In a meeting", ""), (10, "Commuting", "bus")]
        );

        let register_request = requests.recv().expect("register request");
        assert!(register_request.contains("user_status"));
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
            avatar_url: None,
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
            desktop_notifications: None,
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
            last_edit_timestamp: None,
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
