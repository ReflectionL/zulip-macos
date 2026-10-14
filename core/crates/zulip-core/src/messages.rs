//! Authenticated conversation fetch, send, and read-state APIs.

use futures_util::StreamExt;
use reqwest::{Client, Response};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::{
    auth::SecretString,
    server::{DEFAULT_REQUEST_TIMEOUT, ServerBaseUrl, ServerUrlError, secure_http_client},
    sync::MessageSummary,
};

const MESSAGES_PATH: &str = "api/v1/messages";
const MESSAGE_FLAGS_PATH: &str = "api/v1/messages/flags";
const PRESENCE_PATH: &str = "api/v1/users/me/presence";
const TYPING_PATH: &str = "api/v1/typing";
const STREAMS_PATH_PREFIX: &str = "api/v1/streams";
const SUBSCRIPTIONS_PATH: &str = "api/v1/users/me/subscriptions";
const SUBSCRIPTION_PROPERTIES_PATH: &str = "api/v1/users/me/subscriptions/properties";
const SETTINGS_PATH: &str = "api/v1/settings";
const USER_TOPICS_PATH: &str = "api/v1/user_topics";
const MAX_CHANNEL_NAME_CHARS: usize = 60;
const MAX_CHANNEL_DESCRIPTION_CHARS: usize = 1_024;
const MAX_CHANNEL_MEMBERS: usize = 1_000;
/// How recent a presence timestamp must be (Zulip's offline threshold) to count.
const PRESENCE_FRESH_SECONDS: f64 = 140.0;
const TOPICS_PATH_PREFIX: &str = "api/v1/users/me";
const MAX_MESSAGES_RESPONSE_BYTES: usize = 16 * 1_048_576;
const MAX_WRITE_RESPONSE_BYTES: usize = 1_048_576;
const MAX_FETCH_MESSAGES: u16 = 1_000;
const MAX_SEARCH_MESSAGES: u16 = 100;
const MAX_SEARCH_QUERY_BYTES: usize = 512;
const MAX_TOPIC_NAME_BYTES: usize = 1_024;
const MAX_EMOJI_NAME_BYTES: usize = 256;
const MAX_READ_RECEIPT_USERS: usize = 500;

/// Stable server-side conversation selection.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConversationTarget {
    /// The account's combined feed.
    Combined,
    /// Messages that mention the current user.
    Mentions,
    /// Messages starred by the current user.
    Starred,
    /// Messages that the current user has not read.
    Unread,
    /// All visible messages in one channel.
    Channel {
        /// Zulip stream identifier.
        stream_id: i64,
    },
    /// Messages in one channel topic.
    Topic {
        /// Zulip stream identifier.
        stream_id: i64,
        /// Exact topic name.
        topic: String,
    },
    /// Direct messages with the given participants.
    Direct {
        /// Other participant identifiers.
        recipient_ids: Vec<i64>,
    },
}

impl ConversationTarget {
    fn narrow_json(&self) -> Result<String, MessageApiError> {
        let narrow = match self {
            Self::Combined => Value::Array(Vec::new()),
            Self::Mentions => serde_json::json!([
                {"operator": "is", "operand": "mentioned"}
            ]),
            Self::Starred => serde_json::json!([
                {"operator": "is", "operand": "starred"}
            ]),
            Self::Unread => serde_json::json!([
                {"operator": "is", "operand": "unread"}
            ]),
            Self::Channel { stream_id } => serde_json::json!([
                {"operator": "channel", "operand": stream_id}
            ]),
            Self::Topic { stream_id, topic } => {
                if topic.chars().any(char::is_control) {
                    return Err(MessageApiError::InvalidInput);
                }
                serde_json::json!([
                    {"operator": "channel", "operand": stream_id},
                    {"operator": "topic", "operand": topic}
                ])
            }
            Self::Direct { recipient_ids } => {
                if recipient_ids.is_empty() || recipient_ids.iter().any(|id| *id <= 0) {
                    return Err(MessageApiError::InvalidInput);
                }
                serde_json::json!([
                    {"operator": "dm", "operand": recipient_ids}
                ])
            }
        };
        Ok(narrow.to_string())
    }
}

/// One topic visible to the current account.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TopicSummary {
    /// Zulip stream identifier.
    pub stream_id: i64,
    /// Exact topic name.
    pub name: String,
    /// Most recent message in the topic.
    pub max_message_id: i64,
}

/// A validated outgoing text message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OutgoingMessage {
    /// Message to a channel topic.
    Channel {
        /// Destination channel identifier.
        stream_id: i64,
        /// Destination topic.
        topic: String,
        /// Zulip-flavored Markdown content.
        content: String,
    },
    /// Direct message to one or more users.
    Direct {
        /// Destination user identifiers.
        recipient_ids: Vec<i64>,
        /// Zulip-flavored Markdown content.
        content: String,
    },
}

/// Scope applied when changing a channel message's topic.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TopicPropagation {
    /// Move only the selected message.
    ChangeOne,
    /// Rename every message in the selected message's current topic.
    ChangeAll,
}

/// What the account wants for one topic, overriding its channel (Zulip's
/// `visibility_policy`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TopicVisibilityChoice {
    /// Follow the channel: no choice of its own ("Default").
    Inherit,
    /// Hide the topic and silence its notifications.
    Muted,
    /// Show the topic although its channel is muted.
    Unmuted,
    /// Notify about every message and keep the topic prominent.
    Followed,
}

impl TopicVisibilityChoice {
    const fn policy(self) -> &'static str {
        match self {
            Self::Inherit => "0",
            Self::Muted => "1",
            Self::Unmuted => "2",
            Self::Followed => "3",
        }
    }
}

/// A conversation the account may be typing in.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TypingTarget {
    /// A direct-message conversation: the other participants (not the sender).
    Direct {
        /// Recipient user identifiers.
        user_ids: Vec<i64>,
    },
    /// A topic in a channel.
    Topic {
        /// Channel identifier.
        stream_id: i64,
        /// Topic name.
        topic: String,
    },
}

/// Personal message flag supported by the first daily-use write surface.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MessageFlag {
    /// Whether the current user has read the message.
    Read,
    /// Whether the current user starred the message.
    Starred,
}

impl MessageFlag {
    const fn api_value(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Starred => "starred",
        }
    }
}

/// Add or remove a personal message property.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MessageWriteOperation {
    /// Add the flag or reaction.
    Add,
    /// Remove the flag or reaction.
    Remove,
}

impl MessageWriteOperation {
    const fn api_value(self) -> &'static str {
        match self {
            Self::Add => "add",
            Self::Remove => "remove",
        }
    }
}

impl TopicPropagation {
    const fn api_value(self) -> &'static str {
        match self {
            Self::ChangeOne => "change_one",
            Self::ChangeAll => "change_all",
        }
    }
}

/// One fetched conversation page.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationMessages {
    /// Stable conversation selection.
    pub target: ConversationTarget,
    /// Messages sorted by server message identifier.
    pub messages: Vec<MessageSummary>,
    /// Whether the response reached the oldest matching message.
    pub found_oldest: bool,
    /// Whether the response reached the newest matching message.
    pub found_newest: bool,
}

/// Outcome of asking who has read a message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReadReceipts {
    /// Users who read the message, sorted by identifier.
    Readers(Vec<i64>),
    /// The server cannot tell: it predates read receipts, the organization
    /// disabled them, or the message is not visible to this user.
    Unavailable,
}

/// Message API failures safe to map into application errors.
#[derive(Debug, Error)]
pub enum MessageApiError {
    /// The server root violated the shared HTTPS policy.
    #[error(transparent)]
    InvalidServer(#[from] ServerUrlError),
    /// A credential, destination, content, or identifier was invalid.
    #[error("enter valid message details")]
    InvalidInput,
    /// DNS, TLS, timeout, redirect, or connection failure.
    #[error("could not communicate with the Zulip server: {message}")]
    Transport {
        /// Sanitized transport error.
        message: String,
    },
    /// The endpoint returned an unclassified non-success status.
    #[error("message request returned HTTP {0}")]
    HttpStatus(u16),
    /// Zulip rejected the operation with a stable API code.
    #[error("Zulip rejected the message operation: {code}")]
    Rejected {
        /// Stable server error code, excluding server-rendered message text.
        code: String,
    },
    /// The response exceeded its memory bound.
    #[error("message response is too large")]
    ResponseTooLarge,
    /// The response could not be normalized.
    #[error("the server returned an invalid message response: {0}")]
    InvalidResponse(&'static str),
}

/// Authenticated client for conversation reads and basic writes.
#[derive(Debug)]
pub struct MessageClient {
    http: Client,
    base_url: ServerBaseUrl,
    email: String,
    api_key: SecretString,
}

impl MessageClient {
    /// Creates a client with the shared native-root HTTPS policy.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid server or credential input.
    pub fn new(
        server: &str,
        email: impl Into<String>,
        api_key: SecretString,
    ) -> Result<Self, MessageApiError> {
        let base_url = ServerBaseUrl::parse(server)?;
        let email = email.into();
        if email.trim().is_empty()
            || email.contains(':')
            || email.chars().any(char::is_control)
            || api_key.expose_secret().is_empty()
        {
            return Err(MessageApiError::InvalidInput);
        }
        let http = secure_http_client(Some(DEFAULT_REQUEST_TIMEOUT))
            .map_err(|message| MessageApiError::Transport { message })?;
        Ok(Self {
            http,
            base_url,
            email,
            api_key,
        })
    }

    /// Fetches the newest messages matching a stable conversation target.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid limits/targets, transport,
    /// status, size, or message normalization failures.
    pub async fn fetch_conversation(
        &self,
        target: ConversationTarget,
        limit: u16,
    ) -> Result<ConversationMessages, MessageApiError> {
        if limit == 0 || limit > MAX_FETCH_MESSAGES {
            return Err(MessageApiError::InvalidInput);
        }
        self.fetch_page(target, "newest".to_owned(), true, limit, 0)
            .await
    }

    /// Fetches messages older than `before_message_id` for one conversation.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers/limits/targets,
    /// transport, status, size, or message normalization failures.
    pub async fn fetch_older_messages(
        &self,
        target: ConversationTarget,
        before_message_id: i64,
        limit: u16,
    ) -> Result<ConversationMessages, MessageApiError> {
        if before_message_id <= 0 || limit == 0 || limit > MAX_FETCH_MESSAGES {
            return Err(MessageApiError::InvalidInput);
        }
        self.fetch_page(target, before_message_id.to_string(), false, limit, 0)
            .await
    }

    /// Searches all visible messages using Zulip's server-side `search` narrow.
    ///
    /// Results are returned newest first and remain bounded to 100 messages.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for empty/oversized queries, invalid limits,
    /// transport, status, size, or message normalization failures.
    pub async fn search_messages(
        &self,
        query: &str,
        limit: u16,
    ) -> Result<Vec<MessageSummary>, MessageApiError> {
        let query = query.trim();
        if query.is_empty()
            || query.len() > MAX_SEARCH_QUERY_BYTES
            || query.chars().any(char::is_control)
            || limit == 0
            || limit > MAX_SEARCH_MESSAGES
        {
            return Err(MessageApiError::InvalidInput);
        }
        let narrow = serde_json::json!([
            {"operator": "search", "operand": query}
        ])
        .to_string();
        let page = self
            .fetch_narrow_page(narrow, "newest".to_owned(), true, limit, 0)
            .await?;
        Ok(page.messages.into_iter().rev().collect())
    }

    /// Fetches unread messages newer than `after_message_id`, oldest first and at
    /// most `limit` of them: what arrived while the event queue was lost.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers/limits, transport,
    /// status, size, or message normalization failures.
    pub async fn fetch_unread_after(
        &self,
        after_message_id: i64,
        limit: u16,
    ) -> Result<Vec<MessageSummary>, MessageApiError> {
        if after_message_id <= 0 || limit == 0 || limit > MAX_FETCH_MESSAGES {
            return Err(MessageApiError::InvalidInput);
        }
        let narrow = serde_json::json!([
            {"operator": "is", "operand": "unread"}
        ])
        .to_string();
        let page = self
            .fetch_narrow_page(narrow, after_message_id.to_string(), false, 0, limit)
            .await?;
        Ok(page
            .messages
            .into_iter()
            .filter(|message| message.id > after_message_id)
            .collect())
    }

    /// Fetches conversation context centered on one visible server message.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers/counts/targets,
    /// transport, status, size, normalization, or a missing anchor message.
    pub async fn fetch_message_context(
        &self,
        target: ConversationTarget,
        message_id: i64,
        num_before: u16,
        num_after: u16,
    ) -> Result<ConversationMessages, MessageApiError> {
        if message_id <= 0
            || usize::from(num_before)
                .saturating_add(usize::from(num_after))
                .saturating_add(1)
                > usize::from(MAX_FETCH_MESSAGES)
        {
            return Err(MessageApiError::InvalidInput);
        }
        let page = self
            .fetch_page(target, message_id.to_string(), true, num_before, num_after)
            .await?;
        if page.messages.iter().all(|message| message.id != message_id) {
            return Err(MessageApiError::InvalidResponse(
                "anchored message is unavailable",
            ));
        }
        Ok(page)
    }

    async fn fetch_page(
        &self,
        target: ConversationTarget,
        anchor: String,
        include_anchor: bool,
        num_before: u16,
        num_after: u16,
    ) -> Result<ConversationMessages, MessageApiError> {
        if num_before == 0 && num_after == 0 && !include_anchor {
            return Err(MessageApiError::InvalidInput);
        }
        let narrow = target.narrow_json()?;
        let page = self
            .fetch_narrow_page(narrow, anchor, include_anchor, num_before, num_after)
            .await?;
        Ok(ConversationMessages {
            target,
            messages: page.messages,
            found_oldest: page.found_oldest,
            found_newest: page.found_newest,
        })
    }

    async fn fetch_narrow_page(
        &self,
        narrow: String,
        anchor: String,
        include_anchor: bool,
        num_before: u16,
        num_after: u16,
    ) -> Result<NormalizedMessagesPage, MessageApiError> {
        if usize::from(num_before)
            .saturating_add(usize::from(num_after))
            .saturating_add(usize::from(include_anchor))
            > usize::from(MAX_FETCH_MESSAGES)
        {
            return Err(MessageApiError::InvalidInput);
        }
        let response = self
            .http
            .get(self.base_url.endpoint(MESSAGES_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .query(&[
                ("anchor", anchor),
                ("include_anchor", include_anchor.to_string()),
                ("num_before", num_before.to_string()),
                ("num_after", num_after.to_string()),
                ("narrow", narrow),
                ("apply_markdown", "true".to_owned()),
                ("client_gravatar", "false".to_owned()),
                ("allow_empty_topic_name", "true".to_owned()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: MessagesDocument =
            decode_response(response, MAX_MESSAGES_RESPONSE_BYTES).await?;
        document.validate_result()?;
        let messages = document
            .messages
            .into_iter()
            .map(MessageDocument::normalize)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(NormalizedMessagesPage {
            messages,
            found_oldest: document.found_oldest,
            found_newest: document.found_newest,
        })
    }

    /// Fetches all currently visible topics in one subscribed channel.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid channel identifiers, transport,
    /// status, size, or topic normalization failures.
    pub async fn fetch_topics(&self, stream_id: i64) -> Result<Vec<TopicSummary>, MessageApiError> {
        if stream_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let path = format!("{TOPICS_PATH_PREFIX}/{stream_id}/topics");
        let response = self
            .http
            .get(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .query(&[("allow_empty_topic_name", "true")])
            .send()
            .await
            .map_err(transport_error)?;
        let document: TopicsDocument =
            decode_response(response, MAX_MESSAGES_RESPONSE_BYTES).await?;
        document.validate_result()?;
        document
            .topics
            .into_iter()
            .map(|topic| topic.normalize(stream_id))
            .collect()
    }

    /// Sends a channel or direct text message and returns its server ID.
    ///
    /// `queue_id` and `local_id` must either both be present or both be absent.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid content/destination/local echo,
    /// transport, rejection, size, or response failures.
    pub async fn send_message(
        &self,
        message: OutgoingMessage,
        local_echo: Option<(&str, &str)>,
    ) -> Result<i64, MessageApiError> {
        let mut form = match message {
            OutgoingMessage::Channel {
                stream_id,
                topic,
                content,
            } => {
                validate_content(&content)?;
                if stream_id <= 0 || topic.chars().any(char::is_control) {
                    return Err(MessageApiError::InvalidInput);
                }
                vec![
                    ("type".to_owned(), "stream".to_owned()),
                    ("to".to_owned(), stream_id.to_string()),
                    ("topic".to_owned(), topic),
                    ("content".to_owned(), content),
                ]
            }
            OutgoingMessage::Direct {
                recipient_ids,
                content,
            } => {
                validate_content(&content)?;
                if recipient_ids.is_empty() || recipient_ids.iter().any(|id| *id <= 0) {
                    return Err(MessageApiError::InvalidInput);
                }
                vec![
                    ("type".to_owned(), "direct".to_owned()),
                    (
                        "to".to_owned(),
                        serde_json::json!(recipient_ids).to_string(),
                    ),
                    ("content".to_owned(), content),
                ]
            }
        };
        form.push(("read_by_sender".to_owned(), "true".to_owned()));
        if let Some((queue_id, local_id)) = local_echo {
            if queue_id.trim().is_empty()
                || local_id.trim().is_empty()
                || queue_id.chars().any(char::is_control)
                || local_id.chars().any(char::is_control)
            {
                return Err(MessageApiError::InvalidInput);
            }
            form.push(("queue_id".to_owned(), queue_id.to_owned()));
            form.push(("local_id".to_owned(), local_id.to_owned()));
        }

        let response = self
            .http
            .post(self.base_url.endpoint(MESSAGES_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&form)
            .send()
            .await
            .map_err(transport_error)?;
        let document: SendMessageDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()?;
        document
            .id
            .filter(|message_id| *message_id > 0)
            .ok_or(MessageApiError::InvalidResponse(
                "missing sent message identifier",
            ))
    }

    /// Changes the topic of one message or its entire current topic.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers/topic names,
    /// transport, rejection, size, or response failures.
    pub async fn update_message_topic(
        &self,
        message_id: i64,
        topic: &str,
        propagation: TopicPropagation,
    ) -> Result<(), MessageApiError> {
        if message_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let topic = validate_topic_name(topic)?;
        let path = format!("{MESSAGES_PATH}/{message_id}");
        let response = self
            .http
            .patch(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[
                ("topic", topic),
                ("propagate_mode", propagation.api_value()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Replaces the Zulip-flavored Markdown content of one message.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers/content, transport,
    /// rejection, size, or response failures.
    pub async fn update_message_content(
        &self,
        message_id: i64,
        content: &str,
    ) -> Result<(), MessageApiError> {
        if message_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        validate_content(content)?;
        let path = format!("{MESSAGES_PATH}/{message_id}");
        let response = self
            .http
            .patch(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[("content", content)])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Permanently deletes one message when the acting user has permission.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers, transport,
    /// rejection, size, or response failures.
    pub async fn delete_message(&self, message_id: i64) -> Result<(), MessageApiError> {
        if message_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let path = format!("{MESSAGES_PATH}/{message_id}");
        let response = self
            .http
            .delete(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Creates a channel by subscribing `member_ids` to a new name, which is how
    /// Zulip creates channels. The caller includes its own identifier.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid names, descriptions or members,
    /// transport, rejection (including permission and duplicate names), size,
    /// or response failures.
    pub async fn create_channel(
        &self,
        name: &str,
        description: &str,
        is_private: bool,
        member_ids: &[i64],
    ) -> Result<(), MessageApiError> {
        let name = name.trim();
        let description = description.trim();
        if name.is_empty()
            || name.chars().count() > MAX_CHANNEL_NAME_CHARS
            || name.chars().any(char::is_control)
            || description.chars().count() > MAX_CHANNEL_DESCRIPTION_CHARS
            || member_ids.is_empty()
            || member_ids.len() > MAX_CHANNEL_MEMBERS
            || member_ids.iter().any(|id| *id <= 0)
        {
            return Err(MessageApiError::InvalidInput);
        }
        let subscriptions =
            serde_json::json!([{ "name": name, "description": description }]).to_string();
        let principals = serde_json::to_string(member_ids)
            .map_err(|_| MessageApiError::InvalidResponse("channel members are not encodable"))?;
        let response = self
            .http
            .post(self.base_url.endpoint(SUBSCRIPTIONS_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[
                ("subscriptions", subscriptions),
                ("principals", principals),
                ("invite_only", is_private.to_string()),
                ("announce", "false".to_owned()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: SubscribeDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        validate_api_result(document.result.as_deref(), document.code.as_deref())?;
        if document.subscribed.as_ref().is_none_or(Value::is_null)
            || document
                .subscribed
                .as_ref()
                .and_then(Value::as_object)
                .is_some_and(serde_json::Map::is_empty)
        {
            // Nobody was newly subscribed: the channel already existed.
            return Err(MessageApiError::Rejected {
                code: "CHANNEL_ALREADY_EXISTS".to_owned(),
            });
        }
        Ok(())
    }

    /// Renames a channel. The server decides whether the acting user may.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers or names, transport,
    /// rejection (including permission and duplicate names), size, or response
    /// failures.
    pub async fn rename_channel(
        &self,
        stream_id: i64,
        new_name: &str,
    ) -> Result<(), MessageApiError> {
        let name = new_name.trim();
        if stream_id <= 0
            || name.is_empty()
            || name.chars().count() > MAX_CHANNEL_NAME_CHARS
            || name.chars().any(char::is_control)
        {
            return Err(MessageApiError::InvalidInput);
        }
        let path = format!("{STREAMS_PATH_PREFIX}/{stream_id}");
        let response = self
            .http
            .patch(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[("new_name", name)])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Turns desktop notifications for every message of one channel on or off
    /// (the subscription's `desktop_notifications` property).
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for an invalid channel identifier, transport,
    /// rejection, size, or response failures.
    pub async fn set_channel_desktop_notifications(
        &self,
        stream_id: i64,
        enabled: bool,
    ) -> Result<(), MessageApiError> {
        if stream_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let subscription_data = serde_json::json!([{
            "stream_id": stream_id,
            "property": "desktop_notifications",
            "value": enabled,
        }])
        .to_string();
        let response = self
            .http
            .post(self.base_url.endpoint(SUBSCRIPTION_PROPERTIES_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[("subscription_data", subscription_data)])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Mutes, unmutes or follows one topic, or returns it to its channel's
    /// behavior (`POST /user_topics`, Zulip 7.0 / feature level 134 and later).
    /// An empty `topic` is the channel's "general chat" (Zulip 10.0 / feature
    /// level 334 and later), which Zulip may follow automatically.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for an invalid channel identifier or topic,
    /// transport, rejection (including servers too old for the endpoint), size,
    /// or response failures.
    pub async fn set_topic_visibility(
        &self,
        stream_id: i64,
        topic: &str,
        choice: TopicVisibilityChoice,
    ) -> Result<(), MessageApiError> {
        if stream_id <= 0
            || (!topic.is_empty() && topic.trim().is_empty())
            || topic.len() > MAX_TOPIC_NAME_BYTES
            || topic.chars().any(char::is_control)
        {
            return Err(MessageApiError::InvalidInput);
        }
        let response = self
            .http
            .post(self.base_url.endpoint(USER_TOPICS_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[
                ("stream_id", stream_id.to_string()),
                ("topic", topic.to_owned()),
                ("visibility_policy", choice.policy().to_owned()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Sets the account-wide default for desktop notifications about every
    /// message in channels that have no setting of their own
    /// (`enable_stream_desktop_notifications`).
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for transport, rejection, size, or response
    /// failures.
    pub async fn set_default_channel_notifications(
        &self,
        enabled: bool,
    ) -> Result<(), MessageApiError> {
        let response = self
            .http
            .patch(self.base_url.endpoint(SETTINGS_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[("enable_stream_desktop_notifications", enabled.to_string())])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Fetches the original Markdown source of one visible message, as needed
    /// to quote or forward it.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers, transport,
    /// rejection, size, or response failures.
    pub async fn fetch_message_source(&self, message_id: i64) -> Result<String, MessageApiError> {
        if message_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let path = format!("{MESSAGES_PATH}/{message_id}");
        let response = self
            .http
            .get(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .query(&[("apply_markdown", "false")])
            .send()
            .await
            .map_err(transport_error)?;
        let document: MessageSourceDocument =
            decode_response(response, MAX_MESSAGES_RESPONSE_BYTES).await?;
        validate_api_result(document.result.as_deref(), document.code.as_deref())?;
        document
            .message
            .map(|message| message.content)
            .ok_or(MessageApiError::InvalidResponse(
                "message source is missing",
            ))
    }

    /// Lists who has read one message, according to Zulip's read receipts.
    ///
    /// The server answers only when the organization enables read receipts
    /// (Zulip 6.0, feature level 137) and omits readers who turned off sending
    /// them, so an unsupported or disabled server is reported as
    /// [`ReadReceipts::Unavailable`] rather than as a failure.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers, transport, rate
    /// limits, size, or response failures.
    pub async fn fetch_read_receipts(
        &self,
        message_id: i64,
    ) -> Result<ReadReceipts, MessageApiError> {
        if message_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let path = format!("{MESSAGES_PATH}/{message_id}/read_receipts");
        let response = self
            .http
            .get(self.base_url.endpoint(&path))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .send()
            .await
            .map_err(transport_error)?;
        let document: ReadReceiptsDocument =
            match decode_response(response, MAX_WRITE_RESPONSE_BYTES).await {
                Ok(document) => document,
                Err(error) => return read_receipts_failure(error),
            };
        validate_api_result(document.result.as_deref(), document.code.as_deref())?;
        let mut user_ids = document.user_ids;
        user_ids.retain(|id| *id > 0);
        user_ids.sort_unstable();
        user_ids.dedup();
        user_ids.truncate(MAX_READ_RECEIPT_USERS);
        Ok(ReadReceipts::Readers(user_ids))
    }

    /// Adds or removes the current user's emoji reaction on one message.
    ///
    /// Zulip resolves the reaction namespace from `emoji_name`, matching the
    /// documented compatibility behavior for Unicode and realm emoji.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for invalid identifiers/emoji names,
    /// transport, rejection, size, or response failures.
    pub async fn update_reaction(
        &self,
        message_id: i64,
        emoji_name: &str,
        operation: MessageWriteOperation,
    ) -> Result<(), MessageApiError> {
        if message_id <= 0 {
            return Err(MessageApiError::InvalidInput);
        }
        let emoji_name = emoji_name.trim();
        if emoji_name.is_empty()
            || emoji_name.len() > MAX_EMOJI_NAME_BYTES
            || emoji_name.chars().any(char::is_control)
        {
            return Err(MessageApiError::InvalidInput);
        }
        let path = format!("{MESSAGES_PATH}/{message_id}/reactions");
        let request = match operation {
            MessageWriteOperation::Add => self.http.post(self.base_url.endpoint(&path)),
            MessageWriteOperation::Remove => self.http.delete(self.base_url.endpoint(&path)),
        };
        let response = request
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[("emoji_name", emoji_name)])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Adds or removes a personal flag from the supplied messages.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for empty/invalid identifiers, transport,
    /// rejection, size, or response failures.
    pub async fn update_message_flag(
        &self,
        message_ids: &[i64],
        flag: MessageFlag,
        operation: MessageWriteOperation,
    ) -> Result<(), MessageApiError> {
        if message_ids.is_empty() || message_ids.iter().any(|id| *id <= 0) {
            return Err(MessageApiError::InvalidInput);
        }
        let messages =
            serde_json::to_string(message_ids).map_err(|_| MessageApiError::InvalidInput)?;
        let response = self
            .http
            .post(self.base_url.endpoint(MESSAGE_FLAGS_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[
                ("messages", messages.as_str()),
                ("op", operation.api_value()),
                ("flag", flag.api_value()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Adds the personal `read` flag to the supplied messages.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for empty/invalid identifiers, transport,
    /// rejection, size, or response failures.
    pub async fn mark_read(&self, message_ids: &[i64]) -> Result<(), MessageApiError> {
        self.update_message_flag(message_ids, MessageFlag::Read, MessageWriteOperation::Add)
            .await
    }

    /// Tells the server that the account started or stopped typing in a
    /// conversation, so its participants can show it.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for an empty recipient list or an invalid
    /// topic, and for transport, rejection, size, or response failures.
    pub async fn send_typing(
        &self,
        started: bool,
        target: &TypingTarget,
    ) -> Result<(), MessageApiError> {
        let (kind, recipients, topic) = match target {
            TypingTarget::Direct { user_ids } => {
                if user_ids.is_empty() || user_ids.iter().any(|id| *id <= 0) {
                    return Err(MessageApiError::InvalidInput);
                }
                // "private" is the spelling every server version accepts.
                ("private", serde_json::to_string(user_ids), None)
            }
            TypingTarget::Topic { stream_id, topic } => {
                if *stream_id <= 0 || topic.chars().any(char::is_control) || topic.len() > 200 {
                    return Err(MessageApiError::InvalidInput);
                }
                ("stream", serde_json::to_string(&[*stream_id]), Some(topic))
            }
        };
        let recipients = recipients.map_err(|_| MessageApiError::InvalidInput)?;
        let mut form = vec![
            ("op", if started { "start" } else { "stop" }),
            ("type", kind),
            ("to", recipients.as_str()),
        ];
        if let Some(topic) = topic {
            form.push(("topic", topic.as_str()));
        }
        let response = self
            .http
            .post(self.base_url.endpoint(TYPING_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&form)
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }

    /// Reports the current user's own presence and returns everyone else's.
    ///
    /// Zulip derives "online" from recent presence pings, so a client that never
    /// pings is invisible to others and never learns who is online.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for transport, rejection, size, or response
    /// failures.
    pub async fn update_presence(
        &self,
        is_active: bool,
    ) -> Result<Vec<UserPresence>, MessageApiError> {
        let response = self
            .http
            .post(self.base_url.endpoint(PRESENCE_PATH))
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .form(&[
                ("status", if is_active { "active" } else { "idle" }),
                ("slim_presence", "true"),
                ("new_user_input", if is_active { "true" } else { "false" }),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: PresenceDocument =
            decode_response(response, MAX_MESSAGES_RESPONSE_BYTES).await?;
        validate_api_result(document.result.as_deref(), document.code.as_deref())?;
        let now = if document.server_timestamp > 0.0 {
            document.server_timestamp
        } else {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0.0, |elapsed| elapsed.as_secs_f64())
        };
        let mut presences = document
            .presences
            .into_iter()
            .filter_map(|(key, record)| {
                Some(UserPresence {
                    user_id: key.parse().ok()?,
                    status: presence_status(now, record.active_timestamp, record.idle_timestamp),
                    last_active_at: record
                        .active_timestamp
                        .or(record.idle_timestamp)
                        .and_then(whole_seconds),
                })
            })
            .collect::<Vec<_>>();
        presences.sort_by_key(|presence| presence.user_id);
        Ok(presences)
    }
}

/// Whether a user is currently using Zulip.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PresenceStatus {
    /// Recently active.
    Active,
    /// Connected but not recently active.
    Idle,
    /// No recent presence.
    Offline,
}

/// One user's derived presence.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UserPresence {
    /// Zulip user identifier.
    pub user_id: i64,
    /// Derived state.
    pub status: PresenceStatus,
    /// When the user was last active (Unix seconds); the last idle report when
    /// they never were, and `None` when the server has no record.
    pub last_active_at: Option<i64>,
}

/// Whole Unix seconds of a server timestamp, if it is a usable one.
#[allow(clippy::cast_possible_truncation)]
fn whole_seconds(timestamp: f64) -> Option<i64> {
    (timestamp.is_finite() && timestamp > 0.0).then(|| timestamp.floor() as i64)
}

/// Applies Zulip's offline threshold to a presence record.
#[must_use]
pub fn presence_status(now: f64, active: Option<f64>, idle: Option<f64>) -> PresenceStatus {
    let is_fresh = |timestamp: Option<f64>| {
        timestamp.is_some_and(|value| now - value < PRESENCE_FRESH_SECONDS)
    };
    if is_fresh(active) {
        PresenceStatus::Active
    } else if is_fresh(idle) {
        PresenceStatus::Idle
    } else {
        PresenceStatus::Offline
    }
}

#[derive(Debug, Deserialize)]
struct PresenceDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    server_timestamp: f64,
    #[serde(default)]
    presences: std::collections::HashMap<String, PresenceRecord>,
}

#[derive(Debug, Deserialize)]
struct PresenceRecord {
    #[serde(default)]
    active_timestamp: Option<f64>,
    #[serde(default)]
    idle_timestamp: Option<f64>,
}

struct NormalizedMessagesPage {
    messages: Vec<MessageSummary>,
    found_oldest: bool,
    found_newest: bool,
}

fn validate_content(content: &str) -> Result<(), MessageApiError> {
    if content.trim().is_empty() || content.chars().any(|character| character == '\0') {
        Err(MessageApiError::InvalidInput)
    } else {
        Ok(())
    }
}

fn validate_topic_name(topic: &str) -> Result<&str, MessageApiError> {
    let topic = topic.trim();
    if topic.is_empty() || topic.len() > MAX_TOPIC_NAME_BYTES || topic.chars().any(char::is_control)
    {
        Err(MessageApiError::InvalidInput)
    } else {
        Ok(topic)
    }
}

#[derive(Debug, Deserialize)]
struct MessagesDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    found_oldest: bool,
    #[serde(default)]
    found_newest: bool,
    #[serde(default)]
    messages: Vec<MessageDocument>,
}

#[derive(Debug, Deserialize)]
struct TopicsDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    topics: Vec<TopicDocument>,
}

impl TopicsDocument {
    fn validate_result(&self) -> Result<(), MessageApiError> {
        validate_api_result(self.result.as_deref(), self.code.as_deref())
    }
}

#[derive(Debug, Deserialize)]
struct TopicDocument {
    max_id: i64,
    name: String,
}

impl TopicDocument {
    fn normalize(self, stream_id: i64) -> Result<TopicSummary, MessageApiError> {
        if self.max_id <= 0 || self.name.chars().any(char::is_control) {
            return Err(MessageApiError::InvalidResponse("invalid topic"));
        }
        Ok(TopicSummary {
            stream_id,
            name: self.name,
            max_message_id: self.max_id,
        })
    }
}

impl MessagesDocument {
    fn validate_result(&self) -> Result<(), MessageApiError> {
        validate_api_result(self.result.as_deref(), self.code.as_deref())
    }
}

#[derive(Debug, Deserialize)]
struct SendMessageDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    id: Option<i64>,
}

impl SendMessageDocument {
    fn validate_result(&self) -> Result<(), MessageApiError> {
        validate_api_result(self.result.as_deref(), self.code.as_deref())
    }
}

#[derive(Debug, Deserialize)]
struct SubscribeDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    subscribed: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct MessageSourceDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    message: Option<MessageSourceBody>,
}

#[derive(Debug, Deserialize)]
struct MessageSourceBody {
    content: String,
}

#[derive(Debug, Deserialize)]
struct ReadReceiptsDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    user_ids: Vec<i64>,
}

#[derive(Debug, Deserialize)]
struct ApiResultDocument {
    result: Option<String>,
    #[serde(default)]
    code: Option<String>,
}

impl ApiResultDocument {
    fn validate_result(&self) -> Result<(), MessageApiError> {
        validate_api_result(self.result.as_deref(), self.code.as_deref())
    }
}

fn validate_api_result(result: Option<&str>, code: Option<&str>) -> Result<(), MessageApiError> {
    if result.is_none_or(|result| result == "success") {
        return Ok(());
    }
    Err(MessageApiError::Rejected {
        code: code.unwrap_or("UNKNOWN").to_owned(),
    })
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
    reactions: Vec<crate::sync::ReactionDocument>,
    #[serde(default)]
    last_edit_timestamp: Option<i64>,
}

impl MessageDocument {
    fn normalize(self) -> Result<MessageSummary, MessageApiError> {
        let is_channel = matches!(self.message_type.as_str(), "stream" | "channel");
        if !is_channel && !matches!(self.message_type.as_str(), "private" | "direct") {
            return Err(MessageApiError::InvalidResponse("unknown message type"));
        }
        if is_channel && self.stream_id.is_none() {
            return Err(MessageApiError::InvalidResponse(
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
                .filter_map(crate::sync::ReactionDocument::normalize)
                .collect(),
            last_edit_timestamp: self.last_edit_timestamp,
        })
    }
}

#[derive(Debug, Deserialize)]
struct ApiErrorDocument {
    code: Option<String>,
}

/// Maps a failed read-receipts request: a missing route or a plain rejection means
/// the feature is unavailable, while rate limits and transport trouble stay errors
/// so the caller can try again later.
fn read_receipts_failure(error: MessageApiError) -> Result<ReadReceipts, MessageApiError> {
    match error {
        MessageApiError::HttpStatus(400 | 403 | 404 | 405) => Ok(ReadReceipts::Unavailable),
        MessageApiError::Rejected { ref code } if code == "BAD_REQUEST" => {
            Ok(ReadReceipts::Unavailable)
        }
        other => Err(other),
    }
}

fn transport_error(error: reqwest::Error) -> MessageApiError {
    MessageApiError::Transport {
        message: error.without_url().to_string(),
    }
}

async fn decode_response<T: DeserializeOwned>(
    response: Response,
    maximum_bytes: usize,
) -> Result<T, MessageApiError> {
    let status = response.status();
    if response
        .content_length()
        .is_some_and(|length| length > u64::try_from(maximum_bytes).unwrap_or(u64::MAX))
    {
        return Err(MessageApiError::ResponseTooLarge);
    }

    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(transport_error)?;
        if bytes.len().saturating_add(chunk.len()) > maximum_bytes {
            return Err(MessageApiError::ResponseTooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }

    if !status.is_success() {
        if let Some(code) = serde_json::from_slice::<ApiErrorDocument>(&bytes)
            .ok()
            .and_then(|document| document.code)
        {
            return Err(MessageApiError::Rejected { code });
        }
        return Err(MessageApiError::HttpStatus(status.as_u16()));
    }
    serde_json::from_slice(&bytes).map_err(|_| MessageApiError::InvalidResponse("invalid JSON"))
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc,
        thread,
    };

    use reqwest::StatusCode;

    use super::{
        ConversationTarget, MessageApiError, MessageClient, MessageFlag, MessageWriteOperation,
        OutgoingMessage, PresenceStatus, ReadReceipts, TopicPropagation, TopicVisibilityChoice,
        TypingTarget,
    };
    use crate::auth::SecretString;

    const API_KEY: &str = "fixture-message-key-do-not-log";

    #[tokio::test]
    async fn fetch_send_and_mark_read_follow_the_zulip_protocol() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "found_oldest":true,
                    "found_newest":true,
                    "messages":[{
                        "id":42,
                        "sender_id":7,
                        "sender_full_name":"Maya Chen",
                        "timestamp":1770000000,
                        "content":"<p>Hello</p>",
                        "type":"stream",
                        "stream_id":5,
                        "subject":"Rust core",
                        "display_recipient":"engineering",
                        "flags":["read","starred"],
                        "last_edit_timestamp":1770000090,
                        "reactions":[{"emoji_name":"thumbs_up","emoji_code":"1f44d","reaction_type":"unicode_emoji","user_id":7}]
                    }]
                }"#
                .to_owned(),
            ),
            (StatusCode::OK, r#"{"result":"success","id":43}"#.to_owned()),
            (
                StatusCode::OK,
                r#"{"result":"success","messages":[42,43]}"#.to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        let page = client
            .fetch_conversation(
                ConversationTarget::Topic {
                    stream_id: 5,
                    topic: "Rust core".to_owned(),
                },
                50,
            )
            .await
            .expect("fetch conversation");
        assert_eq!(page.messages[0].id, 42);
        assert_eq!(page.messages[0].content_html, "<p>Hello</p>");
        assert_eq!(page.messages[0].flags, vec!["read", "starred"]);
        assert_eq!(page.messages[0].reactions[0].emoji_name, "thumbs_up");
        assert_eq!(page.messages[0].reactions[0].emoji_code, "1f44d");
        assert_eq!(page.messages[0].last_edit_timestamp, Some(1_770_000_090));
        assert!(page.found_oldest && page.found_newest);

        let message_id = client
            .send_message(
                OutgoingMessage::Channel {
                    stream_id: 5,
                    topic: "Rust core".to_owned(),
                    content: "A live message".to_owned(),
                },
                Some(("queue-fixture", "local-1")),
            )
            .await
            .expect("send message");
        assert_eq!(message_id, 43);
        client.mark_read(&[42, 43]).await.expect("mark read");

        assert_fetch_request(&requests.recv().expect("fetch request"));
        assert_send_request(&requests.recv().expect("send request"));
        assert_read_request(&requests.recv().expect("read request"));
    }

    #[tokio::test]
    async fn presence_is_reported_and_derived_from_fresh_timestamps() {
        let responses = vec![(
            StatusCode::OK,
            r#"{
                "result":"success",
                "server_timestamp":1000.5,
                "presences":{
                    "9":{"active_timestamp":990,"idle_timestamp":900},
                    "7":{"active_timestamp":500,"idle_timestamp":950},
                    "4":{"active_timestamp":100},
                    "maya@example.com":{"aggregated":{"status":"active","timestamp":999}}
                }
            }"#
            .to_owned(),
        )];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        let presences = client.update_presence(true).await.expect("presence");
        assert_eq!(
            presences
                .iter()
                .map(|presence| (presence.user_id, presence.status))
                .collect::<Vec<_>>(),
            vec![
                (4, PresenceStatus::Offline),
                (7, PresenceStatus::Idle),
                (9, PresenceStatus::Active),
            ]
        );
        assert_eq!(
            presences
                .iter()
                .map(|presence| presence.last_active_at)
                .collect::<Vec<_>>(),
            vec![Some(100), Some(500), Some(990)]
        );
        let request = requests.recv().expect("presence request");
        assert!(request.starts_with("POST /api/v1/users/me/presence HTTP/1.1"));
        assert!(request.contains("status=active"));
        assert!(request.contains("slim_presence=true"));
        assert!(!request.contains(API_KEY));
    }

    #[tokio::test]
    async fn typing_notifications_name_the_conversation() {
        let ok = || (StatusCode::OK, r#"{"result":"success"}"#.to_owned());
        let (server, requests) = spawn_mock(vec![ok(), ok()]);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .send_typing(
                true,
                &TypingTarget::Direct {
                    user_ids: vec![22, 23],
                },
            )
            .await
            .expect("direct typing");
        client
            .send_typing(
                false,
                &TypingTarget::Topic {
                    stream_id: 5,
                    topic: "Rust core".to_owned(),
                },
            )
            .await
            .expect("topic typing");
        assert!(
            client
                .send_typing(true, &TypingTarget::Direct { user_ids: vec![] })
                .await
                .is_err()
        );

        let direct = requests.recv().expect("direct request");
        assert!(direct.starts_with("POST /api/v1/typing HTTP/1.1"));
        assert!(direct.contains("op=start"));
        assert!(direct.contains("type=private"));
        assert!(direct.contains("to=%5B22%2C23%5D"));
        assert!(!direct.contains("topic="));
        let topic = requests.recv().expect("topic request");
        assert!(topic.contains("op=stop"));
        assert!(topic.contains("type=stream"));
        assert!(topic.contains("to=%5B5%5D"));
        assert!(topic.contains("topic=Rust+core"));
        assert!(!topic.contains(API_KEY));
    }

    #[tokio::test]
    async fn create_channel_subscribes_members_to_a_new_name() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{"result":"success","subscribed":{"9":["design"]},"already_subscribed":{}}"#
                    .to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{"result":"success","subscribed":{},"already_subscribed":{"9":["design"]}}"#
                    .to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .create_channel(" design ", "Visual work", true, &[9, 7])
            .await
            .expect("created");
        let request = requests.recv().expect("create request");
        assert!(request.starts_with("POST /api/v1/users/me/subscriptions HTTP/1.1"));
        assert!(request.contains("invite_only=true"));
        assert!(request.contains("principals=%5B9%2C7%5D"));
        assert!(request.contains("design"));
        assert!(!request.contains(API_KEY));

        assert!(matches!(
            client.create_channel("design", "", false, &[9]).await,
            Err(MessageApiError::Rejected { code }) if code == "CHANNEL_ALREADY_EXISTS"
        ));
        assert!(matches!(
            client.create_channel("  ", "", false, &[9]).await,
            Err(MessageApiError::InvalidInput)
        ));
        assert!(matches!(
            client.create_channel("design", "", false, &[]).await,
            Err(MessageApiError::InvalidInput)
        ));
    }

    #[tokio::test]
    async fn rename_channel_patches_the_stream_name() {
        let responses = vec![
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
            (
                StatusCode::BAD_REQUEST,
                r#"{"result":"error","code":"UNAUTHORIZED_PRINCIPAL","msg":"Insufficient permission"}"#
                    .to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .rename_channel(5, " design team ")
            .await
            .expect("renamed");
        let request = requests.recv().expect("rename request");
        assert!(request.starts_with("PATCH /api/v1/streams/5 HTTP/1.1"));
        assert!(request.contains("new_name=design+team"));
        assert!(!request.contains(API_KEY));

        assert!(client.rename_channel(5, "design").await.is_err());
        assert!(matches!(
            client.rename_channel(0, "design").await,
            Err(MessageApiError::InvalidInput)
        ));
        assert!(matches!(
            client.rename_channel(5, "  ").await,
            Err(MessageApiError::InvalidInput)
        ));
    }

    #[tokio::test]
    async fn notification_settings_are_written_to_the_server() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{"result":"success","msg":""}"#.to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{"result":"success","msg":""}"#.to_owned(),
            ),
            (
                StatusCode::BAD_REQUEST,
                r#"{"result":"error","code":"BAD_REQUEST","msg":"Invalid stream id"}"#.to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .set_channel_desktop_notifications(5, true)
            .await
            .expect("channel setting");
        let request = requests.recv().expect("channel request");
        assert!(request.starts_with("POST /api/v1/users/me/subscriptions/properties HTTP/1.1"));
        assert!(request.contains("subscription_data="));
        assert!(request.contains("desktop_notifications"));
        assert!(request.contains("%22stream_id%22%3A5"));
        assert!(request.contains("%22value%22%3Atrue"));
        assert!(!request.contains(API_KEY));

        client
            .set_default_channel_notifications(false)
            .await
            .expect("default setting");
        let request = requests.recv().expect("default request");
        assert!(request.starts_with("PATCH /api/v1/settings HTTP/1.1"));
        assert!(request.contains("enable_stream_desktop_notifications=false"));

        assert!(
            client
                .set_channel_desktop_notifications(9, false)
                .await
                .is_err()
        );
        assert!(matches!(
            client.set_channel_desktop_notifications(0, true).await,
            Err(MessageApiError::InvalidInput)
        ));
    }

    #[tokio::test]
    async fn topic_visibility_is_written_to_the_server() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{"result":"success","msg":""}"#.to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{"result":"success","msg":""}"#.to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{"result":"success","msg":""}"#.to_owned(),
            ),
            (
                StatusCode::BAD_REQUEST,
                r#"{"result":"error","code":"BAD_REQUEST","msg":"Invalid channel ID"}"#.to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .set_topic_visibility(5, "release plan", TopicVisibilityChoice::Followed)
            .await
            .expect("follow topic");
        let request = requests.recv().expect("follow request");
        assert!(request.starts_with("POST /api/v1/user_topics HTTP/1.1"));
        assert!(request.contains("stream_id=5"));
        assert!(request.contains("topic=release+plan") || request.contains("topic=release%20plan"));
        assert!(request.contains("visibility_policy=3"));
        assert!(!request.contains(API_KEY));

        client
            .set_topic_visibility(5, "release plan", TopicVisibilityChoice::Inherit)
            .await
            .expect("reset topic");
        let request = requests.recv().expect("reset request");
        assert!(request.contains("visibility_policy=0"));

        // The channel's "general chat" is the empty topic name.
        client
            .set_topic_visibility(5, "", TopicVisibilityChoice::Inherit)
            .await
            .expect("reset general chat");
        let request = requests.recv().expect("general chat request");
        assert!(request.contains("topic=&") || request.ends_with("topic="));
        assert!(request.contains("visibility_policy=0"));

        assert!(
            client
                .set_topic_visibility(9, "x", TopicVisibilityChoice::Muted)
                .await
                .is_err()
        );
        assert!(matches!(
            client
                .set_topic_visibility(5, "  ", TopicVisibilityChoice::Muted)
                .await,
            Err(MessageApiError::InvalidInput)
        ));
    }

    #[tokio::test]
    async fn message_source_requests_raw_markdown() {
        let responses = vec![(
            StatusCode::OK,
            r#"{"result":"success","message":{"id":55,"content":"**bold** text"}}"#.to_owned(),
        )];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        let source = client.fetch_message_source(55).await.expect("source");
        assert_eq!(source, "**bold** text");
        let request = requests.recv().expect("source request");
        assert!(request.starts_with("GET /api/v1/messages/55?apply_markdown=false HTTP/1.1"));
        assert!(!request.contains(API_KEY));
        assert!(matches!(
            client.fetch_message_source(0).await,
            Err(MessageApiError::InvalidInput)
        ));
    }

    #[tokio::test]
    async fn read_receipts_list_readers_and_degrade_gracefully() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{"result":"success","msg":"","user_ids":[9,3,3,-1,5]}"#.to_owned(),
            ),
            (
                StatusCode::BAD_REQUEST,
                r#"{"result":"error","code":"BAD_REQUEST","msg":"Read receipts are disabled for this organization."}"#
                    .to_owned(),
            ),
            (StatusCode::NOT_FOUND, "<html>missing</html>".to_owned()),
            (
                StatusCode::TOO_MANY_REQUESTS,
                r#"{"result":"error","code":"RATE_LIMIT_HIT","msg":"slow down"}"#.to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        assert_eq!(
            client.fetch_read_receipts(55).await.expect("readers"),
            ReadReceipts::Readers(vec![3, 5, 9])
        );
        let request = requests.recv().expect("receipt request");
        assert!(request.starts_with("GET /api/v1/messages/55/read_receipts HTTP/1.1"));
        assert!(!request.contains(API_KEY));

        assert_eq!(
            client.fetch_read_receipts(55).await.expect("disabled"),
            ReadReceipts::Unavailable
        );
        assert_eq!(
            client.fetch_read_receipts(55).await.expect("old server"),
            ReadReceipts::Unavailable
        );
        assert!(matches!(
            client.fetch_read_receipts(55).await,
            Err(MessageApiError::Rejected { code }) if code == "RATE_LIMIT_HIT"
        ));
        assert!(matches!(
            client.fetch_read_receipts(0).await,
            Err(MessageApiError::InvalidInput)
        ));
    }

    #[tokio::test]
    async fn direct_messages_and_rejections_are_typed() {
        let responses = vec![(
            StatusCode::BAD_REQUEST,
            r#"{"result":"error","code":"BAD_REQUEST","msg":"invalid recipient"}"#.to_owned(),
        )];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");
        let error = client
            .send_message(
                OutgoingMessage::Direct {
                    recipient_ids: vec![9, 10],
                    content: "Hello".to_owned(),
                },
                None,
            )
            .await
            .expect_err("server rejection");

        assert!(matches!(
            error,
            MessageApiError::Rejected { ref code } if code == "BAD_REQUEST"
        ));
        let request = requests.recv().expect("direct request");
        assert!(request.contains("type=direct"));
        assert!(request.contains("to=%5B9%2C10%5D"));
        assert!(!format!("{error:?} {error}").contains(API_KEY));
    }

    #[tokio::test]
    async fn topic_updates_encode_the_requested_propagation() {
        let responses = vec![
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .update_message_topic(42, " macOS native ", TopicPropagation::ChangeAll)
            .await
            .expect("rename topic");
        client
            .update_message_topic(43, "UI polish", TopicPropagation::ChangeOne)
            .await
            .expect("move one message");

        let rename = requests.recv().expect("rename request");
        assert!(rename.starts_with("PATCH /api/v1/messages/42 HTTP/1.1"));
        assert!(rename.contains("topic=macOS+native"));
        assert!(rename.contains("propagate_mode=change_all"));

        let moved = requests.recv().expect("move request");
        assert!(moved.starts_with("PATCH /api/v1/messages/43 HTTP/1.1"));
        assert!(moved.contains("topic=UI+polish"));
        assert!(moved.contains("propagate_mode=change_one"));
    }

    #[tokio::test]
    async fn daily_message_actions_follow_the_zulip_protocol() {
        let responses = vec![
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
            (StatusCode::OK, r#"{"result":"success"}"#.to_owned()),
            (
                StatusCode::OK,
                r#"{"result":"success","messages":[42]}"#.to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{"result":"success","messages":[42]}"#.to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        client
            .update_message_content(42, "Edited **content**")
            .await
            .expect("edit content");
        client.delete_message(43).await.expect("delete message");
        client
            .update_reaction(42, "thumbs_up", MessageWriteOperation::Add)
            .await
            .expect("add reaction");
        client
            .update_reaction(42, "thumbs_up", MessageWriteOperation::Remove)
            .await
            .expect("remove reaction");
        client
            .update_message_flag(&[42], MessageFlag::Starred, MessageWriteOperation::Add)
            .await
            .expect("star message");
        client
            .update_message_flag(&[42], MessageFlag::Read, MessageWriteOperation::Remove)
            .await
            .expect("mark unread");

        let edit = requests.recv().expect("edit request");
        assert!(edit.starts_with("PATCH /api/v1/messages/42 HTTP/1.1"));
        assert!(edit.contains("content=Edited+"));
        assert!(edit.contains("content"));

        let delete = requests.recv().expect("delete request");
        assert!(delete.starts_with("DELETE /api/v1/messages/43 HTTP/1.1"));

        let add_reaction = requests.recv().expect("add reaction request");
        assert!(add_reaction.starts_with("POST /api/v1/messages/42/reactions HTTP/1.1"));
        assert!(add_reaction.contains("emoji_name=thumbs_up"));

        let remove_reaction = requests.recv().expect("remove reaction request");
        assert!(remove_reaction.starts_with("DELETE /api/v1/messages/42/reactions HTTP/1.1"));
        assert!(remove_reaction.contains("emoji_name=thumbs_up"));

        let star = requests.recv().expect("star request");
        assert!(star.contains("op=add"));
        assert!(star.contains("flag=starred"));

        let unread = requests.recv().expect("unread request");
        assert!(unread.contains("op=remove"));
        assert!(unread.contains("flag=read"));
    }

    #[tokio::test]
    async fn special_narrows_history_and_topics_follow_the_zulip_protocol() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "found_oldest":true,
                    "found_newest":false,
                    "messages":[{
                        "id":40,
                        "sender_id":7,
                        "sender_full_name":"Maya Chen",
                        "timestamp":1770000000,
                        "content":"<p>Earlier</p>",
                        "type":"private",
                        "display_recipient":[{"id":7},{"id":9}]
                    }]
                }"#
                .to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "topics":[
                        {"max_id":44,"name":"macOS"},
                        {"max_id":40,"name":"Rust core"}
                    ]
                }"#
                .to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        let page = client
            .fetch_older_messages(ConversationTarget::Unread, 42, 25)
            .await
            .expect("older unread messages");
        assert_eq!(page.messages[0].id, 40);
        assert!(page.found_oldest);
        assert!(!page.found_newest);

        let topics = client.fetch_topics(5).await.expect("channel topics");
        assert_eq!(topics.len(), 2);
        assert_eq!(topics[0].stream_id, 5);
        assert_eq!(topics[0].name, "macOS");
        assert_eq!(topics[0].max_message_id, 44);

        let history = requests.recv().expect("history request");
        assert!(history.starts_with("GET /api/v1/messages?"));
        assert!(history.contains("anchor=42"));
        assert!(history.contains("include_anchor=false"));
        assert!(history.contains("num_before=25"));
        assert!(history.contains("%22operand%22%3A%22unread%22"));

        let topics_request = requests.recv().expect("topics request");
        assert!(topics_request.starts_with("GET /api/v1/users/me/5/topics?"));
        assert!(topics_request.contains("allow_empty_topic_name=true"));
    }

    #[tokio::test]
    async fn search_and_message_context_use_bounded_server_narrows() {
        let responses = vec![
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "found_oldest":true,
                    "found_newest":true,
                    "messages":[
                        {
                            "id":42,
                            "sender_id":7,
                            "sender_full_name":"Maya Chen",
                            "timestamp":1770000000,
                            "content":"<p>Native macOS client</p>",
                            "type":"stream",
                            "stream_id":5,
                            "subject":"Rust core",
                            "display_recipient":"engineering"
                        },
                        {
                            "id":43,
                            "sender_id":9,
                            "sender_full_name":"Hua Hai",
                            "timestamp":1770000001,
                            "content":"<p>Search result</p>",
                            "type":"private",
                            "display_recipient":[{"id":7},{"id":9}]
                        }
                    ]
                }"#
                .to_owned(),
            ),
            (
                StatusCode::OK,
                r#"{
                    "result":"success",
                    "found_oldest":false,
                    "found_newest":false,
                    "messages":[{
                        "id":42,
                        "sender_id":7,
                        "sender_full_name":"Maya Chen",
                        "timestamp":1770000000,
                        "content":"<p>Native macOS client</p>",
                        "type":"stream",
                        "stream_id":5,
                        "subject":"Rust core",
                        "display_recipient":"engineering"
                    }]
                }"#
                .to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        let results = client
            .search_messages(" native macOS ", 20)
            .await
            .expect("search messages");
        assert_eq!(
            results.iter().map(|message| message.id).collect::<Vec<_>>(),
            vec![43, 42]
        );

        let page = client
            .fetch_message_context(
                ConversationTarget::Topic {
                    stream_id: 5,
                    topic: "Rust core".to_owned(),
                },
                42,
                10,
                10,
            )
            .await
            .expect("message context");
        assert_eq!(page.messages[0].id, 42);

        let search = requests.recv().expect("search request");
        assert!(search.starts_with("GET /api/v1/messages?"));
        assert!(search.contains("anchor=newest"));
        assert!(search.contains("num_before=20"));
        assert!(search.contains("%22operator%22%3A%22search%22"));
        assert!(search.contains("native+macOS"));

        let context = requests.recv().expect("context request");
        assert!(context.contains("anchor=42"));
        assert!(context.contains("include_anchor=true"));
        assert!(context.contains("num_before=10"));
        assert!(context.contains("num_after=10"));
        assert!(context.contains("%22operator%22%3A%22topic%22"));
    }

    #[tokio::test]
    async fn unread_messages_after_a_lost_queue_are_fetched_oldest_first() {
        let responses = vec![(
            StatusCode::OK,
            r#"{
                "result":"success",
                "found_oldest":false,
                "found_newest":true,
                "messages":[
                    {
                        "id":44,
                        "sender_id":9,
                        "sender_full_name":"Hua Hai",
                        "timestamp":1770000002,
                        "content":"<p>Are you there?</p>",
                        "type":"private",
                        "flags":[],
                        "display_recipient":[{"id":7},{"id":9}]
                    }
                ]
            }"#
            .to_owned(),
        )];
        let (server, requests) = spawn_mock(responses);
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        let missed = client
            .fetch_unread_after(43, 50)
            .await
            .expect("unread messages");
        assert_eq!(
            missed.iter().map(|message| message.id).collect::<Vec<_>>(),
            vec![44]
        );

        let request = requests.recv().expect("unread request");
        assert!(request.contains("anchor=43"));
        assert!(request.contains("include_anchor=false"));
        assert!(request.contains("num_before=0"));
        assert!(request.contains("num_after=50"));
        assert!(request.contains("%22operand%22%3A%22unread%22"));
        assert!(client.fetch_unread_after(0, 50).await.is_err());
    }

    #[test]
    fn browsing_targets_encode_stable_narrows() {
        assert_eq!(
            ConversationTarget::Combined
                .narrow_json()
                .expect("combined"),
            "[]"
        );
        for (target, expected) in [
            (ConversationTarget::Mentions, "\"mentioned\""),
            (ConversationTarget::Starred, "\"starred\""),
            (ConversationTarget::Unread, "\"unread\""),
        ] {
            assert!(
                target
                    .narrow_json()
                    .expect("special narrow")
                    .contains(expected)
            );
        }
    }

    #[tokio::test]
    async fn invalid_message_input_fails_before_networking() {
        let (server, _) = spawn_mock(Vec::new());
        let client = MessageClient::new(&server, "maya@example.com", SecretString::new(API_KEY))
            .expect("message client");

        assert!(
            client
                .fetch_conversation(ConversationTarget::Combined, 0)
                .await
                .is_err()
        );
        assert!(client.search_messages(" ", 20).await.is_err());
        assert!(client.search_messages("valid", 101).await.is_err());
        assert!(
            client
                .fetch_message_context(ConversationTarget::Combined, 0, 10, 10)
                .await
                .is_err()
        );
        assert!(client.mark_read(&[]).await.is_err());
        assert!(client.update_message_content(0, "valid").await.is_err());
        assert!(client.update_message_content(42, " \0 ").await.is_err());
        assert!(client.delete_message(0).await.is_err());
        assert!(
            client
                .update_reaction(42, "\n", MessageWriteOperation::Add)
                .await
                .is_err()
        );
        assert!(
            client
                .update_message_flag(&[], MessageFlag::Starred, MessageWriteOperation::Add)
                .await
                .is_err()
        );
        assert!(
            client
                .update_message_topic(0, "Topic", TopicPropagation::ChangeOne)
                .await
                .is_err()
        );
        assert!(
            client
                .update_message_topic(42, " \n ", TopicPropagation::ChangeAll)
                .await
                .is_err()
        );
        assert!(
            client
                .send_message(
                    OutgoingMessage::Direct {
                        recipient_ids: Vec::new(),
                        content: " ".to_owned(),
                    },
                    None,
                )
                .await
                .is_err()
        );
    }

    fn assert_fetch_request(request: &str) {
        assert!(request.starts_with("GET /api/v1/messages?"));
        assert!(request.contains("anchor=newest"));
        assert!(request.contains("include_anchor=true"));
        assert!(request.contains("num_before=50"));
        assert!(request.contains("narrow="));
        assert!(request.contains("apply_markdown=true"));
    }

    fn assert_send_request(request: &str) {
        assert!(request.starts_with("POST /api/v1/messages HTTP/1.1"));
        assert!(request.contains("type=stream"));
        assert!(request.contains("to=5"));
        assert!(request.contains("topic=Rust+core"));
        assert!(request.contains("queue_id=queue-fixture"));
        assert!(request.contains("local_id=local-1"));
    }

    fn assert_read_request(request: &str) {
        assert!(request.starts_with("POST /api/v1/messages/flags HTTP/1.1"));
        assert!(request.contains("messages=%5B42%2C43%5D"));
        assert!(request.contains("op=add"));
        assert!(request.contains("flag=read"));
    }

    fn spawn_mock(responses: Vec<(StatusCode, String)>) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback mock server");
        let address = listener.local_addr().expect("mock server address");
        let (sender, receiver) = mpsc::channel();

        thread::spawn(move || {
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_http_request(&mut stream);
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

    fn read_http_request(stream: &mut std::net::TcpStream) -> String {
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
