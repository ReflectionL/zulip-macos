//! Password/API-key authentication with redacted, zeroizing secrets.

use std::fmt;

use futures_util::StreamExt;
use reqwest::{Client, Response, StatusCode};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use thiserror::Error;
use zeroize::Zeroize;

use crate::server::{DEFAULT_REQUEST_TIMEOUT, ServerBaseUrl, ServerUrlError, secure_http_client};

const FETCH_API_KEY_PATH: &str = "api/v1/fetch_api_key";
const OWN_USER_PATH: &str = "api/v1/users/me";
const MAX_AUTH_RESPONSE_BYTES: usize = 262_144;

/// A secret string whose bytes are cleared when dropped and whose debug output
/// is always redacted.
#[derive(Eq, PartialEq)]
pub struct SecretString(String);

impl SecretString {
    /// Wraps a secret value for short-lived in-memory use.
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Borrows the secret for an authenticated request.
    #[must_use]
    pub fn expose_secret(&self) -> &str {
        &self.0
    }

    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for SecretString {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretString([REDACTED])")
    }
}

impl Drop for SecretString {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Validated identity plus the API key needed to create an authenticated
/// session. The key must be moved into platform credential storage promptly.
#[derive(Eq, PartialEq)]
pub struct AuthenticatedAccount {
    /// Normalized server root.
    pub server_url: String,
    /// Zulip API email used for Basic authentication.
    pub email: String,
    /// Stable Zulip user ID.
    pub user_id: i64,
    /// User-facing name.
    pub full_name: String,
    /// API key; never included in debug output.
    pub api_key: SecretString,
}

impl fmt::Debug for AuthenticatedAccount {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthenticatedAccount")
            .field("server_url", &self.server_url)
            .field("email", &self.email)
            .field("user_id", &self.user_id)
            .field("full_name", &self.full_name)
            .field("api_key", &"[REDACTED]")
            .finish()
    }
}

/// Safe authentication failures suitable for UI mapping.
#[derive(Debug, Error)]
pub enum AuthenticationError {
    /// The server URL violates discovery transport policy.
    #[error(transparent)]
    InvalidServer(#[from] ServerUrlError),
    /// A required identifier or secret is missing or structurally unsafe.
    #[error("enter valid authentication details")]
    InvalidInput,
    /// The server rejected the supplied password or API key.
    #[error("the username, password, or API key was not accepted")]
    InvalidCredentials,
    /// Network, timeout, redirect, or TLS failure.
    #[error("could not connect securely to the Zulip server: {message}")]
    Transport {
        /// Sanitized transport message.
        message: String,
    },
    /// Unexpected non-authentication HTTP response.
    #[error("authentication returned HTTP {0}")]
    HttpStatus(u16),
    /// Oversized or malformed authentication response.
    #[error("the server returned an invalid authentication response: {0}")]
    InvalidResponse(&'static str),
}

/// Async client for password exchange and direct API-key validation.
#[derive(Clone, Debug)]
pub struct AuthenticationClient {
    http: Client,
}

impl AuthenticationClient {
    /// Builds a client with the same TLS and redirect policy as discovery.
    ///
    /// # Errors
    ///
    /// Returns [`AuthenticationError::Transport`] if the HTTP client cannot be
    /// initialized.
    pub fn new() -> Result<Self, AuthenticationError> {
        let http = secure_http_client(Some(DEFAULT_REQUEST_TIMEOUT))
            .map_err(|message| AuthenticationError::Transport { message })?;
        Ok(Self { http })
    }

    /// Exchanges a Zulip username/password for an API key and verifies the
    /// resulting identity.
    ///
    /// # Errors
    ///
    /// Returns [`AuthenticationError`] when input validation, the password
    /// exchange, TLS/network transport, or identity verification fails.
    pub async fn authenticate_with_password(
        &self,
        server: &str,
        username: &str,
        password: SecretString,
    ) -> Result<AuthenticatedAccount, AuthenticationError> {
        validate_identifier(username, false)?;
        if password.is_empty() {
            return Err(AuthenticationError::InvalidInput);
        }

        let base_url = ServerBaseUrl::parse(server)?;
        let response = self
            .http
            .post(base_url.endpoint(FETCH_API_KEY_PATH))
            .form(&[
                ("username", username),
                ("password", password.expose_secret()),
            ])
            .send()
            .await
            .map_err(transport_error)?;
        validate_auth_status(response.status())?;

        let exchange: ApiKeyDocument = decode_response(response).await?;
        if exchange
            .result
            .as_deref()
            .is_some_and(|value| value != "success")
        {
            return Err(AuthenticationError::InvalidCredentials);
        }
        if exchange.api_key.is_empty() || exchange.email.trim().is_empty() {
            return Err(AuthenticationError::InvalidResponse(
                "missing API key or email",
            ));
        }

        self.authenticate_with_api_key_at_base(
            &base_url,
            &exchange.email,
            SecretString::new(exchange.api_key),
        )
        .await
    }

    /// Validates a user-supplied API key using the authenticated own-user
    /// endpoint.
    ///
    /// # Errors
    ///
    /// Returns [`AuthenticationError`] when input validation, TLS/network
    /// transport, credentials, or the own-user response is invalid.
    pub async fn authenticate_with_api_key(
        &self,
        server: &str,
        email: &str,
        api_key: SecretString,
    ) -> Result<AuthenticatedAccount, AuthenticationError> {
        let base_url = ServerBaseUrl::parse(server)?;
        self.authenticate_with_api_key_at_base(&base_url, email, api_key)
            .await
    }

    async fn authenticate_with_api_key_at_base(
        &self,
        base_url: &ServerBaseUrl,
        email: &str,
        api_key: SecretString,
    ) -> Result<AuthenticatedAccount, AuthenticationError> {
        validate_identifier(email, true)?;
        if api_key.is_empty() {
            return Err(AuthenticationError::InvalidInput);
        }

        let response = self
            .http
            .get(base_url.endpoint(OWN_USER_PATH))
            .basic_auth(email, Some(api_key.expose_secret()))
            .send()
            .await
            .map_err(transport_error)?;
        validate_auth_status(response.status())?;

        let user: OwnUserDocument = decode_response(response).await?;
        if user
            .result
            .as_deref()
            .is_some_and(|value| value != "success")
            || user.email.trim().is_empty()
            || user.full_name.trim().is_empty()
        {
            return Err(AuthenticationError::InvalidResponse(
                "missing own-user identity",
            ));
        }

        Ok(AuthenticatedAccount {
            server_url: base_url.as_str().to_owned(),
            email: user.email,
            user_id: user.user_id,
            full_name: user.full_name,
            api_key,
        })
    }
}

impl Default for AuthenticationClient {
    fn default() -> Self {
        Self::new().expect("the built-in HTTP client configuration is valid")
    }
}

#[derive(Debug, Deserialize)]
struct ApiKeyDocument {
    result: Option<String>,
    api_key: String,
    email: String,
}

#[derive(Debug, Deserialize)]
struct OwnUserDocument {
    result: Option<String>,
    email: String,
    full_name: String,
    user_id: i64,
}

fn validate_identifier(value: &str, reject_colon: bool) -> Result<(), AuthenticationError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.chars().any(char::is_control)
        || (reject_colon && trimmed.contains(':'))
    {
        return Err(AuthenticationError::InvalidInput);
    }
    Ok(())
}

fn validate_auth_status(status: StatusCode) -> Result<(), AuthenticationError> {
    if status.is_success() {
        return Ok(());
    }
    if matches!(
        status,
        StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
    ) {
        return Err(AuthenticationError::InvalidCredentials);
    }
    Err(AuthenticationError::HttpStatus(status.as_u16()))
}

fn transport_error(error: reqwest::Error) -> AuthenticationError {
    AuthenticationError::Transport {
        message: error.without_url().to_string(),
    }
}

async fn decode_response<T: DeserializeOwned>(
    response: Response,
) -> Result<T, AuthenticationError> {
    if response
        .content_length()
        .is_some_and(|length| length > u64::try_from(MAX_AUTH_RESPONSE_BYTES).unwrap_or(u64::MAX))
    {
        return Err(AuthenticationError::InvalidResponse(
            "response is too large",
        ));
    }

    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(transport_error)?;
        if bytes.len().saturating_add(chunk.len()) > MAX_AUTH_RESPONSE_BYTES {
            return Err(AuthenticationError::InvalidResponse(
                "response is too large",
            ));
        }
        bytes.extend_from_slice(&chunk);
    }

    serde_json::from_slice(&bytes).map_err(|_| AuthenticationError::InvalidResponse("invalid JSON"))
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

    use super::{AuthenticationClient, AuthenticationError, SecretString};

    const API_KEY: &str = "fixture-api-key-do-not-log";
    const PASSWORD: &str = "fixture-password-do-not-log";

    #[tokio::test]
    async fn password_exchange_is_verified_and_secrets_are_redacted() {
        let responses = vec![
            (
                StatusCode::OK,
                format!(
                    r#"{{"result":"success","api_key":"{API_KEY}","email":"maya@example.com"}}"#
                ),
            ),
            (
                StatusCode::OK,
                r#"{"result":"success","email":"maya@example.com","full_name":"Maya Chen","user_id":101}"#
                    .to_owned(),
            ),
        ];
        let (server, requests) = spawn_mock(responses);
        let account = AuthenticationClient::default()
            .authenticate_with_password(&server, "maya@example.com", SecretString::new(PASSWORD))
            .await
            .expect("password authentication succeeds");

        assert_eq!(account.user_id, 101);
        assert_eq!(account.full_name, "Maya Chen");
        assert_eq!(account.api_key.expose_secret(), API_KEY);

        let first = requests.recv().expect("password request");
        assert!(first.starts_with("POST /api/v1/fetch_api_key HTTP/1.1"));
        assert!(first.contains("username=maya%40example.com"));
        assert!(first.contains("password=fixture-password-do-not-log"));

        let second = requests.recv().expect("identity request");
        assert!(second.starts_with("GET /api/v1/users/me HTTP/1.1"));
        assert!(
            second
                .to_ascii_lowercase()
                .contains("authorization: basic ")
        );

        let debug = format!("{account:?}");
        assert!(!debug.contains(API_KEY));
        assert!(debug.contains("[REDACTED]"));
    }

    #[tokio::test]
    async fn direct_api_key_is_validated() {
        let (server, requests) = spawn_mock(vec![(
            StatusCode::OK,
            r#"{"result":"success","email":"theo@example.com","full_name":"Theo Martin","user_id":102}"#
                .to_owned(),
        )]);
        let account = AuthenticationClient::default()
            .authenticate_with_api_key(&server, "theo@example.com", SecretString::new(API_KEY))
            .await
            .expect("API key authentication succeeds");

        assert_eq!(account.email, "theo@example.com");
        assert_eq!(account.api_key.expose_secret(), API_KEY);
        assert!(
            requests
                .recv()
                .expect("request")
                .starts_with("GET /api/v1/users/me HTTP/1.1")
        );
    }

    #[tokio::test]
    async fn authentication_errors_never_include_secrets() {
        let (server, _) = spawn_mock(vec![(
            StatusCode::UNAUTHORIZED,
            r#"{"result":"error","msg":"invalid credentials"}"#.to_owned(),
        )]);
        let error = AuthenticationClient::default()
            .authenticate_with_api_key(&server, "ari@example.com", SecretString::new(API_KEY))
            .await
            .expect_err("invalid API key fails");

        assert!(matches!(error, AuthenticationError::InvalidCredentials));
        let rendered = format!("{error:?} {error}");
        assert!(!rendered.contains(API_KEY));
        assert!(!rendered.contains(PASSWORD));
    }

    #[test]
    fn rejects_empty_and_basic_auth_unsafe_identifiers() {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let error = runtime
            .block_on(AuthenticationClient::default().authenticate_with_api_key(
                "https://example.com",
                "bad:name@example.com",
                SecretString::new(API_KEY),
            ))
            .expect_err("colon is rejected before networking");
        assert!(matches!(error, AuthenticationError::InvalidInput));
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
        let mut buffer = [0_u8; 2_048];
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
