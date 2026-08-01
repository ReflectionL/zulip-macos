//! Authenticated conversation fetch, send, and read-state APIs.

use futures_util::StreamExt;
use reqwest::{Client, Response};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use thiserror::Error;

use crate::{
    auth::SecretString,
    server::{DEFAULT_REQUEST_TIMEOUT, ServerBaseUrl, ServerUrlError, secure_http_client},
    sync::MessageSummary,
};

const MESSAGES_PATH: &str = "api/v1/messages";
const MESSAGE_FLAGS_PATH: &str = "api/v1/messages/flags";
const TOPICS_PATH_PREFIX: &str = "api/v1/users/me";
const MAX_MESSAGES_RESPONSE_BYTES: usize = 16 * 1_048_576;
const MAX_WRITE_RESPONSE_BYTES: usize = 1_048_576;
const MAX_FETCH_MESSAGES: u16 = 1_000;
const MAX_SEARCH_MESSAGES: u16 = 100;
const MAX_SEARCH_QUERY_BYTES: usize = 512;
const MAX_TOPIC_NAME_BYTES: usize = 1_024;

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
#[derive(Clone, Debug, Eq, PartialEq)]
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

    /// Adds the personal `read` flag to the supplied messages.
    ///
    /// # Errors
    ///
    /// Returns [`MessageApiError`] for empty/invalid identifiers, transport,
    /// rejection, size, or response failures.
    pub async fn mark_read(&self, message_ids: &[i64]) -> Result<(), MessageApiError> {
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
                ("op", "add"),
                ("flag", "read"),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        let document: ApiResultDocument =
            decode_response(response, MAX_WRITE_RESPONSE_BYTES).await?;
        document.validate_result()
    }
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
        })
    }
}

#[derive(Debug, Deserialize)]
struct ApiErrorDocument {
    code: Option<String>,
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
        ConversationTarget, MessageApiError, MessageClient, OutgoingMessage, TopicPropagation,
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
                        "display_recipient":"engineering"
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
