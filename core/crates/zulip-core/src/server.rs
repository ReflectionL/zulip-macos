//! Zulip server URL validation and unauthenticated capability discovery.

use std::time::Duration;

use futures_util::StreamExt;
use reqwest::{Client, redirect::Policy};
use serde::Deserialize;
use thiserror::Error;
use url::{Host, Url};

const SERVER_SETTINGS_PATH: &str = "api/v1/server_settings";
pub(crate) const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(12);
const MAX_REDIRECTS: usize = 5;
const MAX_SETTINGS_BYTES: usize = 1_048_576;
const MAX_SETTINGS_BYTES_U64: u64 = 1_048_576;

/// A normalized Zulip server root that has passed transport policy checks.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerBaseUrl(Url);

impl ServerBaseUrl {
    /// Parses a user-entered server address.
    ///
    /// A missing scheme becomes HTTPS. Plain HTTP is accepted only for
    /// loopback development servers.
    ///
    /// # Errors
    ///
    /// Returns [`ServerUrlError`] when the address is malformed, contains
    /// credentials or route components, or violates the HTTPS policy.
    pub fn parse(input: &str) -> Result<Self, ServerUrlError> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(ServerUrlError::Empty);
        }

        let candidate = if trimmed.contains("://") {
            trimmed.to_owned()
        } else {
            format!("https://{trimmed}")
        };

        let mut url = Url::parse(&candidate).map_err(|_| ServerUrlError::Invalid)?;
        if url.host().is_none() {
            return Err(ServerUrlError::MissingHost);
        }
        if !url.username().is_empty() || url.password().is_some() {
            return Err(ServerUrlError::UserInfoNotAllowed);
        }
        if url.query().is_some() || url.fragment().is_some() {
            return Err(ServerUrlError::QueryOrFragmentNotAllowed);
        }
        if !matches!(url.path(), "" | "/") {
            return Err(ServerUrlError::PathNotAllowed);
        }

        match url.scheme() {
            "https" => {}
            "http" if is_loopback(&url) => {}
            "http" => return Err(ServerUrlError::InsecureTransport),
            scheme => return Err(ServerUrlError::UnsupportedScheme(scheme.to_owned())),
        }

        url.set_path("/");
        Ok(Self(url))
    }

    /// Returns the normalized URL including its trailing slash.
    #[must_use]
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    pub(crate) fn endpoint(&self, path: &str) -> Url {
        self.0
            .join(path)
            .expect("a validated base URL always accepts a relative API path")
    }
}

/// Problems found before any server request is attempted.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ServerUrlError {
    /// No server address was supplied.
    #[error("enter a Zulip server address")]
    Empty,
    /// The address is not a valid absolute URL after applying the HTTPS default.
    #[error("the server address is not a valid URL")]
    Invalid,
    /// The address does not contain a host.
    #[error("the server address must include a host")]
    MissingHost,
    /// Embedded usernames or passwords could leak through URL handling.
    #[error("user information is not allowed in the server address")]
    UserInfoNotAllowed,
    /// Login/deep-link paths are not accepted as server roots.
    #[error("enter the server root without a path")]
    PathNotAllowed,
    /// Query parameters and fragments are not part of a server root.
    #[error("query parameters and fragments are not allowed")]
    QueryOrFragmentNotAllowed,
    /// Production servers must use HTTPS.
    #[error("HTTPS is required except for loopback development servers")]
    InsecureTransport,
    /// Only HTTP(S) server addresses are meaningful.
    #[error("unsupported URL scheme: {0}")]
    UnsupportedScheme(String),
}

/// A non-password authentication method advertised by the Zulip server.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExternalAuthenticationMethod {
    /// Stable server-provided identifier.
    pub name: String,
    /// User-facing provider label.
    pub display_name: String,
    /// Relative or absolute URL used to begin login.
    pub login_url: String,
    /// Optional relative or absolute provider icon.
    pub display_icon: Option<String>,
}

/// Authentication options needed to construct the native login screen.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticationCapabilities {
    /// Whether email/username plus password authentication is available.
    pub password: bool,
    /// API-key authentication is supported by standard Zulip servers.
    pub api_key: bool,
    /// Whether the login identifier must use email address syntax.
    pub require_email_format_usernames: bool,
    /// External methods are recorded for later browser-SSO support.
    pub external: Vec<ExternalAuthenticationMethod>,
}

/// Sanitized server metadata returned to the application.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerSettings {
    /// User-entered server root after normalization.
    pub base_url: String,
    /// Server-advertised canonical organization URL, validated with the same
    /// transport policy, or the input base when absent.
    pub canonical_url: String,
    /// Organization display name when the root identifies one organization.
    pub organization_name: Option<String>,
    /// Zulip server version.
    pub zulip_version: String,
    /// Monotonic Zulip API feature level; old servers imply zero.
    pub zulip_feature_level: u64,
    /// Whether the server says this client is incompatible.
    pub is_incompatible: bool,
    /// Authentication choices for the login UI.
    pub authentication: AuthenticationCapabilities,
}

/// Errors produced while discovering a server.
#[derive(Debug, Error)]
pub enum ServerDiscoveryError {
    /// The initial server address failed local validation.
    #[error(transparent)]
    InvalidUrl(#[from] ServerUrlError),
    /// DNS, TLS, timeout, redirect, or connection failure.
    #[error("could not connect securely to the Zulip server: {message}")]
    Transport {
        /// Sanitized transport error.
        message: String,
    },
    /// The endpoint returned a non-success HTTP status.
    #[error("server settings returned HTTP {0}")]
    HttpStatus(u16),
    /// The response declared an unexpectedly large body.
    #[error("server settings response is too large")]
    ResponseTooLarge,
    /// The response was not compatible Zulip server-settings JSON.
    #[error("the server did not return valid Zulip settings: {0}")]
    InvalidResponse(&'static str),
}

/// Async HTTP client for the unauthenticated server discovery endpoint.
#[derive(Clone, Debug)]
pub struct ServerDiscoveryClient {
    http: Client,
}

impl ServerDiscoveryClient {
    /// Builds a client using native trust roots and a bounded redirect policy.
    ///
    /// # Errors
    ///
    /// Returns [`ServerDiscoveryError::Transport`] if the built-in TLS and
    /// HTTP client configuration cannot be initialized.
    pub fn new() -> Result<Self, ServerDiscoveryError> {
        let http = secure_http_client(Some(DEFAULT_REQUEST_TIMEOUT))
            .map_err(|message| ServerDiscoveryError::Transport { message })?;
        Ok(Self { http })
    }

    /// Fetches and validates the public Zulip `server_settings` document.
    ///
    /// # Errors
    ///
    /// Returns [`ServerDiscoveryError`] for invalid input, transport or TLS
    /// failures, non-success status codes, oversized bodies, and malformed or
    /// unsafe server-settings documents.
    pub async fn discover(&self, input: &str) -> Result<ServerSettings, ServerDiscoveryError> {
        let base_url = ServerBaseUrl::parse(input)?;
        let response = self
            .http
            .get(base_url.endpoint(SERVER_SETTINGS_PATH))
            .send()
            .await
            .map_err(|error| ServerDiscoveryError::Transport {
                message: error.without_url().to_string(),
            })?;

        if !response.status().is_success() {
            return Err(ServerDiscoveryError::HttpStatus(response.status().as_u16()));
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_SETTINGS_BYTES_U64)
        {
            return Err(ServerDiscoveryError::ResponseTooLarge);
        }

        let mut bytes = Vec::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|error| ServerDiscoveryError::Transport {
                message: error.without_url().to_string(),
            })?;
            if bytes.len().saturating_add(chunk.len()) > MAX_SETTINGS_BYTES {
                return Err(ServerDiscoveryError::ResponseTooLarge);
            }
            bytes.extend_from_slice(&chunk);
        }

        let document: ServerSettingsDocument = serde_json::from_slice(&bytes)
            .map_err(|_| ServerDiscoveryError::InvalidResponse("invalid JSON"))?;
        document.into_settings(&base_url)
    }
}

impl Default for ServerDiscoveryClient {
    fn default() -> Self {
        Self::new().expect("the built-in HTTP client configuration is valid")
    }
}

#[derive(Debug, Default, Deserialize)]
struct AuthenticationMethodsDocument {
    #[serde(default)]
    password: bool,
}

#[derive(Debug, Deserialize)]
struct ExternalAuthenticationDocument {
    name: String,
    display_name: String,
    login_url: String,
    #[serde(default)]
    display_icon: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ServerSettingsDocument {
    result: Option<String>,
    #[serde(default)]
    authentication_methods: AuthenticationMethodsDocument,
    #[serde(default)]
    external_authentication_methods: Vec<ExternalAuthenticationDocument>,
    #[serde(default)]
    email_auth_enabled: bool,
    #[serde(default)]
    require_email_format_usernames: bool,
    #[serde(default)]
    zulip_feature_level: u64,
    zulip_version: Option<String>,
    #[serde(default)]
    is_incompatible: bool,
    realm_url: Option<String>,
    realm_uri: Option<String>,
    realm_name: Option<String>,
}

impl ServerSettingsDocument {
    fn into_settings(
        self,
        base_url: &ServerBaseUrl,
    ) -> Result<ServerSettings, ServerDiscoveryError> {
        if self
            .result
            .as_deref()
            .is_some_and(|result| result != "success")
        {
            return Err(ServerDiscoveryError::InvalidResponse(
                "result was not success",
            ));
        }

        let zulip_version = self
            .zulip_version
            .filter(|version| !version.trim().is_empty())
            .ok_or(ServerDiscoveryError::InvalidResponse(
                "missing zulip_version",
            ))?;

        let canonical_url = self
            .realm_url
            .or(self.realm_uri)
            .map(|url| ServerBaseUrl::parse(&url))
            .transpose()
            .map_err(|_| ServerDiscoveryError::InvalidResponse("unsafe canonical realm URL"))?
            .unwrap_or_else(|| base_url.clone());

        Ok(ServerSettings {
            base_url: base_url.as_str().to_owned(),
            canonical_url: canonical_url.as_str().to_owned(),
            organization_name: self.realm_name,
            zulip_version,
            zulip_feature_level: self.zulip_feature_level,
            is_incompatible: self.is_incompatible,
            authentication: AuthenticationCapabilities {
                password: self.authentication_methods.password || self.email_auth_enabled,
                api_key: true,
                require_email_format_usernames: self.require_email_format_usernames,
                external: self
                    .external_authentication_methods
                    .into_iter()
                    .map(|method| ExternalAuthenticationMethod {
                        name: method.name,
                        display_name: method.display_name,
                        login_url: method.login_url,
                        display_icon: method.display_icon,
                    })
                    .collect(),
            },
        })
    }
}

fn redirect_transport_allowed(target: &Url, previous: &[Url]) -> bool {
    if target.scheme() == "https" {
        return true;
    }

    target.scheme() == "http"
        && is_loopback(target)
        && previous
            .iter()
            .all(|url| url.scheme() == "http" && is_loopback(url))
}

pub(crate) fn secure_http_client(timeout: Option<Duration>) -> Result<Client, String> {
    let mut builder = Client::builder()
        .user_agent(concat!("zulip-mac/", env!("CARGO_PKG_VERSION")))
        // Drop idle connections early so a request never reuses one the server or
        // network closed while the app was idle (it would stall until the timeout).
        .pool_idle_timeout(Duration::from_secs(20))
        .tcp_keepalive(Duration::from_secs(30))
        .redirect(Policy::custom(|attempt| {
            if attempt.previous().len() >= MAX_REDIRECTS {
                return attempt.stop();
            }

            if redirect_transport_allowed(attempt.url(), attempt.previous()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }));
    if let Some(timeout) = timeout {
        builder = builder.timeout(timeout);
    }

    builder
        .build()
        .map_err(|error| error.without_url().to_string())
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    }
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
        ServerBaseUrl, ServerDiscoveryClient, ServerDiscoveryError, ServerUrlError,
        redirect_transport_allowed,
    };
    use url::Url;

    const SUCCESS_RESPONSE: &str = r#"{
        "result": "success",
        "authentication_methods": {"password": true},
        "external_authentication_methods": [{
            "name": "github",
            "display_name": "GitHub",
            "login_url": "/accounts/login/social/github",
            "display_icon": null
        }],
        "email_auth_enabled": true,
        "require_email_format_usernames": true,
        "zulip_feature_level": 321,
        "zulip_version": "10.2",
        "is_incompatible": false,
        "realm_name": "Fixture Realm"
    }"#;

    #[test]
    fn normalizes_https_server_roots() {
        let server = ServerBaseUrl::parse(" Example.ZulipChat.com/ ").expect("valid URL");
        assert_eq!(server.as_str(), "https://example.zulipchat.com/");
    }

    #[test]
    fn allows_plain_http_only_for_loopback_development() {
        assert!(ServerBaseUrl::parse("http://localhost:9991").is_ok());
        assert!(ServerBaseUrl::parse("http://127.0.0.1:9991").is_ok());
        assert!(ServerBaseUrl::parse("http://[::1]:9991").is_ok());
        assert_eq!(
            ServerBaseUrl::parse("http://zulip.example.com"),
            Err(ServerUrlError::InsecureTransport)
        );
    }

    #[test]
    fn rejects_urls_that_can_leak_or_misroute_input() {
        assert_eq!(
            ServerBaseUrl::parse("https://person:secret@example.com"),
            Err(ServerUrlError::UserInfoNotAllowed)
        );
        assert_eq!(
            ServerBaseUrl::parse("https://example.com/login"),
            Err(ServerUrlError::PathNotAllowed)
        );
        assert_eq!(
            ServerBaseUrl::parse("https://example.com?next=/login"),
            Err(ServerUrlError::QueryOrFragmentNotAllowed)
        );
        assert_eq!(
            ServerBaseUrl::parse("file:///tmp/zulip"),
            Err(ServerUrlError::MissingHost)
        );
    }

    #[test]
    fn secure_servers_cannot_redirect_into_loopback_http() {
        let secure_origin = Url::parse("https://zulip.example.com/").expect("URL");
        let loopback_target = Url::parse("http://127.0.0.1:9991/").expect("URL");
        assert!(!redirect_transport_allowed(
            &loopback_target,
            &[secure_origin]
        ));

        let loopback_origin = Url::parse("http://localhost:9991/").expect("URL");
        assert!(redirect_transport_allowed(
            &loopback_target,
            &[loopback_origin]
        ));
    }

    #[tokio::test]
    async fn discovers_capabilities_from_mock_server() {
        let (server_url, request) = spawn_mock(StatusCode::OK, SUCCESS_RESPONSE, None);
        let settings = ServerDiscoveryClient::default()
            .discover(&server_url)
            .await
            .expect("fixture discovery succeeds");

        assert_eq!(
            request.recv().expect("request path"),
            "GET /api/v1/server_settings HTTP/1.1"
        );
        assert_eq!(settings.base_url, server_url);
        assert_eq!(settings.canonical_url, server_url);
        assert_eq!(settings.organization_name.as_deref(), Some("Fixture Realm"));
        assert_eq!(settings.zulip_version, "10.2");
        assert_eq!(settings.zulip_feature_level, 321);
        assert!(settings.authentication.password);
        assert!(settings.authentication.api_key);
        assert!(settings.authentication.require_email_format_usernames);
        assert_eq!(settings.authentication.external.len(), 1);
    }

    #[tokio::test]
    async fn reports_http_and_invalid_zulip_responses() {
        let (not_found_url, _) = spawn_mock(StatusCode::NOT_FOUND, "not found", None);
        let error = ServerDiscoveryClient::default()
            .discover(&not_found_url)
            .await
            .expect_err("404 must fail");
        assert!(matches!(error, ServerDiscoveryError::HttpStatus(404)));

        let (invalid_url, _) = spawn_mock(StatusCode::OK, r#"{"result":"success"}"#, None);
        let error = ServerDiscoveryClient::default()
            .discover(&invalid_url)
            .await
            .expect_err("non-Zulip JSON must fail");
        assert!(matches!(
            error,
            ServerDiscoveryError::InvalidResponse("missing zulip_version")
        ));
    }

    #[tokio::test]
    async fn refuses_redirect_downgrades_to_remote_http() {
        let (server_url, _) = spawn_mock(
            StatusCode::FOUND,
            "",
            Some("http://zulip.example.com/api/v1/server_settings"),
        );
        let error = ServerDiscoveryClient::default()
            .discover(&server_url)
            .await
            .expect_err("redirect downgrade must fail");

        assert!(matches!(error, ServerDiscoveryError::HttpStatus(302)));
    }

    fn spawn_mock(
        status: StatusCode,
        body: &'static str,
        location: Option<&'static str>,
    ) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback mock server");
        let address = listener.local_addr().expect("mock server address");
        let (sender, receiver) = mpsc::channel();

        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let mut request = [0_u8; 4_096];
            let length = stream.read(&mut request).expect("read request");
            let request = String::from_utf8_lossy(&request[..length]);
            let _ = sender.send(request.lines().next().unwrap_or_default().to_owned());

            let reason = status.canonical_reason().unwrap_or("Unknown");
            let location_header = location
                .map(|value| format!("Location: {value}\r\n"))
                .unwrap_or_default();
            let response = format!(
                "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\n{}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                status.as_u16(),
                reason,
                location_header,
                body.len(),
                body
            );
            stream
                .write_all(response.as_bytes())
                .expect("write response");
        });

        (format!("http://{address}/"), receiver)
    }
}
