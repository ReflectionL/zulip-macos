#![doc = "Swift-facing actor boundary for the native Zulip macOS client."]

use std::{
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use tokio::{
    runtime::Runtime,
    sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel},
    task::JoinSet,
    time::Instant,
};
use zulip_core::{
    auth::{AuthenticatedAccount, AuthenticationClient, SecretString},
    content::{
        ContentBlock as NativeContentBlock, InlineContent as NativeInlineContent, parse_zulip_html,
    },
    database::{CacheDatabase, CachedAccount, CachedConversation, CachedSnapshot, DraftRecord},
    media::MediaClient,
    messages::{
        ConversationTarget, MessageClient, MessageFlag, MessageWriteOperation, OutgoingMessage,
        TopicPropagation, TopicSummary,
    },
    sync::{
        EventQueueClient, MessageSummary, RecoveryPolicy, SyncCycle, SyncSession, SyncSnapshot,
        UserSummary,
    },
};

uniffi::setup_scaffolding!();

/// Minimum spacing between full-snapshot cache writes during busy event streams.
const SNAPSHOT_CACHE_INTERVAL_SECONDS: u64 = 5;

/// Best-effort handle to the on-disk cache.
///
/// Persistence problems never fail a user-visible operation: a missing or
/// damaged cache only means the app behaves as it did before offline reading.
#[derive(Clone, Default)]
struct CacheHandle(Option<Arc<Mutex<CacheDatabase>>>);

impl CacheHandle {
    fn open(path: Option<&Path>) -> Self {
        let Some(path) = path else {
            return Self(None);
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        Self(
            CacheDatabase::open(path)
                .ok()
                .map(|database| Arc::new(Mutex::new(database))),
        )
    }

    fn with<T>(
        &self,
        operation: impl FnOnce(&CacheDatabase) -> Result<T, zulip_core::database::DatabaseError>,
    ) -> Option<T> {
        let database = self.0.as_ref()?.lock().ok()?;
        operation(&database).ok()
    }
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

fn now_timestamp() -> i64 {
    i64::try_from(now_seconds()).unwrap_or(i64::MAX)
}

/// Stable conversation identity crossing the Swift/Rust boundary.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreConversationKey {
    /// Account combined feed.
    Inbox {
        /// Client-owned account identifier.
        account_id: String,
    },
    /// Messages mentioning the current user.
    Mentions {
        /// Client-owned account identifier.
        account_id: String,
    },
    /// Messages starred by the current user.
    Starred {
        /// Client-owned account identifier.
        account_id: String,
    },
    /// Messages not yet read by the current user.
    Unread {
        /// Client-owned account identifier.
        account_id: String,
    },
    /// One channel.
    Channel {
        /// Client-owned account identifier.
        account_id: String,
        /// Zulip stream identifier.
        stream_id: i64,
    },
    /// One channel topic.
    Topic {
        /// Client-owned account identifier.
        account_id: String,
        /// Zulip stream identifier.
        stream_id: i64,
        /// Exact topic name.
        topic: String,
    },
    /// Direct-message conversation.
    DirectMessage {
        /// Client-owned account identifier.
        account_id: String,
        /// Other participant identifiers.
        recipient_ids: Vec<i64>,
    },
}

impl CoreConversationKey {
    fn account_id(&self) -> &str {
        match self {
            Self::Inbox { account_id }
            | Self::Mentions { account_id }
            | Self::Starred { account_id }
            | Self::Unread { account_id }
            | Self::Channel { account_id, .. }
            | Self::Topic { account_id, .. }
            | Self::DirectMessage { account_id, .. } => account_id,
        }
    }

    fn cache_key(&self) -> String {
        match self {
            Self::Inbox { .. } => "inbox".to_owned(),
            Self::Mentions { .. } => "mentions".to_owned(),
            Self::Starred { .. } => "starred".to_owned(),
            Self::Unread { .. } => "unread".to_owned(),
            Self::Channel { stream_id, .. } => format!("channel:{stream_id}"),
            Self::Topic {
                stream_id, topic, ..
            } => format!("topic:{stream_id}:{topic}"),
            Self::DirectMessage { recipient_ids, .. } => {
                let mut ids = recipient_ids.clone();
                ids.sort_unstable();
                ids.dedup();
                format!(
                    "dm:{}",
                    ids.iter().map(i64::to_string).collect::<Vec<_>>().join(",")
                )
            }
        }
    }

    /// Inverse of [`Self::cache_key`], for restoring persisted drafts.
    fn from_cache_key(account_id: &str, key: &str) -> Option<Self> {
        let account_id = account_id.to_owned();
        match key {
            "inbox" => return Some(Self::Inbox { account_id }),
            "mentions" => return Some(Self::Mentions { account_id }),
            "starred" => return Some(Self::Starred { account_id }),
            "unread" => return Some(Self::Unread { account_id }),
            _ => {}
        }
        if let Some(stream_id) = key.strip_prefix("channel:") {
            return Some(Self::Channel {
                account_id,
                stream_id: stream_id.parse().ok()?,
            });
        }
        if let Some(rest) = key.strip_prefix("topic:") {
            let (stream_id, topic) = rest.split_once(':')?;
            return Some(Self::Topic {
                account_id,
                stream_id: stream_id.parse().ok()?,
                topic: topic.to_owned(),
            });
        }
        let recipients = key.strip_prefix("dm:")?;
        let recipient_ids = recipients
            .split(',')
            .map(|id| id.parse().ok())
            .collect::<Option<Vec<i64>>>()?;
        Some(Self::DirectMessage {
            account_id,
            recipient_ids,
        })
    }

    fn target(&self) -> ConversationTarget {
        match self {
            Self::Inbox { .. } => ConversationTarget::Combined,
            Self::Mentions { .. } => ConversationTarget::Mentions,
            Self::Starred { .. } => ConversationTarget::Starred,
            Self::Unread { .. } => ConversationTarget::Unread,
            Self::Channel { stream_id, .. } => ConversationTarget::Channel {
                stream_id: *stream_id,
            },
            Self::Topic {
                stream_id, topic, ..
            } => ConversationTarget::Topic {
                stream_id: *stream_id,
                topic: topic.clone(),
            },
            Self::DirectMessage { recipient_ids, .. } => ConversationTarget::Direct {
                recipient_ids: recipient_ids.clone(),
            },
        }
    }
}

/// One persisted composer draft.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreDraft {
    /// Conversation the draft belongs to.
    pub key: CoreConversationKey,
    /// Draft Markdown/plain text.
    pub content: String,
}

/// Commands submitted synchronously by Swift and executed off the main actor.
#[derive(Clone, uniffi::Enum)]
pub enum CoreCommand {
    /// Foundation health check.
    Ping {
        /// Correlates the response.
        request_id: u64,
        /// Non-secret test payload.
        payload: String,
    },
    /// Starts an authenticated live session from a Keychain-loaded API key.
    StartApiKeySession {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Normalized or user-entered Zulip server root.
        server_url: String,
        /// Zulip API email.
        email: String,
        /// API key moved immediately into zeroizing Rust memory.
        api_key: String,
    },
    /// Exchanges a password for an API key, then starts a live session.
    StartPasswordSession {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Normalized or user-entered Zulip server root.
        server_url: String,
        /// Zulip login username.
        username: String,
        /// Password moved immediately into zeroizing Rust memory.
        password: String,
    },
    /// Loads the newest messages for one conversation.
    OpenConversation {
        /// Correlates the response.
        request_id: u64,
        /// Stable account-scoped conversation.
        key: CoreConversationKey,
        /// Number of newest messages, from 1 through 1000.
        limit: u16,
    },
    /// Loads a page ending immediately before a known message.
    LoadOlderMessages {
        /// Correlates the response.
        request_id: u64,
        /// Stable account-scoped conversation.
        key: CoreConversationKey,
        /// Oldest message currently held by Swift.
        before_message_id: i64,
        /// Maximum number of earlier messages, from 1 through 1000.
        limit: u16,
    },
    /// Searches all messages visible to the active account.
    SearchMessages {
        /// Correlates the response and allows Swift to ignore stale searches.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Non-empty server-side search query.
        query: String,
        /// Maximum number of results, from 1 through 100.
        limit: u16,
    },
    /// Loads conversation context centered on one search result.
    OpenMessage {
        /// Correlates the response.
        request_id: u64,
        /// Stable account-scoped conversation containing the message.
        key: CoreConversationKey,
        /// Server message identifier to include and focus.
        message_id: i64,
        /// Number of messages before the target.
        num_before: u16,
        /// Number of messages after the target.
        num_after: u16,
    },
    /// Sends a channel message.
    SendChannelMessage {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Destination channel.
        stream_id: i64,
        /// Destination topic.
        topic: String,
        /// Zulip-flavored Markdown.
        content: String,
        /// Stable local echo identifier.
        local_id: String,
    },
    /// Sends a direct message.
    SendDirectMessage {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Destination users.
        recipient_ids: Vec<i64>,
        /// Zulip-flavored Markdown.
        content: String,
        /// Stable local echo identifier.
        local_id: String,
    },
    /// Replaces the content of one message.
    EditMessage {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Server message identifier.
        message_id: i64,
        /// Replacement Zulip-flavored Markdown.
        content: String,
    },
    /// Permanently deletes one message.
    DeleteMessage {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Server message identifier.
        message_id: i64,
    },
    /// Adds or removes the current user's emoji reaction.
    UpdateReaction {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Server message identifier.
        message_id: i64,
        /// Stable Zulip emoji name.
        emoji_name: String,
        /// Whether to add instead of remove the reaction.
        add: bool,
    },
    /// Adds or removes a personal read/star flag.
    UpdateMessageFlag {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Server message identifiers.
        message_ids: Vec<i64>,
        /// Supported personal flag.
        flag: CoreMessageFlag,
        /// Whether to add instead of remove the flag.
        add: bool,
    },
    /// Renames every message in an existing channel topic.
    RenameTopic {
        /// Correlates the response.
        request_id: u64,
        /// Existing account-scoped topic.
        key: CoreConversationKey,
        /// Any server message currently in the topic.
        message_id: i64,
        /// Validated replacement topic name.
        new_topic: String,
    },
    /// Moves one channel message to an existing or new topic.
    MoveMessageToTopic {
        /// Correlates the response.
        request_id: u64,
        /// Existing account-scoped topic containing the message.
        key: CoreConversationKey,
        /// Server message to move.
        message_id: i64,
        /// Validated destination topic name.
        new_topic: String,
    },
    /// Uploads one picker-selected file without sending a message.
    UploadAttachment {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Absolute security-scoped local file path.
        local_path: String,
        /// User-visible filename selected by Swift.
        filename: String,
    },
    /// Resolves one same-origin protected upload into the private cache.
    LoadMedia {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Same-origin `/user_uploads/` message URL.
        remote_url: String,
    },
    /// Adds the personal `read` flag to messages.
    MarkRead {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Server message identifiers.
        message_ids: Vec<i64>,
    },
    /// Ends the current live account session and forgets its cached data.
    Disconnect {
        /// Correlates the response.
        request_id: u64,
    },
    /// Persists the composer text for one conversation; empty text deletes it.
    SaveDraft {
        /// Correlates failures.
        request_id: u64,
        /// Stable account-scoped conversation.
        key: CoreConversationKey,
        /// Draft Markdown/plain text.
        content: String,
    },
    /// Loads every persisted draft of one account.
    LoadDrafts {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
    },
    /// Loads the last cached navigation state without using the network.
    LoadCachedSession {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
    },
}

impl CoreCommand {
    const fn request_id(&self) -> u64 {
        match self {
            Self::Ping { request_id, .. }
            | Self::StartApiKeySession { request_id, .. }
            | Self::StartPasswordSession { request_id, .. }
            | Self::LoadCachedSession { request_id, .. }
            | Self::SaveDraft { request_id, .. }
            | Self::LoadDrafts { request_id, .. }
            | Self::OpenConversation { request_id, .. }
            | Self::LoadOlderMessages { request_id, .. }
            | Self::SearchMessages { request_id, .. }
            | Self::OpenMessage { request_id, .. }
            | Self::SendChannelMessage { request_id, .. }
            | Self::SendDirectMessage { request_id, .. }
            | Self::EditMessage { request_id, .. }
            | Self::DeleteMessage { request_id, .. }
            | Self::UpdateReaction { request_id, .. }
            | Self::UpdateMessageFlag { request_id, .. }
            | Self::RenameTopic { request_id, .. }
            | Self::MoveMessageToTopic { request_id, .. }
            | Self::UploadAttachment { request_id, .. }
            | Self::LoadMedia { request_id, .. }
            | Self::MarkRead { request_id, .. }
            | Self::Disconnect { request_id } => *request_id,
        }
    }
}

/// Personal message flag supported across the bridge.
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreMessageFlag {
    /// Read/unread state.
    Read,
    /// Starred/unstarred state.
    Starred,
}

impl From<CoreMessageFlag> for MessageFlag {
    fn from(flag: CoreMessageFlag) -> Self {
        match flag {
            CoreMessageFlag::Read => Self::Read,
            CoreMessageFlag::Starred => Self::Starred,
        }
    }
}

/// One-time API credential returned for immediate Keychain persistence.
#[derive(Clone, Eq, PartialEq, uniffi::Record)]
pub struct CoreSessionCredential {
    /// API key derived from a password or validated as a direct login.
    pub api_key: String,
}

impl std::fmt::Debug for CoreSessionCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CoreSessionCredential { api_key: [REDACTED] }")
    }
}

/// User projection in a bridge snapshot.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreUser {
    /// Zulip user identifier.
    pub user_id: i64,
    /// Display name.
    pub full_name: String,
    /// Visible Zulip API email.
    pub email: Option<String>,
    /// Active account state.
    pub is_active: bool,
    /// Bot account state.
    pub is_bot: bool,
}

/// Channel projection in a bridge snapshot.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreChannel {
    /// Zulip stream identifier.
    pub stream_id: i64,
    /// Display name.
    pub name: String,
    /// Server-provided color.
    pub color: String,
    /// Personal mute state.
    pub is_muted: bool,
}

/// Topic projection discovered through the authenticated topics API.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreTopic {
    /// Zulip stream identifier.
    pub stream_id: i64,
    /// Exact topic name.
    pub name: String,
    /// Most recent message in the topic.
    pub max_message_id: i64,
}

/// Message projection in a bridge snapshot or page.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMessage {
    /// Zulip message identifier.
    pub message_id: i64,
    /// Sender identifier.
    pub sender_id: i64,
    /// Sender display name.
    pub sender_full_name: String,
    /// Unix timestamp in seconds.
    pub timestamp: i64,
    /// Sanitized native content parsed by Rust from rendered Zulip HTML.
    pub content: Vec<CoreContentBlock>,
    /// Channel identifier for channel messages.
    pub stream_id: Option<i64>,
    /// Topic name for channel messages.
    pub topic: Option<String>,
    /// Recipient identifiers for direct messages.
    pub recipient_ids: Vec<i64>,
    /// Personal flags returned for the active account.
    pub flags: Vec<String>,
    /// Reactions currently attached to the message.
    pub reactions: Vec<CoreReaction>,
}

/// Sanitized inline content crossing the application bridge.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreInlineContent {
    /// Plain display text.
    Text {
        /// Text value.
        value: String,
    },
    /// A safe native link.
    Link {
        /// Visible label.
        label: String,
        /// Sanitized destination.
        url: String,
    },
    /// A Zulip user mention.
    Mention {
        /// Display name without Zulip markup.
        display_name: String,
        /// Zulip user identifier.
        user_id: i64,
    },
    /// A rendered emoji or readable custom-emoji placeholder.
    Emoji {
        /// Stable Zulip emoji name.
        name: String,
        /// Readable fallback value.
        value: String,
    },
}

/// One list item containing recursively nested native blocks.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreContentListItem {
    /// Blocks within this item.
    pub blocks: Vec<CoreContentBlock>,
}

/// Sanitized native block content crossing the application bridge.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreContentBlock {
    /// Paragraph or heading content.
    Paragraph {
        /// Inline values in display order.
        content: Vec<CoreInlineContent>,
    },
    /// Nested quotation.
    Quote {
        /// Quoted blocks.
        blocks: Vec<CoreContentBlock>,
    },
    /// Ordered or unordered list.
    List {
        /// List items.
        items: Vec<CoreContentListItem>,
        /// Numeric instead of bullet markers.
        ordered: bool,
    },
    /// Preformatted code.
    Code {
        /// Optional language hint.
        language: Option<String>,
        /// Exact readable code value.
        value: String,
    },
    /// Safe image reference awaiting account-aware media loading.
    Image {
        /// Sanitized source.
        url: String,
        /// Alternative text.
        alt: String,
        /// Optional width hint.
        width: Option<u32>,
        /// Optional height hint.
        height: Option<u32>,
    },
    /// Readable unsupported/unsafe fallback.
    Unsupported {
        /// Sanitized summary.
        summary: String,
    },
}

/// One reaction attached to a bridge message.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreReaction {
    /// Stable emoji name used by the write endpoint.
    pub emoji_name: String,
    /// Zulip user identifier of the reacting user.
    pub user_id: i64,
}

/// Immutable full state projection.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreSnapshot {
    /// Monotonic snapshot revision within the session.
    pub revision: u64,
    /// Highest accepted event identifier.
    pub last_event_id: i64,
    /// Users sorted by identifier.
    pub users: Vec<CoreUser>,
    /// Channels sorted by identifier.
    pub channels: Vec<CoreChannel>,
    /// Visible topics ordered by channel and server recency.
    pub topics: Vec<CoreTopic>,
    /// Messages sorted by identifier.
    pub messages: Vec<CoreMessage>,
}

/// Newest message page for one stable conversation.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreConversationPage {
    /// Account-scoped conversation key.
    pub key: CoreConversationKey,
    /// Messages sorted by server ID.
    pub messages: Vec<CoreMessage>,
    /// Whether this page reached the oldest matching message.
    pub found_oldest: bool,
    /// Whether this page reached the newest matching message.
    pub found_newest: bool,
}

/// One immutable, account-scoped server search result.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreSearchResult {
    /// Conversation that contains the matching message.
    pub key: CoreConversationKey,
    /// Matching server message.
    pub message: CoreMessage,
}

/// Scope applied to a successful topic update.
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreTopicPropagation {
    /// Only the selected message moved.
    ChangeOne,
    /// The selected message's entire former topic was renamed.
    ChangeAll,
}

/// Typed events delivered from the Rust actor to Swift.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreEvent {
    /// Correlated foundation response.
    Pong {
        /// Originating request.
        request_id: u64,
        /// Human-readable core identity.
        message: String,
    },
    /// Initial live registration completed.
    SessionStarted {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Normalized Zulip server root.
        server_url: String,
        /// Canonical API email.
        email: String,
        /// Authenticated Zulip user identifier, or zero until the first
        /// own-user event for a direct API-key login.
        user_id: i64,
        /// Authenticated display name.
        full_name: String,
        /// One-time credential for immediate Keychain persistence.
        credential: CoreSessionCredential,
        /// First immutable state.
        snapshot: CoreSnapshot,
    },
    /// Long-poll reduction or full resync produced a changed snapshot.
    SnapshotUpdated {
        /// Active account partition.
        account_id: String,
        /// New immutable state.
        snapshot: CoreSnapshot,
    },
    /// One conversation page loaded.
    ConversationOpened {
        /// Originating request.
        request_id: u64,
        /// Loaded page.
        page: CoreConversationPage,
    },
    /// An older page loaded for merging ahead of the current timeline.
    ConversationHistoryLoaded {
        /// Originating request.
        request_id: u64,
        /// Historical page.
        page: CoreConversationPage,
    },
    /// A correlated server-side message search completed.
    SearchCompleted {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Results ordered newest first.
        results: Vec<CoreSearchResult>,
    },
    /// Conversation context centered on a requested message loaded.
    MessageFocused {
        /// Originating request.
        request_id: u64,
        /// Message that must be present and focused.
        message_id: i64,
        /// Anchored conversation page.
        page: CoreConversationPage,
    },
    /// A send request succeeded.
    MessageSent {
        /// Originating request.
        request_id: u64,
        /// Stable local echo identifier.
        local_id: String,
        /// Server-assigned message identifier.
        message_id: i64,
    },
    /// A picker-selected file was uploaded and is ready for composer insertion.
    AttachmentUploaded {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Server-normalized filename.
        filename: String,
        /// Same-origin uploaded-file route.
        url: String,
        /// Markdown link to insert without automatically sending.
        markdown: String,
    },
    /// Protected uploaded media is available at a cache-owned local URL.
    MediaReady {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Same-origin route found in message content.
        remote_url: String,
        /// Cache-owned `file:` URL.
        local_url: String,
        /// Sanitized response MIME type, if present.
        content_type: Option<String>,
        /// Number of cached bytes.
        byte_count: u64,
        /// Whether this request was served without a network download.
        cache_hit: bool,
    },
    /// A correlated content edit succeeded.
    MessageEdited {
        /// Originating request.
        request_id: u64,
        /// Updated server message.
        message_id: i64,
        /// Submitted replacement Markdown.
        content: String,
    },
    /// A correlated permanent deletion succeeded.
    MessageDeleted {
        /// Originating request.
        request_id: u64,
        /// Deleted server message.
        message_id: i64,
    },
    /// A correlated emoji reaction mutation succeeded.
    ReactionUpdated {
        /// Originating request.
        request_id: u64,
        /// Updated server message.
        message_id: i64,
        /// Stable Zulip emoji name.
        emoji_name: String,
        /// Whether the reaction was added.
        added: bool,
    },
    /// A correlated personal flag mutation succeeded.
    MessageFlagUpdated {
        /// Originating request.
        request_id: u64,
        /// Updated server messages.
        message_ids: Vec<i64>,
        /// Updated personal flag.
        flag: CoreMessageFlag,
        /// Whether the flag was added.
        added: bool,
    },
    /// A correlated topic mutation succeeded.
    TopicUpdated {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Channel containing the affected message.
        stream_id: i64,
        /// Topic name before the mutation.
        old_topic: String,
        /// Topic name after the mutation.
        new_topic: String,
        /// Anchor or moved message.
        message_id: i64,
        /// Update scope accepted by Zulip.
        propagation: CoreTopicPropagation,
    },
    /// A read-state write succeeded.
    MessagesMarkedRead {
        /// Originating request.
        request_id: u64,
        /// Updated message identifiers.
        message_ids: Vec<i64>,
    },
    /// The actor scheduled a transient retry.
    RetryScheduled {
        /// Active account partition.
        account_id: String,
        /// Delay before another poll or resync.
        delay_milliseconds: u64,
    },
    /// Persisted drafts for an account.
    DraftsLoaded {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Non-empty drafts, newest first.
        drafts: Vec<CoreDraft>,
    },
    /// Cached navigation state for an account that is not (yet) live.
    CachedSessionLoaded {
        /// Originating request.
        request_id: u64,
        /// Active account partition.
        account_id: String,
        /// Normalized Zulip server root.
        server_url: String,
        /// Canonical API email.
        email: String,
        /// Authenticated Zulip user identifier.
        user_id: i64,
        /// Authenticated display name.
        full_name: String,
        /// Last known immutable navigation state.
        snapshot: CoreSnapshot,
    },
    /// Polling succeeded again after one or more scheduled retries.
    SyncResumed {
        /// Active account partition.
        account_id: String,
    },
    /// The active session ended.
    Disconnected {
        /// Originating request.
        request_id: u64,
    },
    /// A command or background session operation failed.
    Failed {
        /// Originating request, or `None` for a background failure.
        request_id: Option<u64>,
        /// Sanitized, non-secret error.
        message: String,
    },
}

/// Foreign event sink implemented by Swift.
#[uniffi::export(foreign)]
pub trait CoreEventSink: Send + Sync {
    /// Receives an event off the Swift main actor.
    fn handle_event(&self, event: CoreEvent);
}

/// Long-lived entry point owned by the Swift application.
#[derive(uniffi::Object)]
pub struct RustCoreClient {
    sender: UnboundedSender<CoreCommand>,
    event_sink: Arc<dyn CoreEventSink>,
    _runtime: Runtime,
}

#[uniffi::export]
impl RustCoreClient {
    /// Creates the Rust runtime and single command actor.
    ///
    /// # Panics
    ///
    /// Panics only if the process cannot initialize Tokio's built-in worker
    /// runtime, in which case no core operation can be performed.
    #[uniffi::constructor]
    #[allow(clippy::needless_pass_by_value)]
    pub fn new(
        event_sink: Arc<dyn CoreEventSink>,
        media_cache_root_path: String,
        database_path: Option<String>,
    ) -> Arc<Self> {
        let runtime = Runtime::new().expect("the built-in Tokio runtime initializes");
        let (sender, receiver) = unbounded_channel();
        runtime.spawn(run_actor(
            receiver,
            Arc::clone(&event_sink),
            PathBuf::from(media_cache_root_path),
            CacheHandle::open(database_path.as_deref().map(Path::new)),
        ));
        Arc::new(Self {
            sender,
            event_sink,
            _runtime: runtime,
        })
    }

    /// Enqueues a typed command without blocking on network or storage work.
    #[allow(clippy::needless_pass_by_value)]
    pub fn submit(&self, command: CoreCommand) {
        let request_id = command.request_id();
        if self.sender.send(command).is_err() {
            self.event_sink.handle_event(CoreEvent::Failed {
                request_id: Some(request_id),
                message: "the Rust core actor is unavailable".to_owned(),
            });
        }
    }
}

struct AccountSession {
    account_id: String,
    own_user_id: i64,
    messages: Arc<MessageClient>,
    media: Arc<MediaClient>,
    sync: SyncSession,
    topics: Vec<TopicSummary>,
    cache: CacheHandle,
    last_snapshot_cache_seconds: AtomicU64,
}

enum ActorInput {
    Command(Option<CoreCommand>),
    Sync(SyncCycle),
}

async fn run_actor(
    mut receiver: UnboundedReceiver<CoreCommand>,
    event_sink: Arc<dyn CoreEventSink>,
    media_cache_root: PathBuf,
    cache: CacheHandle,
) {
    let mut account: Option<AccountSession> = None;
    let mut poll_not_before = Instant::now();
    let mut retrying = false;

    loop {
        let input = if let Some(session) = account.as_mut() {
            let sync_advance = async {
                tokio::time::sleep_until(poll_not_before).await;
                session.sync.advance().await
            };
            tokio::pin!(sync_advance);
            tokio::select! {
                command = receiver.recv() => ActorInput::Command(command),
                cycle = &mut sync_advance => ActorInput::Sync(cycle),
            }
        } else {
            ActorInput::Command(receiver.recv().await)
        };

        match input {
            ActorInput::Command(Some(command)) => {
                let resets_poll = matches!(
                    &command,
                    CoreCommand::StartApiKeySession { .. }
                        | CoreCommand::StartPasswordSession { .. }
                        | CoreCommand::Disconnect { .. }
                );
                let previous_account = account.as_ref().map(|session| session.account_id.clone());
                handle_command(
                    command,
                    &mut account,
                    &event_sink,
                    &media_cache_root,
                    &cache,
                )
                .await;
                let current_account = account.as_ref().map(|session| session.account_id.as_str());
                if resets_poll || previous_account.as_deref() != current_account {
                    poll_not_before = Instant::now();
                }
            }
            ActorInput::Command(None) => break,
            ActorInput::Sync(cycle) => {
                let terminal = matches!(&cycle, SyncCycle::Fatal { .. });
                match &cycle {
                    SyncCycle::RetryAfter { .. } => retrying = true,
                    SyncCycle::Events(_) if retrying => {
                        retrying = false;
                        if let Some(session) = account.as_ref() {
                            event_sink.handle_event(CoreEvent::SyncResumed {
                                account_id: session.account_id.clone(),
                            });
                        }
                    }
                    _ => retrying = false,
                }
                poll_not_before = handle_sync_cycle(cycle, account.as_ref(), &event_sink);
                if terminal {
                    account = None;
                }
            }
        }
    }
}

#[allow(clippy::too_many_lines)]
async fn handle_command(
    command: CoreCommand,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
    media_cache_root: &Path,
    cache: &CacheHandle,
) {
    match command {
        CoreCommand::Ping {
            request_id,
            payload,
        } => emit_pong(request_id, &payload, event_sink),
        CoreCommand::StartApiKeySession {
            request_id,
            account_id,
            server_url,
            email,
            api_key,
        } => {
            start_api_key_session(
                request_id,
                account_id,
                server_url,
                email,
                api_key,
                account,
                event_sink,
                media_cache_root,
                cache,
            )
            .await;
        }
        CoreCommand::StartPasswordSession {
            request_id,
            account_id,
            server_url,
            username,
            password,
        } => {
            start_password_session(
                request_id,
                account_id,
                server_url,
                username,
                password,
                account,
                event_sink,
                media_cache_root,
                cache,
            )
            .await;
        }
        CoreCommand::LoadCachedSession {
            request_id,
            account_id,
        } => load_cached_session(request_id, &account_id, cache, event_sink),
        CoreCommand::SaveDraft { key, content, .. } => save_draft(&key, &content, cache),
        CoreCommand::LoadDrafts {
            request_id,
            account_id,
        } => load_drafts(request_id, &account_id, cache, event_sink),
        CoreCommand::OpenConversation {
            request_id,
            key,
            limit,
        } => open_conversation(request_id, key, limit, account.as_ref(), cache, event_sink).await,
        CoreCommand::LoadOlderMessages {
            request_id,
            key,
            before_message_id,
            limit,
        } => {
            load_older_messages(
                request_id,
                key,
                before_message_id,
                limit,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::SearchMessages {
            request_id,
            account_id,
            query,
            limit,
        } => {
            search_messages(
                request_id,
                &account_id,
                &query,
                limit,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::OpenMessage {
            request_id,
            key,
            message_id,
            num_before,
            num_after,
        } => {
            open_message(
                request_id,
                key,
                message_id,
                num_before,
                num_after,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::SendChannelMessage {
            request_id,
            account_id,
            stream_id,
            topic,
            content,
            local_id,
        } => {
            send_message(
                request_id,
                &account_id,
                OutgoingMessage::Channel {
                    stream_id,
                    topic,
                    content,
                },
                local_id,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::SendDirectMessage {
            request_id,
            account_id,
            recipient_ids,
            content,
            local_id,
        } => {
            send_message(
                request_id,
                &account_id,
                OutgoingMessage::Direct {
                    recipient_ids,
                    content,
                },
                local_id,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::EditMessage {
            request_id,
            account_id,
            message_id,
            content,
        } => {
            edit_message(
                request_id,
                &account_id,
                message_id,
                content,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::DeleteMessage {
            request_id,
            account_id,
            message_id,
        } => {
            delete_message(
                request_id,
                &account_id,
                message_id,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::UpdateReaction {
            request_id,
            account_id,
            message_id,
            emoji_name,
            add,
        } => {
            update_reaction(
                request_id,
                &account_id,
                message_id,
                emoji_name,
                add,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::UpdateMessageFlag {
            request_id,
            account_id,
            message_ids,
            flag,
            add,
        } => {
            update_message_flag(
                request_id,
                &account_id,
                message_ids,
                flag,
                add,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::RenameTopic {
            request_id,
            key,
            message_id,
            new_topic,
        } => {
            update_topic(
                request_id,
                key,
                message_id,
                new_topic,
                TopicPropagation::ChangeAll,
                account.as_mut(),
                event_sink,
            )
            .await;
        }
        CoreCommand::MoveMessageToTopic {
            request_id,
            key,
            message_id,
            new_topic,
        } => {
            update_topic(
                request_id,
                key,
                message_id,
                new_topic,
                TopicPropagation::ChangeOne,
                account.as_mut(),
                event_sink,
            )
            .await;
        }
        CoreCommand::UploadAttachment {
            request_id,
            account_id,
            local_path,
            filename,
        } => upload_attachment(
            request_id,
            account_id,
            local_path,
            filename,
            account.as_ref(),
            event_sink,
        ),
        CoreCommand::LoadMedia {
            request_id,
            account_id,
            remote_url,
        } => load_media(
            request_id,
            account_id,
            remote_url,
            account.as_ref(),
            event_sink,
        ),
        CoreCommand::MarkRead {
            request_id,
            account_id,
            message_ids,
        } => {
            mark_read(
                request_id,
                &account_id,
                message_ids,
                account.as_ref(),
                event_sink,
            )
            .await;
        }
        CoreCommand::Disconnect { request_id } => {
            disconnect(request_id, account, cache, event_sink);
        }
    }
}

fn upload_attachment(
    request_id: u64,
    account_id: String,
    local_path: String,
    filename: String,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    let media = Arc::clone(&session.media);
    let event_sink = Arc::clone(event_sink);
    tokio::spawn(async move {
        match media.upload_file(Path::new(&local_path), &filename).await {
            Ok(uploaded) => event_sink.handle_event(CoreEvent::AttachmentUploaded {
                request_id,
                account_id,
                filename: uploaded.filename,
                url: uploaded.url,
                markdown: uploaded.markdown,
            }),
            Err(error) => emit_error(Some(request_id), error, &event_sink),
        }
    });
}

fn load_media(
    request_id: u64,
    account_id: String,
    remote_url: String,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    let media = Arc::clone(&session.media);
    let event_sink = Arc::clone(event_sink);
    tokio::spawn(async move {
        match media.load_media(&remote_url).await {
            Ok(cached) => event_sink.handle_event(CoreEvent::MediaReady {
                request_id,
                account_id,
                remote_url: cached.remote_url,
                local_url: cached.local_url,
                content_type: cached.content_type,
                byte_count: cached.byte_count,
                cache_hit: cached.cache_hit,
            }),
            Err(error) => emit_error(Some(request_id), error, &event_sink),
        }
    });
}

async fn edit_message(
    request_id: u64,
    account_id: &str,
    message_id: i64,
    content: String,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session
        .messages
        .update_message_content(message_id, &content)
        .await
    {
        Ok(()) => event_sink.handle_event(CoreEvent::MessageEdited {
            request_id,
            message_id,
            content,
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

async fn delete_message(
    request_id: u64,
    account_id: &str,
    message_id: i64,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session.messages.delete_message(message_id).await {
        Ok(()) => event_sink.handle_event(CoreEvent::MessageDeleted {
            request_id,
            message_id,
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

#[allow(clippy::too_many_arguments)]
async fn update_reaction(
    request_id: u64,
    account_id: &str,
    message_id: i64,
    emoji_name: String,
    add: bool,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    let operation = if add {
        MessageWriteOperation::Add
    } else {
        MessageWriteOperation::Remove
    };
    match session
        .messages
        .update_reaction(message_id, &emoji_name, operation)
        .await
    {
        Ok(()) => event_sink.handle_event(CoreEvent::ReactionUpdated {
            request_id,
            message_id,
            emoji_name,
            added: add,
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

#[allow(clippy::too_many_arguments)]
async fn update_message_flag(
    request_id: u64,
    account_id: &str,
    message_ids: Vec<i64>,
    flag: CoreMessageFlag,
    add: bool,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    let operation = if add {
        MessageWriteOperation::Add
    } else {
        MessageWriteOperation::Remove
    };
    match session
        .messages
        .update_message_flag(&message_ids, flag.into(), operation)
        .await
    {
        Ok(()) => event_sink.handle_event(CoreEvent::MessageFlagUpdated {
            request_id,
            message_ids,
            flag,
            added: add,
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

fn disconnect(
    request_id: u64,
    account: &mut Option<AccountSession>,
    cache: &CacheHandle,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    if let Some(session) = account.as_ref() {
        let account_id = session.account_id.clone();
        cache.with(|database| database.delete_account_cache(&account_id));
    }
    *account = None;
    event_sink.handle_event(CoreEvent::Disconnected { request_id });
}

async fn load_older_messages(
    request_id: u64,
    key: CoreConversationKey,
    before_message_id: i64,
    limit: u16,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == key.account_id()) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session
        .messages
        .fetch_older_messages(key.target(), before_message_id, limit)
        .await
    {
        Ok(page) => event_sink.handle_event(CoreEvent::ConversationHistoryLoaded {
            request_id,
            page: CoreConversationPage {
                key,
                messages: page.messages.into_iter().map(Into::into).collect(),
                found_oldest: page.found_oldest,
                found_newest: page.found_newest,
            },
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

async fn search_messages(
    request_id: u64,
    account_id: &str,
    query: &str,
    limit: u16,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session.messages.search_messages(query, limit).await {
        Ok(messages) => {
            let results = messages
                .into_iter()
                .map(|message| CoreSearchResult {
                    key: conversation_key_for_message(
                        &session.account_id,
                        session.own_user_id,
                        &message,
                    ),
                    message: message.into(),
                })
                .collect();
            event_sink.handle_event(CoreEvent::SearchCompleted {
                request_id,
                account_id: account_id.to_owned(),
                results,
            });
        }
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

#[allow(clippy::too_many_arguments)]
async fn open_message(
    request_id: u64,
    key: CoreConversationKey,
    message_id: i64,
    num_before: u16,
    num_after: u16,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == key.account_id()) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session
        .messages
        .fetch_message_context(key.target(), message_id, num_before, num_after)
        .await
    {
        Ok(page) => event_sink.handle_event(CoreEvent::MessageFocused {
            request_id,
            message_id,
            page: CoreConversationPage {
                key,
                messages: page.messages.into_iter().map(Into::into).collect(),
                found_oldest: page.found_oldest,
                found_newest: page.found_newest,
            },
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

fn conversation_key_for_message(
    account_id: &str,
    own_user_id: i64,
    message: &MessageSummary,
) -> CoreConversationKey {
    if let Some(stream_id) = message.stream_id {
        if let Some(topic) = &message.topic {
            return CoreConversationKey::Topic {
                account_id: account_id.to_owned(),
                stream_id,
                topic: topic.clone(),
            };
        }
        return CoreConversationKey::Channel {
            account_id: account_id.to_owned(),
            stream_id,
        };
    }

    let mut recipient_ids = message.recipient_ids.clone();
    recipient_ids.retain(|user_id| *user_id > 0 && *user_id != own_user_id);
    recipient_ids.sort_unstable();
    recipient_ids.dedup();
    if recipient_ids.is_empty() {
        recipient_ids.push(own_user_id);
    }
    CoreConversationKey::DirectMessage {
        account_id: account_id.to_owned(),
        recipient_ids,
    }
}

async fn open_conversation(
    request_id: u64,
    key: CoreConversationKey,
    limit: u16,
    account: Option<&AccountSession>,
    cache: &CacheHandle,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == key.account_id()) else {
        // No live session: serve the last cached copy so reading works offline.
        if !emit_cached_conversation(request_id, &key, cache, event_sink) {
            emit_no_session(request_id, event_sink);
        }
        return;
    };
    match session
        .messages
        .fetch_conversation(key.target(), limit)
        .await
    {
        Ok(page) => {
            let cached = CachedConversation {
                messages: page.messages.clone(),
                found_oldest: page.found_oldest,
                found_newest: page.found_newest,
            };
            session.cache.with(|database| {
                database.save_conversation(
                    key.account_id(),
                    &key.cache_key(),
                    &cached,
                    now_timestamp(),
                )
            });
            event_sink.handle_event(CoreEvent::ConversationOpened {
                request_id,
                page: CoreConversationPage {
                    key,
                    messages: page.messages.into_iter().map(Into::into).collect(),
                    found_oldest: page.found_oldest,
                    found_newest: page.found_newest,
                },
            });
        }
        Err(error) => {
            // A network failure should not blank a conversation we already have.
            if !emit_cached_conversation(request_id, &key, cache, event_sink) {
                emit_error(Some(request_id), error, event_sink);
            }
        }
    }
}

/// Emits the cached copy of `key`; returns whether one existed.
fn emit_cached_conversation(
    request_id: u64,
    key: &CoreConversationKey,
    cache: &CacheHandle,
    event_sink: &Arc<dyn CoreEventSink>,
) -> bool {
    let Some(cached) = cache
        .with(|database| database.conversation(key.account_id(), &key.cache_key()))
        .flatten()
    else {
        return false;
    };
    event_sink.handle_event(CoreEvent::ConversationOpened {
        request_id,
        page: CoreConversationPage {
            key: key.clone(),
            messages: cached.messages.into_iter().map(Into::into).collect(),
            found_oldest: cached.found_oldest,
            found_newest: cached.found_newest,
        },
    });
    true
}

async fn send_message(
    request_id: u64,
    account_id: &str,
    outgoing: OutgoingMessage,
    local_id: String,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    let queue_id = session.sync.queue().id.clone();
    let result = session
        .messages
        .send_message(outgoing, Some((&queue_id, &local_id)))
        .await;
    emit_send_result(result, request_id, local_id, event_sink);
}

async fn update_topic(
    request_id: u64,
    key: CoreConversationKey,
    message_id: i64,
    new_topic: String,
    propagation: TopicPropagation,
    account: Option<&mut AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let CoreConversationKey::Topic {
        account_id,
        stream_id,
        topic: old_topic,
    } = key
    else {
        emit_error(
            Some(request_id),
            zulip_core::messages::MessageApiError::InvalidInput,
            event_sink,
        );
        return;
    };
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    let new_topic = new_topic.trim().to_owned();
    match session
        .messages
        .update_message_topic(message_id, &new_topic, propagation)
        .await
    {
        Ok(()) => {
            if propagation == TopicPropagation::ChangeAll {
                let mut renamed = false;
                for topic in &mut session.topics {
                    if topic.stream_id == stream_id && topic.name == old_topic {
                        topic.name.clone_from(&new_topic);
                        topic.max_message_id = topic.max_message_id.max(message_id);
                        renamed = true;
                    }
                }
                if !renamed {
                    session.topics.push(TopicSummary {
                        stream_id,
                        name: new_topic.clone(),
                        max_message_id: message_id,
                    });
                }
            } else {
                session.topics.push(TopicSummary {
                    stream_id,
                    name: new_topic.clone(),
                    max_message_id: message_id,
                });
            }
            normalize_topics(&mut session.topics);
            event_sink.handle_event(CoreEvent::TopicUpdated {
                request_id,
                account_id,
                stream_id,
                old_topic,
                new_topic,
                message_id,
                propagation: match propagation {
                    TopicPropagation::ChangeOne => CoreTopicPropagation::ChangeOne,
                    TopicPropagation::ChangeAll => CoreTopicPropagation::ChangeAll,
                },
            });
        }
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

fn normalize_topics(topics: &mut Vec<TopicSummary>) {
    topics.sort_by(|left, right| {
        left.stream_id
            .cmp(&right.stream_id)
            .then_with(|| left.name.cmp(&right.name))
            .then_with(|| right.max_message_id.cmp(&left.max_message_id))
    });
    topics.dedup_by(|left, right| left.stream_id == right.stream_id && left.name == right.name);
    topics.sort_by(|left, right| {
        left.stream_id
            .cmp(&right.stream_id)
            .then_with(|| right.max_message_id.cmp(&left.max_message_id))
            .then_with(|| left.name.cmp(&right.name))
    });
}

async fn mark_read(
    request_id: u64,
    account_id: &str,
    message_ids: Vec<i64>,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == account_id) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session.messages.mark_read(&message_ids).await {
        Ok(()) => event_sink.handle_event(CoreEvent::MessagesMarkedRead {
            request_id,
            message_ids,
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

fn emit_pong(request_id: u64, payload: &str, event_sink: &Arc<dyn CoreEventSink>) {
    let identity = zulip_core::identity();
    event_sink.handle_event(CoreEvent::Pong {
        request_id,
        message: format!(
            "{} {} received: {}",
            identity.name, identity.version, payload
        ),
    });
}

#[allow(clippy::too_many_arguments)]
async fn start_api_key_session(
    request_id: u64,
    account_id: String,
    server_url: String,
    email: String,
    api_key: String,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
    media_cache_root: &Path,
    cache: &CacheHandle,
) {
    let authentication = match AuthenticationClient::new() {
        Ok(client) => client,
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    let authenticated = match authentication
        .authenticate_with_api_key(&server_url, &email, SecretString::new(api_key))
        .await
    {
        Ok(authenticated) => authenticated,
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    start_authenticated_session(
        request_id,
        account_id,
        authenticated,
        account,
        event_sink,
        media_cache_root,
        cache,
    )
    .await;
}

#[allow(clippy::too_many_arguments)]
async fn start_password_session(
    request_id: u64,
    account_id: String,
    server_url: String,
    username: String,
    password: String,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
    media_cache_root: &Path,
    cache: &CacheHandle,
) {
    let authentication = match AuthenticationClient::new() {
        Ok(client) => client,
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    let authenticated = match authentication
        .authenticate_with_password(&server_url, &username, SecretString::new(password))
        .await
    {
        Ok(authenticated) => authenticated,
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    start_authenticated_session(
        request_id,
        account_id,
        authenticated,
        account,
        event_sink,
        media_cache_root,
        cache,
    )
    .await;
}

async fn start_authenticated_session(
    request_id: u64,
    account_id: String,
    authenticated: AuthenticatedAccount,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
    media_cache_root: &Path,
    cache: &CacheHandle,
) {
    let api_key = authenticated.api_key.expose_secret().to_owned();
    start_session(
        request_id,
        account_id,
        authenticated.server_url,
        authenticated.email,
        authenticated.user_id,
        authenticated.full_name,
        api_key,
        account,
        event_sink,
        media_cache_root,
        cache,
    )
    .await;
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
async fn start_session(
    request_id: u64,
    account_id: String,
    server_url: String,
    email: String,
    user_id: i64,
    full_name: String,
    api_key: String,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
    media_cache_root: &Path,
    cache: &CacheHandle,
) {
    if account_id.trim().is_empty() || user_id <= 0 {
        event_sink.handle_event(CoreEvent::Failed {
            request_id: Some(request_id),
            message: "enter valid account details".to_owned(),
        });
        return;
    }
    let sync_client = match EventQueueClient::new(
        &server_url,
        email.clone(),
        SecretString::new(api_key.clone()),
    ) {
        Ok(client) => client,
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    let messages = match MessageClient::new(
        &server_url,
        email.clone(),
        SecretString::new(api_key.clone()),
    ) {
        Ok(client) => Arc::new(client),
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    let media = match MediaClient::new(
        &server_url,
        email.clone(),
        SecretString::new(api_key.clone()),
        media_cache_root,
        &account_id,
    ) {
        Ok(client) => Arc::new(client),
        Err(error) => {
            emit_error(Some(request_id), error, event_sink);
            return;
        }
    };
    match SyncSession::start(sync_client, RecoveryPolicy::default(), request_id).await {
        Ok((sync, snapshot)) => {
            let mut topics = Vec::new();
            for channels in snapshot.channels.chunks(6) {
                let mut topic_tasks = JoinSet::new();
                for channel in channels {
                    let messages = Arc::clone(&messages);
                    let stream_id = channel.id;
                    topic_tasks.spawn(async move { messages.fetch_topics(stream_id).await });
                }
                while let Some(result) = topic_tasks.join_next().await {
                    if let Ok(Ok(mut channel_topics)) = result {
                        topics.append(&mut channel_topics);
                    }
                }
            }
            topics.sort_by(|left, right| {
                left.stream_id
                    .cmp(&right.stream_id)
                    .then_with(|| right.max_message_id.cmp(&left.max_message_id))
                    .then_with(|| left.name.cmp(&right.name))
            });
            topics.dedup_by(|left, right| {
                left.stream_id == right.stream_id && left.name == right.name
            });
            cache_snapshot(
                cache,
                &account_id,
                &CachedAccount {
                    server_url: server_url.clone(),
                    email: email.clone(),
                    user_id,
                    full_name: full_name.clone(),
                },
                &snapshot,
                &topics,
            );
            let bridge_snapshot = CoreSnapshot::from_sync(snapshot, &topics);
            *account = Some(AccountSession {
                account_id: account_id.clone(),
                own_user_id: user_id,
                messages,
                media,
                sync,
                topics,
                cache: cache.clone(),
                last_snapshot_cache_seconds: AtomicU64::new(now_seconds()),
            });
            event_sink.handle_event(CoreEvent::SessionStarted {
                request_id,
                account_id,
                server_url,
                email,
                user_id,
                full_name,
                credential: CoreSessionCredential { api_key },
                snapshot: bridge_snapshot,
            });
        }
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

fn emit_send_result(
    result: Result<i64, zulip_core::messages::MessageApiError>,
    request_id: u64,
    local_id: String,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    match result {
        Ok(message_id) => event_sink.handle_event(CoreEvent::MessageSent {
            request_id,
            local_id,
            message_id,
        }),
        Err(error) => emit_error(Some(request_id), error, event_sink),
    }
}

fn handle_sync_cycle(
    cycle: SyncCycle,
    account: Option<&AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) -> Instant {
    let Some(account) = account else {
        return Instant::now();
    };
    match cycle {
        SyncCycle::Events(outcome) => {
            if let Some(snapshot) = outcome.snapshot {
                cache_snapshot_throttled(account, &snapshot);
                event_sink.handle_event(CoreEvent::SnapshotUpdated {
                    account_id: account.account_id.clone(),
                    snapshot: CoreSnapshot::from_sync(snapshot, &account.topics),
                });
            }
            Instant::now()
        }
        SyncCycle::Resynchronized { snapshot, .. } => {
            cache_snapshot_throttled(account, &snapshot);
            event_sink.handle_event(CoreEvent::SnapshotUpdated {
                account_id: account.account_id.clone(),
                snapshot: CoreSnapshot::from_sync(snapshot, &account.topics),
            });
            Instant::now()
        }
        SyncCycle::RetryAfter { delay, .. } => {
            event_sink.handle_event(CoreEvent::RetryScheduled {
                account_id: account.account_id.clone(),
                delay_milliseconds: duration_milliseconds(delay),
            });
            Instant::now() + delay
        }
        SyncCycle::Fatal { error } => {
            emit_error(None, error, event_sink);
            Instant::now() + Duration::from_secs(30)
        }
    }
}

fn cached_snapshot(snapshot: &SyncSnapshot, topics: &[TopicSummary]) -> CachedSnapshot {
    CachedSnapshot {
        users: snapshot.users.clone(),
        channels: snapshot.channels.clone(),
        topics: topics.to_vec(),
        messages: snapshot.messages.clone(),
    }
}

fn cache_snapshot(
    cache: &CacheHandle,
    account_id: &str,
    identity: &CachedAccount,
    snapshot: &SyncSnapshot,
    topics: &[TopicSummary],
) {
    let cached = cached_snapshot(snapshot, topics);
    cache.with(|database| {
        database.save_account_cache(account_id, identity, &cached, now_timestamp())
    });
}

/// Persists busy-stream snapshots at most once per interval.
fn cache_snapshot_throttled(account: &AccountSession, snapshot: &SyncSnapshot) {
    let now = now_seconds();
    let previous = account.last_snapshot_cache_seconds.load(Ordering::Relaxed);
    if now.saturating_sub(previous) < SNAPSHOT_CACHE_INTERVAL_SECONDS {
        return;
    }
    account
        .last_snapshot_cache_seconds
        .store(now, Ordering::Relaxed);
    let cached = cached_snapshot(snapshot, &account.topics);
    account
        .cache
        .with(|database| database.save_snapshot(&account.account_id, &cached, now_timestamp()));
}

fn save_draft(key: &CoreConversationKey, content: &str, cache: &CacheHandle) {
    let account_id = key.account_id();
    let draft_id = key.cache_key();
    if content.trim().is_empty() {
        cache.with(|database| database.delete_draft(account_id, &draft_id));
        return;
    }
    cache.with(|database| {
        database.save_draft(&DraftRecord {
            account_id: account_id.to_owned(),
            draft_id: draft_id.clone(),
            conversation_key: draft_id,
            content: content.to_owned(),
            updated_at: now_timestamp(),
        })
    });
}

fn load_drafts(
    request_id: u64,
    account_id: &str,
    cache: &CacheHandle,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let drafts = cache
        .with(|database| database.drafts(account_id))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|draft| {
            Some(CoreDraft {
                key: CoreConversationKey::from_cache_key(account_id, &draft.conversation_key)?,
                content: draft.content,
            })
        })
        .collect();
    event_sink.handle_event(CoreEvent::DraftsLoaded {
        request_id,
        account_id: account_id.to_owned(),
        drafts,
    });
}

fn load_cached_session(
    request_id: u64,
    account_id: &str,
    cache: &CacheHandle,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some((identity, cached)) = cache
        .with(|database| database.account_cache(account_id))
        .flatten()
    else {
        event_sink.handle_event(CoreEvent::Failed {
            request_id: Some(request_id),
            message: "no cached data is available for this account".to_owned(),
        });
        return;
    };
    let snapshot = SyncSnapshot {
        revision: 0,
        last_event_id: -1,
        users: cached.users,
        channels: cached.channels,
        messages: cached.messages,
    };
    event_sink.handle_event(CoreEvent::CachedSessionLoaded {
        request_id,
        account_id: account_id.to_owned(),
        server_url: identity.server_url,
        email: identity.email,
        user_id: identity.user_id,
        full_name: identity.full_name,
        snapshot: CoreSnapshot::from_sync(snapshot, &cached.topics),
    });
}

fn duration_milliseconds(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

fn emit_no_session(request_id: u64, event_sink: &Arc<dyn CoreEventSink>) {
    event_sink.handle_event(CoreEvent::Failed {
        request_id: Some(request_id),
        message: "no matching live account session".to_owned(),
    });
}

fn emit_error(
    request_id: Option<u64>,
    error: impl std::fmt::Display,
    event_sink: &Arc<dyn CoreEventSink>,
) {
    event_sink.handle_event(CoreEvent::Failed {
        request_id,
        message: error.to_string(),
    });
}

impl From<UserSummary> for CoreUser {
    fn from(user: UserSummary) -> Self {
        Self {
            user_id: user.id,
            full_name: user.full_name,
            email: user.email,
            is_active: user.is_active,
            is_bot: user.is_bot,
        }
    }
}

impl From<MessageSummary> for CoreMessage {
    fn from(message: MessageSummary) -> Self {
        let content = parse_zulip_html(&message.content_html)
            .into_iter()
            .map(CoreContentBlock::from)
            .collect();
        Self {
            message_id: message.id,
            sender_id: message.sender_id,
            sender_full_name: message.sender_full_name,
            timestamp: message.timestamp,
            content,
            stream_id: message.stream_id,
            topic: message.topic,
            recipient_ids: message.recipient_ids,
            flags: message.flags,
            reactions: message
                .reactions
                .into_iter()
                .map(|reaction| CoreReaction {
                    emoji_name: reaction.emoji_name,
                    user_id: reaction.user_id,
                })
                .collect(),
        }
    }
}

impl From<NativeInlineContent> for CoreInlineContent {
    fn from(content: NativeInlineContent) -> Self {
        match content {
            NativeInlineContent::Text(value) => Self::Text { value },
            NativeInlineContent::Link { label, url } => Self::Link { label, url },
            NativeInlineContent::Mention {
                display_name,
                user_id,
            } => Self::Mention {
                display_name,
                user_id,
            },
            NativeInlineContent::Emoji { name, value } => Self::Emoji { name, value },
        }
    }
}

impl From<NativeContentBlock> for CoreContentBlock {
    fn from(block: NativeContentBlock) -> Self {
        match block {
            NativeContentBlock::Paragraph(content) => Self::Paragraph {
                content: content.into_iter().map(CoreInlineContent::from).collect(),
            },
            NativeContentBlock::Quote(blocks) => Self::Quote {
                blocks: blocks.into_iter().map(Self::from).collect(),
            },
            NativeContentBlock::List { items, ordered } => Self::List {
                items: items
                    .into_iter()
                    .map(|blocks| CoreContentListItem {
                        blocks: blocks.into_iter().map(Self::from).collect(),
                    })
                    .collect(),
                ordered,
            },
            NativeContentBlock::Code { language, value } => Self::Code { language, value },
            NativeContentBlock::Image {
                url,
                alt,
                width,
                height,
            } => Self::Image {
                url,
                alt,
                width,
                height,
            },
            NativeContentBlock::Unsupported { summary } => Self::Unsupported { summary },
        }
    }
}

impl CoreSnapshot {
    fn from_sync(snapshot: SyncSnapshot, topics: &[TopicSummary]) -> Self {
        Self {
            revision: snapshot.revision,
            last_event_id: snapshot.last_event_id,
            users: snapshot.users.into_iter().map(Into::into).collect(),
            channels: snapshot
                .channels
                .into_iter()
                .map(|channel| CoreChannel {
                    stream_id: channel.id,
                    name: channel.name,
                    color: channel.color,
                    is_muted: channel.is_muted,
                })
                .collect(),
            topics: topics.iter().cloned().map(Into::into).collect(),
            messages: snapshot.messages.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<TopicSummary> for CoreTopic {
    fn from(topic: TopicSummary) -> Self {
        Self {
            stream_id: topic.stream_id,
            name: topic.name,
            max_message_id: topic.max_message_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{Arc, Mutex, mpsc},
        thread,
        time::{Duration, Instant as StdInstant},
    };

    use super::{
        CoreCommand, CoreContentBlock, CoreConversationKey, CoreEvent, CoreEventSink,
        CoreInlineContent, CoreMessage, CoreMessageFlag, CoreSnapshot, CoreTopicPropagation,
        RustCoreClient, conversation_key_for_message,
    };
    use tempfile::TempDir;
    use zulip_core::{
        messages::{ConversationTarget, TopicSummary},
        sync::{MessageSummary, SyncSnapshot},
    };

    #[derive(Default)]
    struct RecordingSink {
        events: Mutex<Vec<CoreEvent>>,
        notifier: Mutex<Option<mpsc::Sender<()>>>,
    }

    impl CoreEventSink for RecordingSink {
        fn handle_event(&self, event: CoreEvent) {
            self.events.lock().expect("event lock poisoned").push(event);
            if let Some(sender) = self
                .notifier
                .lock()
                .expect("notifier lock poisoned")
                .as_ref()
            {
                let _ = sender.send(());
            }
        }
    }

    #[test]
    fn command_emits_correlated_event_from_actor() {
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone(), "/tmp/zulip-ffi-tests".to_owned(), None);

        client.submit(CoreCommand::Ping {
            request_id: 42,
            payload: "ping".to_owned(),
        });
        signal_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("actor event");

        let events = sink.events.lock().expect("event lock poisoned");
        assert!(matches!(
            &events[0],
            CoreEvent::Pong {
                request_id: 42,
                message
            } if message.ends_with("received: ping")
        ));
    }

    #[test]
    fn browsing_keys_and_topics_cross_the_boundary_without_transport_types() {
        for (key, target) in [
            (
                CoreConversationKey::Mentions {
                    account_id: "account-1".to_owned(),
                },
                ConversationTarget::Mentions,
            ),
            (
                CoreConversationKey::Starred {
                    account_id: "account-1".to_owned(),
                },
                ConversationTarget::Starred,
            ),
            (
                CoreConversationKey::Unread {
                    account_id: "account-1".to_owned(),
                },
                ConversationTarget::Unread,
            ),
        ] {
            assert_eq!(key.account_id(), "account-1");
            assert_eq!(key.target(), target);
        }

        let snapshot = CoreSnapshot::from_sync(
            SyncSnapshot {
                revision: 2,
                last_event_id: 10,
                users: Vec::new(),
                channels: Vec::new(),
                messages: Vec::new(),
            },
            &[TopicSummary {
                stream_id: 5,
                name: "macOS".to_owned(),
                max_message_id: 44,
            }],
        );
        assert_eq!(snapshot.topics.len(), 1);
        assert_eq!(snapshot.topics[0].stream_id, 5);
        assert_eq!(snapshot.topics[0].name, "macOS");
        assert_eq!(snapshot.topics[0].max_message_id, 44);
    }

    #[test]
    fn search_results_map_to_stable_account_scoped_conversations() {
        let topic_message = MessageSummary {
            id: 42,
            sender_id: 9,
            sender_full_name: "Maya Chen".to_owned(),
            timestamp: 1_770_000_000,
            content_html: "<p>Search</p>".to_owned(),
            stream_id: Some(5),
            topic: Some("Rust core".to_owned()),
            recipient_ids: Vec::new(),
            flags: vec!["read".to_owned()],
            reactions: Vec::new(),
        };
        assert_eq!(
            conversation_key_for_message("account-1", 9, &topic_message),
            CoreConversationKey::Topic {
                account_id: "account-1".to_owned(),
                stream_id: 5,
                topic: "Rust core".to_owned(),
            }
        );

        let group_direct_message = MessageSummary {
            stream_id: None,
            topic: None,
            recipient_ids: vec![11, 9, 10, 11],
            ..topic_message.clone()
        };
        assert_eq!(
            conversation_key_for_message("account-1", 9, &group_direct_message),
            CoreConversationKey::DirectMessage {
                account_id: "account-1".to_owned(),
                recipient_ids: vec![10, 11],
            }
        );

        let self_direct_message = MessageSummary {
            recipient_ids: vec![9],
            ..group_direct_message
        };
        assert_eq!(
            conversation_key_for_message("account-1", 9, &self_direct_message),
            CoreConversationKey::DirectMessage {
                account_id: "account-1".to_owned(),
                recipient_ids: vec![9],
            }
        );
    }

    #[test]
    fn message_content_maps_to_sanitized_typed_blocks() {
        let message = MessageSummary {
            id: 42,
            sender_id: 9,
            sender_full_name: "Maya Chen".to_owned(),
            timestamp: 1_770_000_000,
            content_html: r#"<p>Hello <a href="https://zulip.com">Zulip</a>
                <span class="user-mention" data-user-id="42">@Maya</span>
                <span class="emoji emoji-1f44b" title="wave">:wave:</span>
                <a href="javascript:alert(1)">unsafe label</a></p>
                <blockquote><p>Quoted</p></blockquote>
                <ul><li>First</li></ul>
                <div class="codehilite" data-code-language="rust"><pre>fn main() {}</pre></div>
                <div class="message_inline_image"><img src="/user_uploads/image.png"
                    alt="Preview" data-original-dimensions="640x360"></div>
                <script>unsafe()</script>"#
                .to_owned(),
            stream_id: Some(5),
            topic: Some("Rust core".to_owned()),
            recipient_ids: Vec::new(),
            flags: vec!["read".to_owned()],
            reactions: Vec::new(),
        };

        let mapped = CoreMessage::from(message);
        let CoreContentBlock::Paragraph { content } = &mapped.content[0] else {
            panic!("expected a paragraph, got {:?}", mapped.content);
        };
        assert!(content.iter().any(|item| matches!(
            item,
            CoreInlineContent::Link { label, url }
                if label == "Zulip" && url == "https://zulip.com"
        )));
        assert!(content.iter().any(|item| matches!(
            item,
            CoreInlineContent::Mention { display_name, user_id: 42 }
                if display_name == "Maya"
        )));
        assert!(content.iter().any(|item| matches!(
            item,
            CoreInlineContent::Emoji { name, value }
                if name == "wave" && value == ":wave:"
        )));
        assert!(content.iter().any(|item| matches!(
            item,
            CoreInlineContent::Text { value } if value.contains("unsafe label")
        )));
        assert!(
            mapped
                .content
                .iter()
                .any(|block| matches!(block, CoreContentBlock::Quote { .. }))
        );
        assert!(
            mapped
                .content
                .iter()
                .any(|block| matches!(block, CoreContentBlock::List { .. }))
        );
        assert!(mapped.content.iter().any(|block| matches!(
            block,
            CoreContentBlock::Code { language: Some(language), value }
                if language == "rust" && value == "fn main() {}"
        )));
        assert!(mapped.content.iter().any(|block| matches!(
            block,
            CoreContentBlock::Image {
                url,
                alt,
                width: Some(640),
                height: Some(360),
            } if url == "/user_uploads/image.png" && alt == "Preview"
        )));
        assert!(
            mapped
                .content
                .iter()
                .any(|block| matches!(block, CoreContentBlock::Unsupported { .. }))
        );
        assert!(!format!("{:?}", mapped.content).contains("javascript:"));
    }

    #[test]
    fn actor_searches_and_focuses_a_correlated_result() {
        let (server, requests) = spawn_search_actor_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone(), "/tmp/zulip-ffi-tests".to_owned(), None);

        client.submit(CoreCommand::StartApiKeySession {
            request_id: 20,
            account_id: "account-search".to_owned(),
            server_url: server,
            email: "maya@example.com".to_owned(),
            api_key: "fixture-key-do-not-log".to_owned(),
        });
        let _ = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::SessionStarted { request_id: 20, .. })
        });

        client.submit(CoreCommand::SearchMessages {
            request_id: 21,
            account_id: "account-search".to_owned(),
            query: "native macOS".to_owned(),
            limit: 20,
        });
        let search = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::SearchCompleted { request_id: 21, .. })
        });
        let CoreEvent::SearchCompleted {
            account_id,
            results,
            ..
        } = search
        else {
            unreachable!("search predicate only accepts search events");
        };
        assert_eq!(account_id, "account-search");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].message.message_id, 50);
        assert_eq!(
            results[0].key,
            CoreConversationKey::Topic {
                account_id: "account-search".to_owned(),
                stream_id: 5,
                topic: "macOS".to_owned(),
            }
        );

        client.submit(CoreCommand::OpenMessage {
            request_id: 22,
            key: results[0].key.clone(),
            message_id: 50,
            num_before: 10,
            num_after: 10,
        });
        let focused = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::MessageFocused { request_id: 22, .. })
        });
        assert!(matches!(
            focused,
            CoreEvent::MessageFocused {
                message_id: 50,
                page,
                ..
            } if page.messages.iter().any(|message| message.message_id == 50)
        ));

        let observed = requests.try_iter().collect::<Vec<_>>();
        assert!(observed.iter().any(|request| {
            request.starts_with("GET /api/v1/messages?")
                && request.contains("%22operator%22%3A%22search%22")
        }));
        assert!(observed.iter().any(|request| {
            request.starts_with("GET /api/v1/messages?") && request.contains("anchor=50")
        }));
    }

    #[test]
    fn actor_renames_topics_and_moves_one_message_with_correlated_events() {
        let (server, requests) = spawn_topic_actor_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone(), "/tmp/zulip-ffi-tests".to_owned(), None);
        client.submit(CoreCommand::StartApiKeySession {
            request_id: 30,
            account_id: "account-topic".to_owned(),
            server_url: server,
            email: "maya@example.com".to_owned(),
            api_key: "fixture-key-do-not-log".to_owned(),
        });
        let _ = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::SessionStarted { request_id: 30, .. })
        });

        client.submit(CoreCommand::RenameTopic {
            request_id: 31,
            key: CoreConversationKey::Topic {
                account_id: "account-topic".to_owned(),
                stream_id: 5,
                topic: "macOS".to_owned(),
            },
            message_id: 50,
            new_topic: "Native Mac".to_owned(),
        });
        let renamed = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::TopicUpdated { request_id: 31, .. })
        });
        assert!(matches!(
            renamed,
            CoreEvent::TopicUpdated {
                account_id,
                stream_id: 5,
                old_topic,
                new_topic,
                message_id: 50,
                propagation: CoreTopicPropagation::ChangeAll,
                ..
            } if account_id == "account-topic"
                && old_topic == "macOS"
                && new_topic == "Native Mac"
        ));

        client.submit(CoreCommand::MoveMessageToTopic {
            request_id: 32,
            key: CoreConversationKey::Topic {
                account_id: "account-topic".to_owned(),
                stream_id: 5,
                topic: "Native Mac".to_owned(),
            },
            message_id: 51,
            new_topic: "UI polish".to_owned(),
        });
        let moved = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::TopicUpdated { request_id: 32, .. })
        });
        assert!(matches!(
            moved,
            CoreEvent::TopicUpdated {
                old_topic,
                new_topic,
                propagation: CoreTopicPropagation::ChangeOne,
                ..
            } if old_topic == "Native Mac" && new_topic == "UI polish"
        ));

        let observed = requests.try_iter().collect::<Vec<_>>();
        assert!(observed.iter().any(|request| {
            request.starts_with("PATCH /api/v1/messages/50 HTTP/1.1")
                && request.contains("propagate_mode=change_all")
        }));
        assert!(observed.iter().any(|request| {
            request.starts_with("PATCH /api/v1/messages/51 HTTP/1.1")
                && request.contains("propagate_mode=change_one")
        }));
    }

    #[test]
    fn actor_correlates_daily_message_action_results() {
        let (server, requests) = spawn_message_action_actor_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone(), "/tmp/zulip-ffi-tests".to_owned(), None);
        client.submit(CoreCommand::StartApiKeySession {
            request_id: 40,
            account_id: "account-actions".to_owned(),
            server_url: server,
            email: "maya@example.com".to_owned(),
            api_key: "fixture-key-do-not-log".to_owned(),
        });
        let _ = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::SessionStarted { request_id: 40, .. })
        });

        client.submit(CoreCommand::EditMessage {
            request_id: 41,
            account_id: "account-actions".to_owned(),
            message_id: 50,
            content: "Edited content".to_owned(),
        });
        assert!(matches!(
            wait_for_event(&signal_receiver, &sink, |event| {
                matches!(event, CoreEvent::MessageEdited { request_id: 41, .. })
            }),
            CoreEvent::MessageEdited { message_id: 50, .. }
        ));

        client.submit(CoreCommand::UpdateReaction {
            request_id: 42,
            account_id: "account-actions".to_owned(),
            message_id: 50,
            emoji_name: "thumbs_up".to_owned(),
            add: true,
        });
        assert!(matches!(
            wait_for_event(&signal_receiver, &sink, |event| {
                matches!(event, CoreEvent::ReactionUpdated { request_id: 42, .. })
            }),
            CoreEvent::ReactionUpdated { added: true, .. }
        ));

        client.submit(CoreCommand::UpdateMessageFlag {
            request_id: 43,
            account_id: "account-actions".to_owned(),
            message_ids: vec![50],
            flag: CoreMessageFlag::Starred,
            add: true,
        });
        assert!(matches!(
            wait_for_event(&signal_receiver, &sink, |event| {
                matches!(event, CoreEvent::MessageFlagUpdated { request_id: 43, .. })
            }),
            CoreEvent::MessageFlagUpdated {
                flag: CoreMessageFlag::Starred,
                added: true,
                ..
            }
        ));

        client.submit(CoreCommand::UpdateMessageFlag {
            request_id: 44,
            account_id: "account-actions".to_owned(),
            message_ids: vec![50],
            flag: CoreMessageFlag::Read,
            add: false,
        });
        let _ = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::MessageFlagUpdated { request_id: 44, .. })
        });

        client.submit(CoreCommand::DeleteMessage {
            request_id: 45,
            account_id: "account-actions".to_owned(),
            message_id: 50,
        });
        let _ = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::MessageDeleted { request_id: 45, .. })
        });

        let observed = requests.try_iter().collect::<Vec<_>>();
        assert!(observed.iter().any(|request| {
            request.starts_with("PATCH /api/v1/messages/50 HTTP/1.1")
                && request.contains("content=Edited+content")
        }));
        assert!(observed.iter().any(|request| {
            request.starts_with("POST /api/v1/messages/50/reactions HTTP/1.1")
                && request.contains("emoji_name=thumbs_up")
        }));
        assert!(observed.iter().any(|request| {
            request.starts_with("POST /api/v1/messages/flags HTTP/1.1")
                && request.contains("flag=starred")
        }));
        assert!(
            observed
                .iter()
                .any(|request| { request.starts_with("DELETE /api/v1/messages/50 HTTP/1.1") })
        );
    }

    #[test]
    fn actor_correlates_attachment_upload_and_cached_media_results() {
        let (server, requests) = spawn_media_actor_mock();
        let fixture = TempDir::new().expect("media fixture directory");
        let selected_file = fixture.path().join("fixture image.png");
        std::fs::write(&selected_file, b"upload fixture").expect("write upload fixture");
        let cache_root = fixture.path().join("cache");
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(
            sink.clone(),
            cache_root.to_string_lossy().into_owned(),
            None,
        );
        client.submit(CoreCommand::StartApiKeySession {
            request_id: 50,
            account_id: "account-media".to_owned(),
            server_url: server,
            email: "maya@example.com".to_owned(),
            api_key: "fixture-key-do-not-log".to_owned(),
        });
        let _ = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::SessionStarted { request_id: 50, .. })
        });

        client.submit(CoreCommand::UploadAttachment {
            request_id: 51,
            account_id: "account-media".to_owned(),
            local_path: selected_file.to_string_lossy().into_owned(),
            filename: "fixture image.png".to_owned(),
        });
        let uploaded = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::AttachmentUploaded { request_id: 51, .. })
        });
        assert!(matches!(
            uploaded,
            CoreEvent::AttachmentUploaded {
                account_id,
                filename,
                url,
                markdown,
                ..
            } if account_id == "account-media"
                && filename == "fixture image.png"
                && url == "/user_uploads/1/ab/fixture-image.png"
                && markdown.contains("fixture image.png")
        ));

        client.submit(CoreCommand::LoadMedia {
            request_id: 52,
            account_id: "account-media".to_owned(),
            remote_url: "/user_uploads/1/ab/fixture-image.png".to_owned(),
        });
        let ready = wait_for_event(&signal_receiver, &sink, |event| {
            matches!(event, CoreEvent::MediaReady { request_id: 52, .. })
        });
        assert!(matches!(
            ready,
            CoreEvent::MediaReady {
                account_id,
                remote_url,
                local_url,
                byte_count: 13,
                cache_hit: false,
                ..
            } if account_id == "account-media"
                && remote_url == "/user_uploads/1/ab/fixture-image.png"
                && local_url.starts_with("file:///")
        ));

        let observed = requests.try_iter().collect::<Vec<_>>();
        assert!(observed.iter().any(|request| {
            request.starts_with("POST /api/v1/user_uploads HTTP/1.1")
                && request.contains("upload fixture")
        }));
        assert!(observed.iter().any(|request| {
            request.starts_with("GET /api/v1/user_uploads/1/ab/fixture-image.png HTTP/1.1")
        }));
        assert!(observed.iter().any(|request| {
            request.starts_with("GET /user_uploads/temporary/token/fixture-image.png HTTP/1.1")
                && !request.to_ascii_lowercase().contains("authorization:")
        }));
    }

    #[test]
    fn api_key_session_registers_off_the_calling_thread() {
        let (server, request) = spawn_register_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone(), "/tmp/zulip-ffi-tests".to_owned(), None);

        client.submit(CoreCommand::StartApiKeySession {
            request_id: 7,
            account_id: "account-1".to_owned(),
            server_url: server,
            email: "maya@example.com".to_owned(),
            api_key: "fixture-key-do-not-log".to_owned(),
        });
        signal_receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("session event");

        let events = sink.events.lock().expect("event lock poisoned");
        assert!(matches!(
            &events[0],
            CoreEvent::SessionStarted {
                request_id: 7,
                account_id,
                snapshot,
                ..
            } if account_id == "account-1"
                && snapshot.channels[0].name == "engineering"
                && snapshot.topics[0].name == "macOS"
        ));
        let own_user = request
            .recv_timeout(Duration::from_secs(1))
            .expect("own-user request");
        let register = request
            .recv_timeout(Duration::from_secs(1))
            .expect("register request");
        assert!(own_user.starts_with("GET /api/v1/users/me"));
        assert!(register.starts_with("POST /api/v1/register"));
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn cached_session_and_conversation_are_readable_without_a_live_session() {
        let (server, _requests) = spawn_search_actor_mock();
        let directory = TempDir::new().expect("temporary directory");
        let database_path = directory
            .path()
            .join("cache.sqlite")
            .to_string_lossy()
            .into_owned();
        let media_root = directory
            .path()
            .join("media")
            .to_string_lossy()
            .into_owned();
        let inbox = CoreConversationKey::Inbox {
            account_id: "account-search".to_owned(),
        };

        let (online_sender, online_receiver) = mpsc::channel();
        let online_sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(online_sender)),
        });
        let online = RustCoreClient::new(
            online_sink.clone(),
            media_root.clone(),
            Some(database_path.clone()),
        );
        online.submit(CoreCommand::StartApiKeySession {
            request_id: 30,
            account_id: "account-search".to_owned(),
            server_url: server,
            email: "maya@example.com".to_owned(),
            api_key: "fixture-key-do-not-log".to_owned(),
        });
        let _ = wait_for_event(&online_receiver, &online_sink, |event| {
            matches!(event, CoreEvent::SessionStarted { request_id: 30, .. })
        });
        online.submit(CoreCommand::OpenConversation {
            request_id: 31,
            key: inbox.clone(),
            limit: 20,
        });
        let _ = wait_for_event(&online_receiver, &online_sink, |event| {
            matches!(event, CoreEvent::ConversationOpened { request_id: 31, .. })
        });

        // A fresh process-like client with no network session reads the cache.
        let (offline_sender, offline_receiver) = mpsc::channel();
        let offline_sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(offline_sender)),
        });
        let offline = RustCoreClient::new(offline_sink.clone(), media_root, Some(database_path));
        offline.submit(CoreCommand::LoadCachedSession {
            request_id: 40,
            account_id: "account-search".to_owned(),
        });
        let loaded = wait_for_event(&offline_receiver, &offline_sink, |event| {
            matches!(event, CoreEvent::CachedSessionLoaded { request_id: 40, .. })
        });
        let CoreEvent::CachedSessionLoaded {
            email,
            full_name,
            snapshot,
            ..
        } = loaded
        else {
            unreachable!("matched above");
        };
        assert_eq!(email, "maya@example.com");
        assert_eq!(full_name, "Maya Chen");
        assert_eq!(snapshot.channels[0].name, "engineering");
        assert_eq!(snapshot.topics[0].name, "macOS");

        offline.submit(CoreCommand::OpenConversation {
            request_id: 41,
            key: inbox,
            limit: 20,
        });
        let opened = wait_for_event(&offline_receiver, &offline_sink, |event| {
            matches!(event, CoreEvent::ConversationOpened { request_id: 41, .. })
        });
        let CoreEvent::ConversationOpened { page, .. } = opened else {
            unreachable!("matched above");
        };
        assert_eq!(page.messages.len(), 1);
        assert_eq!(page.messages[0].message_id, 50);
        assert!(page.found_oldest);

        let draft_key = CoreConversationKey::Topic {
            account_id: "account-search".to_owned(),
            stream_id: 5,
            topic: "ship: v1".to_owned(),
        };
        offline.submit(CoreCommand::SaveDraft {
            request_id: 43,
            key: draft_key.clone(),
            content: "half-written reply".to_owned(),
        });
        offline.submit(CoreCommand::LoadDrafts {
            request_id: 44,
            account_id: "account-search".to_owned(),
        });
        let drafts = wait_for_event(&offline_receiver, &offline_sink, |event| {
            matches!(event, CoreEvent::DraftsLoaded { request_id: 44, .. })
        });
        let CoreEvent::DraftsLoaded { drafts, .. } = drafts else {
            unreachable!("matched above");
        };
        assert_eq!(drafts.len(), 1);
        assert_eq!(drafts[0].key, draft_key);
        assert_eq!(drafts[0].content, "half-written reply");

        offline.submit(CoreCommand::SaveDraft {
            request_id: 45,
            key: draft_key,
            content: "  \n".to_owned(),
        });
        offline.submit(CoreCommand::LoadDrafts {
            request_id: 46,
            account_id: "account-search".to_owned(),
        });
        let cleared = wait_for_event(&offline_receiver, &offline_sink, |event| {
            matches!(event, CoreEvent::DraftsLoaded { request_id: 46, .. })
        });
        assert!(matches!(
            cleared,
            CoreEvent::DraftsLoaded { drafts, .. } if drafts.is_empty()
        ));

        offline.submit(CoreCommand::LoadCachedSession {
            request_id: 42,
            account_id: "someone-else".to_owned(),
        });
        let missing = wait_for_event(&offline_receiver, &offline_sink, |event| {
            matches!(
                event,
                CoreEvent::Failed {
                    request_id: Some(42),
                    ..
                }
            )
        });
        assert!(matches!(missing, CoreEvent::Failed { .. }));
    }

    #[test]
    fn conversation_cache_keys_round_trip() {
        for key in [
            CoreConversationKey::Inbox {
                account_id: "a".to_owned(),
            },
            CoreConversationKey::Channel {
                account_id: "a".to_owned(),
                stream_id: 7,
            },
            CoreConversationKey::Topic {
                account_id: "a".to_owned(),
                stream_id: 7,
                topic: "a:b:c".to_owned(),
            },
            CoreConversationKey::DirectMessage {
                account_id: "a".to_owned(),
                recipient_ids: vec![3, 9],
            },
        ] {
            assert_eq!(
                CoreConversationKey::from_cache_key("a", &key.cache_key()),
                Some(key)
            );
        }
        assert_eq!(CoreConversationKey::from_cache_key("a", "bogus"), None);
    }

    #[test]
    fn password_session_exchanges_key_and_returns_redacted_credential() {
        let (server, requests) = spawn_password_session_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone(), "/tmp/zulip-ffi-tests".to_owned(), None);

        client.submit(CoreCommand::StartPasswordSession {
            request_id: 8,
            account_id: "account-2".to_owned(),
            server_url: server,
            username: "maya@example.com".to_owned(),
            password: "fixture-password-do-not-log".to_owned(),
        });
        signal_receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("session event");

        let events = sink.events.lock().expect("event lock poisoned");
        assert!(matches!(
            &events[0],
            CoreEvent::SessionStarted {
                request_id: 8,
                account_id,
                user_id: 9,
                full_name,
                credential,
                ..
            } if account_id == "account-2"
                && full_name == "Maya Chen"
                && credential.api_key == "derived-fixture-key"
        ));
        let debug = format!("{:?}", events[0]);
        assert!(!debug.contains("derived-fixture-key"));
        assert!(debug.contains("[REDACTED]"));

        let paths: Vec<String> = (0..3)
            .map(|_| {
                requests
                    .recv_timeout(Duration::from_secs(1))
                    .expect("authentication/register request")
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_owned()
            })
            .collect();
        assert!(paths[0].starts_with("POST /api/v1/fetch_api_key"));
        assert!(paths[1].starts_with("GET /api/v1/users/me"));
        assert!(paths[2].starts_with("POST /api/v1/register"));
    }

    fn spawn_register_mock() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let bodies = [
                r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":9}"#,
                r##"{
                    "result":"success",
                    "queue_id":"queue-1",
                    "last_event_id":10,
                    "event_queue_longpoll_timeout_seconds":5,
                    "zulip_feature_level":481,
                    "realm_users":[],
                    "subscriptions":[{
                        "stream_id":5,
                        "name":"engineering",
                        "color":"#76ce90",
                        "is_muted":false
                    }]
                }"##,
                r#"{"result":"success","topics":[{"max_id":44,"name":"macOS"}]}"#,
            ];
            for body in bodies {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let _ = sender.send(request);
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
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

    fn spawn_search_actor_mock() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut focused = false;
            while !focused {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let request_line = request.lines().next().unwrap_or_default();
                if request_line.is_empty() {
                    continue;
                }
                let _ = sender.send(request.clone());
                let body = if request_line.starts_with("GET /api/v1/users/me HTTP") {
                    r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":9}"#
                } else if request_line.starts_with("POST /api/v1/register HTTP") {
                    r##"{
                        "result":"success",
                        "queue_id":"queue-search",
                        "last_event_id":10,
                        "event_queue_longpoll_timeout_seconds":5,
                        "zulip_feature_level":481,
                        "realm_users":[],
                        "subscriptions":[{
                            "stream_id":5,
                            "name":"engineering",
                            "color":"#76ce90",
                            "is_muted":false
                        }]
                    }"##
                } else if request_line.starts_with("GET /api/v1/users/me/5/topics?") {
                    r#"{"result":"success","topics":[{"max_id":50,"name":"macOS"}]}"#
                } else if request_line.starts_with("GET /api/v1/events?") {
                    thread::sleep(Duration::from_millis(10));
                    r#"{"result":"success","events":[{"id":11,"type":"heartbeat"}]}"#
                } else if request_line.starts_with("GET /api/v1/messages?")
                    && request.contains("anchor=50")
                {
                    focused = true;
                    r#"{
                        "result":"success",
                        "found_oldest":false,
                        "found_newest":false,
                        "messages":[{
                            "id":50,
                            "sender_id":22,
                            "sender_full_name":"Theo Martin",
                            "timestamp":1770000050,
                            "content":"<p>Native macOS result</p>",
                            "type":"stream",
                            "stream_id":5,
                            "subject":"macOS",
                            "display_recipient":"engineering"
                        }]
                    }"#
                } else if request_line.starts_with("GET /api/v1/messages?") {
                    r#"{
                        "result":"success",
                        "found_oldest":true,
                        "found_newest":true,
                        "messages":[{
                            "id":50,
                            "sender_id":22,
                            "sender_full_name":"Theo Martin",
                            "timestamp":1770000050,
                            "content":"<p>Native macOS result</p>",
                            "type":"stream",
                            "stream_id":5,
                            "subject":"macOS",
                            "display_recipient":"engineering"
                        }]
                    }"#
                } else {
                    panic!("unexpected request: {request_line}");
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        (format!("http://{address}/"), receiver)
    }

    fn spawn_password_session_mock() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let bodies = [
                r#"{"result":"success","api_key":"derived-fixture-key","email":"maya@example.com"}"#,
                r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":9}"#,
                r##"{
                    "result":"success",
                    "queue_id":"queue-password",
                    "last_event_id":10,
                    "event_queue_longpoll_timeout_seconds":5,
                    "zulip_feature_level":481,
                    "realm_users":[],
                    "subscriptions":[{
                        "stream_id":5,
                        "name":"engineering",
                        "color":"#76ce90",
                        "is_muted":false
                    }]
                }"##,
                r#"{"result":"success","topics":[{"max_id":44,"name":"macOS"}]}"#,
            ];
            for body in bodies {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let _ = sender.send(request);
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
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

    fn spawn_topic_actor_mock() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut updates = 0;
            while updates < 2 {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let request_line = request.lines().next().unwrap_or_default();
                if request_line.is_empty() {
                    continue;
                }
                let _ = sender.send(request.clone());
                let body = if request_line.starts_with("GET /api/v1/users/me HTTP") {
                    r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":9}"#
                } else if request_line.starts_with("POST /api/v1/register HTTP") {
                    r##"{
                        "result":"success",
                        "queue_id":"queue-topic",
                        "last_event_id":10,
                        "event_queue_longpoll_timeout_seconds":5,
                        "zulip_feature_level":481,
                        "realm_users":[],
                        "subscriptions":[{
                            "stream_id":5,
                            "name":"engineering",
                            "color":"#76ce90",
                            "is_muted":false
                        }]
                    }"##
                } else if request_line.starts_with("GET /api/v1/users/me/5/topics?") {
                    r#"{"result":"success","topics":[{"max_id":50,"name":"macOS"}]}"#
                } else if request_line.starts_with("GET /api/v1/events?") {
                    thread::sleep(Duration::from_millis(10));
                    r#"{"result":"success","events":[{"id":11,"type":"heartbeat"}]}"#
                } else if request_line.starts_with("PATCH /api/v1/messages/") {
                    updates += 1;
                    r#"{"result":"success"}"#
                } else {
                    panic!("unexpected request: {request_line}");
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        (format!("http://{address}/"), receiver)
    }

    fn spawn_message_action_actor_mock() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut writes = 0;
            while writes < 5 {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let request_line = request.lines().next().unwrap_or_default();
                if request_line.is_empty() {
                    continue;
                }
                let _ = sender.send(request.clone());
                let body = if request_line.starts_with("GET /api/v1/users/me HTTP") {
                    r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":9}"#
                } else if request_line.starts_with("POST /api/v1/register HTTP") {
                    r#"{
                        "result":"success",
                        "queue_id":"queue-actions",
                        "last_event_id":10,
                        "event_queue_longpoll_timeout_seconds":5,
                        "zulip_feature_level":481,
                        "realm_users":[],
                        "subscriptions":[]
                    }"#
                } else if request_line.starts_with("GET /api/v1/events?") {
                    thread::sleep(Duration::from_millis(10));
                    r#"{"result":"success","events":[{"id":11,"type":"heartbeat"}]}"#
                } else if request_line.starts_with("PATCH /api/v1/messages/50")
                    || request_line.starts_with("POST /api/v1/messages/50/reactions")
                    || request_line.starts_with("POST /api/v1/messages/flags")
                    || request_line.starts_with("DELETE /api/v1/messages/50")
                {
                    writes += 1;
                    r#"{"result":"success","messages":[50]}"#
                } else {
                    panic!("unexpected request: {request_line}");
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        (format!("http://{address}/"), receiver)
    }

    fn spawn_media_actor_mock() -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut media_downloaded = false;
            while !media_downloaded {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let request_line = request.lines().next().unwrap_or_default();
                if request_line.is_empty() {
                    continue;
                }
                let _ = sender.send(request.clone());
                let (content_type, body) = if request_line.starts_with("GET /api/v1/users/me HTTP")
                {
                    (
                        "application/json",
                        r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":9}"#,
                    )
                } else if request_line.starts_with("POST /api/v1/register HTTP") {
                    (
                        "application/json",
                        r#"{
                            "result":"success",
                            "queue_id":"queue-media",
                            "last_event_id":10,
                            "event_queue_longpoll_timeout_seconds":5,
                            "zulip_feature_level":481,
                            "realm_users":[],
                            "subscriptions":[]
                        }"#,
                    )
                } else if request_line.starts_with("GET /api/v1/events?") {
                    thread::sleep(Duration::from_millis(10));
                    (
                        "application/json",
                        r#"{"result":"success","events":[{"id":11,"type":"heartbeat"}]}"#,
                    )
                } else if request_line.starts_with("POST /api/v1/user_uploads HTTP") {
                    (
                        "application/json",
                        r#"{"result":"success","filename":"fixture image.png","url":"/user_uploads/1/ab/fixture-image.png"}"#,
                    )
                } else if request_line
                    .starts_with("GET /api/v1/user_uploads/1/ab/fixture-image.png HTTP")
                {
                    (
                        "application/json",
                        r#"{"result":"success","url":"/user_uploads/temporary/token/fixture-image.png"}"#,
                    )
                } else if request_line
                    .starts_with("GET /user_uploads/temporary/token/fixture-image.png HTTP")
                {
                    media_downloaded = true;
                    ("image/png", "fixture-image")
                } else {
                    panic!("unexpected request: {request_line}");
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
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

    fn wait_for_event(
        receiver: &mpsc::Receiver<()>,
        sink: &RecordingSink,
        predicate: impl Fn(&CoreEvent) -> bool,
    ) -> CoreEvent {
        let deadline = StdInstant::now() + Duration::from_secs(5);
        loop {
            if let Some(event) = sink
                .events
                .lock()
                .expect("event lock poisoned")
                .iter()
                .find(|event| predicate(event))
                .cloned()
            {
                return event;
            }
            let remaining = deadline.saturating_duration_since(StdInstant::now());
            assert!(!remaining.is_zero(), "timed out waiting for actor event");
            receiver
                .recv_timeout(remaining)
                .expect("actor event notification");
        }
    }
}
