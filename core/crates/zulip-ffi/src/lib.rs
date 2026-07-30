#![doc = "Swift-facing actor boundary for the native Zulip macOS client."]

use std::{sync::Arc, time::Duration};

use tokio::{
    runtime::Runtime,
    sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel},
    task::JoinSet,
    time::Instant,
};
use zulip_core::{
    auth::{AuthenticatedAccount, AuthenticationClient, SecretString},
    messages::{ConversationTarget, MessageClient, OutgoingMessage, TopicSummary},
    sync::{
        EventQueueClient, MessageSummary, RecoveryPolicy, SyncCycle, SyncSession, SyncSnapshot,
        UserSummary,
    },
};

uniffi::setup_scaffolding!();

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
    /// Adds the personal `read` flag to messages.
    MarkRead {
        /// Correlates the response.
        request_id: u64,
        /// Client-owned account partition.
        account_id: String,
        /// Server message identifiers.
        message_ids: Vec<i64>,
    },
    /// Ends the current live account session.
    Disconnect {
        /// Correlates the response.
        request_id: u64,
    },
}

impl CoreCommand {
    const fn request_id(&self) -> u64 {
        match self {
            Self::Ping { request_id, .. }
            | Self::StartApiKeySession { request_id, .. }
            | Self::StartPasswordSession { request_id, .. }
            | Self::OpenConversation { request_id, .. }
            | Self::LoadOlderMessages { request_id, .. }
            | Self::SearchMessages { request_id, .. }
            | Self::OpenMessage { request_id, .. }
            | Self::SendChannelMessage { request_id, .. }
            | Self::SendDirectMessage { request_id, .. }
            | Self::MarkRead { request_id, .. }
            | Self::Disconnect { request_id } => *request_id,
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
    /// Untrusted rendered Zulip HTML for Rust content normalization.
    pub content_html: String,
    /// Channel identifier for channel messages.
    pub stream_id: Option<i64>,
    /// Topic name for channel messages.
    pub topic: Option<String>,
    /// Recipient identifiers for direct messages.
    pub recipient_ids: Vec<i64>,
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
    pub fn new(event_sink: Arc<dyn CoreEventSink>) -> Arc<Self> {
        let runtime = Runtime::new().expect("the built-in Tokio runtime initializes");
        let (sender, receiver) = unbounded_channel();
        runtime.spawn(run_actor(receiver, Arc::clone(&event_sink)));
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
    sync: SyncSession,
    topics: Vec<TopicSummary>,
}

enum ActorInput {
    Command(Option<CoreCommand>),
    Sync(SyncCycle),
}

async fn run_actor(
    mut receiver: UnboundedReceiver<CoreCommand>,
    event_sink: Arc<dyn CoreEventSink>,
) {
    let mut account: Option<AccountSession> = None;
    let mut poll_not_before = Instant::now();

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
                handle_command(command, &mut account, &event_sink).await;
                let current_account = account.as_ref().map(|session| session.account_id.as_str());
                if resets_poll || previous_account.as_deref() != current_account {
                    poll_not_before = Instant::now();
                }
            }
            ActorInput::Command(None) => break,
            ActorInput::Sync(cycle) => {
                let terminal = matches!(&cycle, SyncCycle::Fatal { .. });
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
                request_id, account_id, server_url, email, api_key, account, event_sink,
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
                request_id, account_id, server_url, username, password, account, event_sink,
            )
            .await;
        }
        CoreCommand::OpenConversation {
            request_id,
            key,
            limit,
        } => open_conversation(request_id, key, limit, account.as_ref(), event_sink).await,
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
        CoreCommand::Disconnect { request_id } => disconnect(request_id, account, event_sink),
    }
}

fn disconnect(
    request_id: u64,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
) {
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
    event_sink: &Arc<dyn CoreEventSink>,
) {
    let Some(session) = account.filter(|item| item.account_id == key.account_id()) else {
        emit_no_session(request_id, event_sink);
        return;
    };
    match session
        .messages
        .fetch_conversation(key.target(), limit)
        .await
    {
        Ok(page) => event_sink.handle_event(CoreEvent::ConversationOpened {
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
    start_authenticated_session(request_id, account_id, authenticated, account, event_sink).await;
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
    start_authenticated_session(request_id, account_id, authenticated, account, event_sink).await;
}

async fn start_authenticated_session(
    request_id: u64,
    account_id: String,
    authenticated: AuthenticatedAccount,
    account: &mut Option<AccountSession>,
    event_sink: &Arc<dyn CoreEventSink>,
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
    )
    .await;
}

#[allow(clippy::too_many_arguments)]
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
            let bridge_snapshot = CoreSnapshot::from_sync(snapshot, &topics);
            *account = Some(AccountSession {
                account_id: account_id.clone(),
                own_user_id: user_id,
                messages,
                sync,
                topics,
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
                event_sink.handle_event(CoreEvent::SnapshotUpdated {
                    account_id: account.account_id.clone(),
                    snapshot: CoreSnapshot::from_sync(snapshot, &account.topics),
                });
            }
            Instant::now()
        }
        SyncCycle::Resynchronized { snapshot, .. } => {
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
        Self {
            message_id: message.id,
            sender_id: message.sender_id,
            sender_full_name: message.sender_full_name,
            timestamp: message.timestamp,
            content_html: message.content_html,
            stream_id: message.stream_id,
            topic: message.topic,
            recipient_ids: message.recipient_ids,
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
        CoreCommand, CoreConversationKey, CoreEvent, CoreEventSink, CoreSnapshot, RustCoreClient,
        conversation_key_for_message,
    };
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
        let client = RustCoreClient::new(sink.clone());

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
    fn actor_searches_and_focuses_a_correlated_result() {
        let (server, requests) = spawn_search_actor_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone());

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
    fn api_key_session_registers_off_the_calling_thread() {
        let (server, request) = spawn_register_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone());

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
    fn password_session_exchanges_key_and_returns_redacted_credential() {
        let (server, requests) = spawn_password_session_mock();
        let (signal_sender, signal_receiver) = mpsc::channel();
        let sink = Arc::new(RecordingSink {
            events: Mutex::new(Vec::new()),
            notifier: Mutex::new(Some(signal_sender)),
        });
        let client = RustCoreClient::new(sink.clone());

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
