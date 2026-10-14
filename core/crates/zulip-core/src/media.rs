//! Bounded attachment upload and authenticated uploaded-media caching.

use std::{
    fmt::Write as _,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

use futures_util::StreamExt;
use reqwest::{
    Client, Response,
    header::CONTENT_TYPE,
    multipart::{Form, Part},
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::{
    fs::{self, OpenOptions},
    io::AsyncWriteExt,
};
use url::Url;

use crate::{
    auth::SecretString,
    server::{
        DEFAULT_REQUEST_TIMEOUT, ServerBaseUrl, ServerUrlError, secure_transfer_client,
        secure_upload_client,
    },
};

const UPLOAD_PATH: &str = "api/v1/user_uploads";
const UPLOAD_API_PATH_PREFIX: &str = "api/v1/user_uploads/";
const UPLOAD_ROUTE_PREFIX: &str = "/user_uploads/";
const TEMPORARY_ROUTE_PREFIX: &str = "/user_uploads/temporary/";
const MAX_UPLOAD_BYTES: usize = 25 * 1_048_576;
const MAX_DOWNLOAD_BYTES: usize = 32 * 1_048_576;
const MAX_PUBLIC_IMAGE_BYTES: usize = 16 * 1_048_576;
const AVATAR_ROUTE_PREFIX: &str = "/user_avatars/";
/// Where the server proxies images linked from other sites; no credentials needed.
const EXTERNAL_CONTENT_ROUTE_PREFIX: &str = "/external_content/";
const MAX_JSON_BYTES: usize = 1_048_576;
/// Deadline for a whole picture download; a stalled connection
/// is cut off much sooner by the client's read timeout.
const TRANSFER_DEADLINE: Duration = Duration::from_mins(3);
/// Deadline for sending one file: 25 MiB over a slow uplink takes minutes.
const UPLOAD_DEADLINE: Duration = Duration::from_mins(10);
const MAX_FILENAME_BYTES: usize = 1_024;
static TEMPORARY_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// Result of a successful Zulip attachment upload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UploadedAttachment {
    /// Server-normalized display name.
    pub filename: String,
    /// Same-origin Zulip uploaded-file route.
    pub url: String,
    /// Markdown link ready to insert into a composer.
    pub markdown: String,
}

/// One authenticated uploaded file copied into the private account cache.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CachedMedia {
    /// Same-origin route supplied by message content.
    pub remote_url: String,
    /// Cache-owned local file URL safe to expose to Swift.
    pub local_url: String,
    /// Sanitized response MIME type, if present.
    pub content_type: Option<String>,
    /// Bounded number of cached bytes.
    pub byte_count: u64,
    /// Whether the file already existed in the account cache.
    pub cache_hit: bool,
}

/// Failures safe to present without exposing credentials, local paths, or server text.
#[derive(Debug, Error)]
pub enum MediaError {
    /// The server root violated the shared transport policy.
    #[error(transparent)]
    InvalidServer(#[from] ServerUrlError),
    /// A credential, account identifier, filename, or remote route was invalid.
    #[error("enter valid attachment details")]
    InvalidInput,
    /// The selected file is unavailable or is not a regular file.
    #[error("the selected file is unavailable")]
    FileUnavailable,
    /// The selected file exceeds the simple-upload policy.
    #[error("attachments must be 25 MiB or smaller")]
    UploadTooLarge,
    /// DNS, TLS, timeout, redirect, or connection failure.
    #[error("could not communicate with the Zulip server: {message}")]
    Transport {
        /// Sanitized transport error.
        message: String,
    },
    /// A server or temporary media endpoint returned an unclassified status.
    #[error("attachment request returned HTTP {0}")]
    HttpStatus(u16),
    /// Zulip rejected the operation with a stable API code.
    #[error("Zulip rejected the attachment operation: {code}")]
    Rejected {
        /// Stable server error code, excluding server-rendered text.
        code: String,
    },
    /// An API response exceeded its bounded memory budget.
    #[error("attachment response is too large")]
    ResponseTooLarge,
    /// A downloaded file exceeded its on-disk bound.
    #[error("downloaded media must be 32 MiB or smaller")]
    DownloadTooLarge,
    /// A response was malformed or requested an unsafe route.
    #[error("the server returned an invalid attachment response")]
    InvalidResponse,
    /// The server would not hand out a download link for an uploaded file.
    #[error("the server gave no download link ({0})")]
    LinkUnavailable(String),
    /// The download itself was refused.
    #[error("the picture download was refused (HTTP {0})")]
    DownloadRefused(u16),
    /// The download was a web page or JSON document, not a picture.
    #[error("the server sent a web page instead of the image (content type {0})")]
    NotAnImage(String),
    /// The private cache could not be created or updated atomically.
    #[error("the media cache is unavailable")]
    CacheUnavailable,
}

/// Authenticated Zulip media client scoped to one account cache partition.
#[derive(Debug)]
pub struct MediaClient {
    http: Client,
    upload_http: Client,
    base_url: ServerBaseUrl,
    email: String,
    api_key: SecretString,
    account_cache_directory: PathBuf,
}

impl MediaClient {
    /// Creates a media client without touching the filesystem.
    ///
    /// # Errors
    ///
    /// Returns [`MediaError`] for invalid server, credentials, account ID, or
    /// a non-absolute cache root.
    pub fn new(
        server: &str,
        email: impl Into<String>,
        api_key: SecretString,
        cache_root: &Path,
        account_id: &str,
    ) -> Result<Self, MediaError> {
        let base_url = ServerBaseUrl::parse(server)?;
        let email = email.into();
        if email.trim().is_empty()
            || email.contains(':')
            || email.chars().any(char::is_control)
            || api_key.expose_secret().is_empty()
            || account_id.trim().is_empty()
            || account_id.chars().any(char::is_control)
            || !cache_root.is_absolute()
        {
            return Err(MediaError::InvalidInput);
        }
        let http = secure_transfer_client().map_err(|message| MediaError::Transport { message })?;
        let upload_http =
            secure_upload_client().map_err(|message| MediaError::Transport { message })?;
        let account_partition = sha256_hex(account_id.as_bytes());
        Ok(Self {
            http,
            upload_http,
            base_url,
            email,
            api_key,
            account_cache_directory: cache_root.join(account_partition),
        })
    }

    /// Uploads one regular file using Zulip's simple multipart endpoint.
    ///
    /// # Errors
    ///
    /// Returns [`MediaError`] for unavailable/oversized files, invalid names,
    /// transport failures, server rejection, or unsafe response routes.
    pub async fn upload_file(
        &self,
        local_path: &Path,
        display_filename: &str,
    ) -> Result<UploadedAttachment, MediaError> {
        let filename = validated_filename(display_filename)?;
        if !local_path.is_absolute() {
            return Err(MediaError::InvalidInput);
        }
        let metadata = fs::symlink_metadata(local_path)
            .await
            .map_err(|_| MediaError::FileUnavailable)?;
        if !metadata.file_type().is_file() {
            return Err(MediaError::FileUnavailable);
        }
        if metadata.len() > MAX_UPLOAD_BYTES as u64 {
            return Err(MediaError::UploadTooLarge);
        }
        let bytes = fs::read(local_path)
            .await
            .map_err(|_| MediaError::FileUnavailable)?;
        if bytes.len() > MAX_UPLOAD_BYTES {
            return Err(MediaError::UploadTooLarge);
        }

        let part = Part::bytes(bytes).file_name(filename.clone());
        let response = self
            .upload_http
            .post(self.base_url.endpoint(UPLOAD_PATH))
            .timeout(UPLOAD_DEADLINE)
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .multipart(Form::new().part("filename", part))
            .send()
            .await
            .map_err(transport_error)?;
        let document: UploadDocument = decode_json(response).await?;
        document.validate_result()?;
        let remote_url = document
            .url
            .or(document.uri)
            .ok_or(MediaError::InvalidResponse)?;
        let validated = self.validated_uploaded_route(&remote_url)?;
        // The link must reach the message exactly as the server wrote it. Zulip
        // finds the uploads a message refers to (to show their previews and to
        // let the recipients open them) by matching the raw path, so a name
        // re-encoded by the URL parser, such as a screenshot called
        // "截屏2026-10-14 15.13.06.png", would leave the picture without a preview.
        let url = verbatim_upload_route(&remote_url).unwrap_or(validated);
        let filename = match document.filename {
            Some(server_filename) => validated_filename(&server_filename)?,
            None => filename,
        };
        let markdown = format!("[{}]({})", markdown_label(&filename), markdown_url(&url));
        Ok(UploadedAttachment {
            filename,
            url,
            markdown,
        })
    }

    /// Resolves a protected Zulip upload and stores it in the account cache.
    ///
    /// Only same-origin `/user_uploads/` message URLs are accepted for
    /// authenticated downloads. Public images (same-origin `/user_avatars/` or
    /// `/external_content/`, or any HTTPS host such as Gravatar or an image
    /// linked from another site) are fetched without credentials and capped at
    /// 16 MiB. The short-lived
    /// download URL is consumed immediately and never persisted.
    ///
    /// # Errors
    ///
    /// Returns [`MediaError`] for unsafe URLs, authentication/transport
    /// failures, oversized downloads, or atomic cache failures.
    pub async fn load_media(&self, remote_url: &str) -> Result<CachedMedia, MediaError> {
        if let Some(public_url) = self.validated_public_image(remote_url) {
            return self.load_public_image(public_url).await;
        }
        let remote_url = self.validated_uploaded_route(remote_url)?;
        let digest = sha256_hex(remote_url.as_bytes());
        let final_path = self.account_cache_directory.join(format!("{digest}.media"));
        self.prepare_cache_directory().await?;

        if let Some(byte_count) = valid_cached_file(&final_path).await? {
            if cached_file_is_text(&final_path).await {
                // An earlier build cached an error page as if it were the picture.
                let _ = fs::remove_file(&final_path).await;
            } else {
                return cached_media(remote_url, final_path, None, byte_count, true);
            }
        }

        let response = match self.temporary_download(&remote_url).await {
            Ok(response) => response,
            // Zulip also serves an upload straight to an API-authenticated
            // request (an S3-backed server redirects to storage, and the
            // client drops the credentials when it follows the redirect).
            Err(
                error @ (MediaError::LinkUnavailable(_)
                | MediaError::DownloadRefused(_)
                | MediaError::Transport { .. }),
            ) => self
                .authenticated_download(&remote_url)
                .await
                .ok_or(error)?,
            Err(error) => return Err(error),
        };
        if response
            .content_length()
            .is_some_and(|length| length > MAX_DOWNLOAD_BYTES as u64)
        {
            return Err(MediaError::DownloadTooLarge);
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(sanitized_content_type);
        if let Some(value) = content_type
            .as_deref()
            .filter(|value| is_text_document(value))
        {
            return Err(MediaError::NotAnImage(value.to_owned()));
        }
        let byte_count = self
            .write_download_atomically(response, &final_path, &digest, MAX_DOWNLOAD_BYTES)
            .await?;
        cached_media(remote_url, final_path, content_type, byte_count, false)
    }

    /// Downloads one public image (avatar or organization icon) without credentials.
    async fn load_public_image(&self, url: Url) -> Result<CachedMedia, MediaError> {
        let key = url.as_str().to_owned();
        let digest = sha256_hex(key.as_bytes());
        let final_path = self.account_cache_directory.join(format!("{digest}.media"));
        self.prepare_cache_directory().await?;

        if let Some(byte_count) = valid_cached_file(&final_path).await? {
            return cached_media(key, final_path, None, byte_count, true);
        }

        let response = self
            .http
            .get(url)
            .timeout(TRANSFER_DEADLINE)
            .send()
            .await
            .map_err(transport_error)?;
        if !response.status().is_success() {
            return Err(MediaError::DownloadRefused(response.status().as_u16()));
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_PUBLIC_IMAGE_BYTES as u64)
        {
            return Err(MediaError::DownloadTooLarge);
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(sanitized_content_type);
        if !content_type
            .as_deref()
            .is_some_and(|value| value.to_ascii_lowercase().starts_with("image/"))
        {
            return Err(MediaError::InvalidResponse);
        }
        let byte_count = self
            .write_download_atomically(response, &final_path, &digest, MAX_PUBLIC_IMAGE_BYTES)
            .await?;
        cached_media(key, final_path, content_type, byte_count, false)
    }

    /// Asks the server for a short-lived download link and opens it.
    async fn temporary_download(&self, remote_url: &str) -> Result<Response, MediaError> {
        let api_path = format!(
            "{UPLOAD_API_PATH_PREFIX}{}",
            remote_url.trim_start_matches(UPLOAD_ROUTE_PREFIX)
        );
        let response = self
            .http
            .get(self.base_url.endpoint(&api_path))
            .timeout(DEFAULT_REQUEST_TIMEOUT)
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .send()
            .await
            .map_err(transport_error)?;
        let document: TemporaryUrlDocument = decode_json(response)
            .await
            .map_err(|error| MediaError::LinkUnavailable(error.to_string()))?;
        document
            .validate_result()
            .map_err(|error| MediaError::LinkUnavailable(error.to_string()))?;
        let temporary_url = self
            .validated_temporary_url(&document.url)
            .map_err(|error| MediaError::LinkUnavailable(error.to_string()))?;
        let response = self
            .http
            .get(temporary_url)
            .timeout(TRANSFER_DEADLINE)
            .send()
            .await
            .map_err(transport_error)?;
        if !response.status().is_success() {
            return Err(MediaError::DownloadRefused(response.status().as_u16()));
        }
        Ok(response)
    }

    /// Downloads an upload with the account's credentials on the request itself.
    async fn authenticated_download(&self, remote_url: &str) -> Option<Response> {
        let response = self
            .http
            .get(self.base_url.endpoint(remote_url.trim_start_matches('/')))
            .timeout(TRANSFER_DEADLINE)
            .basic_auth(&self.email, Some(self.api_key.expose_secret()))
            .send()
            .await
            .ok()?;
        response.status().is_success().then_some(response)
    }

    fn validated_public_image(&self, input: &str) -> Option<Url> {
        let input = input.trim();
        if input.is_empty() || input.chars().any(char::is_control) || input.contains('\\') {
            return None;
        }
        let url = if input.starts_with('/') {
            self.base_url
                .as_str()
                .parse::<Url>()
                .ok()?
                .join(input)
                .ok()?
        } else {
            Url::parse(input).ok()?
        };
        if !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || url.path().starts_with(UPLOAD_ROUTE_PREFIX)
            || unsafe_path(url.path())
        {
            return None;
        }
        let allowed = if same_origin(&url, self.base_url.as_str()) {
            url.path().starts_with(AVATAR_ROUTE_PREFIX)
                || url.path().starts_with(EXTERNAL_CONTENT_ROUTE_PREFIX)
        } else {
            url.scheme() == "https"
        };
        allowed.then_some(url)
    }

    async fn prepare_cache_directory(&self) -> Result<(), MediaError> {
        fs::create_dir_all(&self.account_cache_directory)
            .await
            .map_err(|_| MediaError::CacheUnavailable)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                &self.account_cache_directory,
                std::fs::Permissions::from_mode(0o700),
            )
            .await
            .map_err(|_| MediaError::CacheUnavailable)?;
        }
        Ok(())
    }

    async fn write_download_atomically(
        &self,
        response: Response,
        final_path: &Path,
        digest: &str,
        limit: usize,
    ) -> Result<u64, MediaError> {
        let sequence = TEMPORARY_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temporary_path = self
            .account_cache_directory
            .join(format!(".{digest}.{sequence}.part"));
        let result = self
            .stream_download(response, &temporary_path, final_path, limit)
            .await;
        if result.is_err() {
            let _ = fs::remove_file(&temporary_path).await;
        }
        result
    }

    async fn stream_download(
        &self,
        response: Response,
        temporary_path: &Path,
        final_path: &Path,
        limit: usize,
    ) -> Result<u64, MediaError> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(temporary_path)
            .await
            .map_err(|_| MediaError::CacheUnavailable)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(std::fs::Permissions::from_mode(0o600))
                .await
                .map_err(|_| MediaError::CacheUnavailable)?;
        }

        let mut byte_count = 0_usize;
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(transport_error)?;
            byte_count = byte_count.saturating_add(chunk.len());
            if byte_count > limit {
                return Err(MediaError::DownloadTooLarge);
            }
            file.write_all(&chunk)
                .await
                .map_err(|_| MediaError::CacheUnavailable)?;
        }
        file.sync_all()
            .await
            .map_err(|_| MediaError::CacheUnavailable)?;
        drop(file);
        fs::rename(temporary_path, final_path)
            .await
            .map_err(|_| MediaError::CacheUnavailable)?;
        u64::try_from(byte_count).map_err(|_| MediaError::DownloadTooLarge)
    }

    fn validated_uploaded_route(&self, input: &str) -> Result<String, MediaError> {
        let input = input.trim();
        if input.is_empty() || input.chars().any(char::is_control) || input.contains('\\') {
            return Err(MediaError::InvalidInput);
        }
        let url = if input.starts_with('/') {
            self.base_url
                .as_str()
                .parse::<Url>()
                .expect("validated server URL parses")
                .join(input)
                .map_err(|_| MediaError::InvalidInput)?
        } else {
            Url::parse(input).map_err(|_| MediaError::InvalidInput)?
        };
        let url = original_upload_url(url);
        if !same_origin(&url, self.base_url.as_str())
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !url.path().starts_with(UPLOAD_ROUTE_PREFIX)
            || url.path().starts_with(TEMPORARY_ROUTE_PREFIX)
            || unsafe_path(url.path())
        {
            return Err(MediaError::InvalidInput);
        }
        Ok(url.path().to_owned())
    }

    fn validated_temporary_url(&self, input: &str) -> Result<Url, MediaError> {
        let input = input.trim();
        let url = if input.starts_with('/') {
            self.base_url
                .as_str()
                .parse::<Url>()
                .expect("validated server URL parses")
                .join(input)
                .map_err(|_| MediaError::InvalidResponse)?
        } else {
            Url::parse(input).map_err(|_| MediaError::InvalidResponse)?
        };
        let same_server = same_origin(&url, self.base_url.as_str());
        if !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || !(url.scheme() == "https" || same_server)
            || (same_server && !url.path().starts_with(TEMPORARY_ROUTE_PREFIX))
        {
            return Err(MediaError::InvalidResponse);
        }
        Ok(url)
    }
}

#[derive(Debug, Deserialize)]
struct UploadDocument {
    result: Option<String>,
    code: Option<String>,
    url: Option<String>,
    uri: Option<String>,
    filename: Option<String>,
}

impl UploadDocument {
    fn validate_result(&self) -> Result<(), MediaError> {
        validate_api_result(self.result.as_deref(), self.code.as_deref())
    }
}

#[derive(Debug, Deserialize)]
struct TemporaryUrlDocument {
    result: Option<String>,
    code: Option<String>,
    url: String,
}

impl TemporaryUrlDocument {
    fn validate_result(&self) -> Result<(), MediaError> {
        validate_api_result(self.result.as_deref(), self.code.as_deref())
    }
}

#[derive(Debug, Deserialize)]
struct ApiErrorDocument {
    code: Option<String>,
}

fn validate_api_result(result: Option<&str>, code: Option<&str>) -> Result<(), MediaError> {
    if result == Some("success") {
        return Ok(());
    }
    Err(MediaError::Rejected {
        code: sanitized_code(code),
    })
}

async fn decode_json<T: DeserializeOwned>(response: Response) -> Result<T, MediaError> {
    let status = response.status();
    if response
        .content_length()
        .is_some_and(|length| length > MAX_JSON_BYTES as u64)
    {
        return Err(MediaError::ResponseTooLarge);
    }
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(transport_error)?;
        if bytes.len().saturating_add(chunk.len()) > MAX_JSON_BYTES {
            return Err(MediaError::ResponseTooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        if let Some(code) = serde_json::from_slice::<ApiErrorDocument>(&bytes)
            .ok()
            .and_then(|document| document.code)
        {
            return Err(MediaError::Rejected {
                code: sanitized_code(Some(&code)),
            });
        }
        return Err(MediaError::HttpStatus(status.as_u16()));
    }
    serde_json::from_slice(&bytes).map_err(|_| MediaError::InvalidResponse)
}

async fn valid_cached_file(path: &Path) -> Result<Option<u64>, MediaError> {
    let metadata = match fs::symlink_metadata(path).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(MediaError::CacheUnavailable),
    };
    if !metadata.file_type().is_file() || metadata.len() > MAX_DOWNLOAD_BYTES as u64 {
        return Err(MediaError::CacheUnavailable);
    }
    Ok(Some(metadata.len()))
}

/// Whether a response type is a web page or data document rather than a picture.
fn is_text_document(content_type: &str) -> bool {
    let lower = content_type.to_ascii_lowercase();
    lower.starts_with("text/")
        || lower.starts_with("application/json")
        || lower.starts_with("application/xhtml")
}

/// Whether a cached download begins like an HTML page or JSON error body.
async fn cached_file_is_text(path: &Path) -> bool {
    use tokio::io::AsyncReadExt as _;
    let Ok(mut file) = fs::File::open(path).await else {
        return false;
    };
    let mut head = [0_u8; 16];
    let Ok(count) = file.read(&mut head).await else {
        return false;
    };
    let head = head[..count].to_ascii_lowercase();
    let head = head.trim_ascii_start();
    head.starts_with(b"<!doctype html") || head.starts_with(b"<html") || head.starts_with(b"{")
}

fn cached_media(
    remote_url: String,
    path: PathBuf,
    content_type: Option<String>,
    byte_count: u64,
    cache_hit: bool,
) -> Result<CachedMedia, MediaError> {
    let local_url = Url::from_file_path(path)
        .map_err(|()| MediaError::CacheUnavailable)?
        .to_string();
    Ok(CachedMedia {
        remote_url,
        local_url,
        content_type,
        byte_count,
        cache_hit,
    })
}

fn validated_filename(filename: &str) -> Result<String, MediaError> {
    let filename = filename.trim();
    if filename.is_empty()
        || filename == "."
        || filename == ".."
        || filename.len() > MAX_FILENAME_BYTES
        || filename.chars().any(char::is_control)
        || filename.contains('/')
        || filename.contains('\\')
    {
        return Err(MediaError::InvalidInput);
    }
    Ok(filename.to_owned())
}

fn markdown_label(filename: &str) -> String {
    filename
        .replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]")
}

fn markdown_url(url: &str) -> String {
    url.replace('(', "%28")
        .replace(')', "%29")
        .replace(' ', "%20")
}

/// The server's own spelling of a same-origin upload route (`/user_uploads/…`),
/// for routes already checked by `validated_uploaded_route`.
fn verbatim_upload_route(remote_url: &str) -> Option<String> {
    let route = remote_url.trim();
    (route.starts_with(UPLOAD_ROUTE_PREFIX) && !route.contains(['?', '#']))
        .then(|| route.to_owned())
}

/// Maps a picture preview route to the uploaded file it was made from.
///
/// Message content can point at a preview instead of the upload: Zulip 9 and
/// later use `/user_uploads/thumbnail/<realm>/<xx>/<id>/<name>/<size>.webp`,
/// older servers `/thumbnail?url=user_uploads%2F…&size=…`. The API only hands out
/// download links for the upload itself, so the preview route is translated to it.
/// Any other URL is returned unchanged.
fn original_upload_url(mut url: Url) -> Url {
    const THUMBNAIL_PREFIX: &str = "/user_uploads/thumbnail/";
    let original_path = if url.path() == "/thumbnail" {
        url.query_pairs()
            .find(|(name, _)| name == "url")
            .map(|(_, value)| value.trim_start_matches('/').to_owned())
            .filter(|target| target.starts_with("user_uploads/") && !target.contains('?'))
            .map(|target| format!("/{target}"))
    } else {
        url.path().strip_prefix(THUMBNAIL_PREFIX).and_then(|rest| {
            // realm, two-character prefix, random id, file name, then the size.
            let segments: Vec<&str> = rest.split('/').collect();
            (segments.len() >= 5)
                .then(|| format!("/user_uploads/{}", segments[..segments.len() - 1].join("/")))
        })
    };
    if let Some(path) = original_path {
        url.set_path(&path);
        url.set_query(None);
    }
    url
}

fn same_origin(url: &Url, base: &str) -> bool {
    let Ok(base) = Url::parse(base) else {
        return false;
    };
    url.scheme() == base.scheme()
        && url.host_str() == base.host_str()
        && url.port_or_known_default() == base.port_or_known_default()
}

fn unsafe_path(path: &str) -> bool {
    path.split('/').any(|segment| {
        let lower = segment.to_ascii_lowercase();
        segment == "."
            || segment == ".."
            || lower == "%2e"
            || lower == "%2e%2e"
            || lower.contains("%2f")
            || lower.contains("%5c")
    })
}

fn sanitized_code(code: Option<&str>) -> String {
    code.filter(|value| {
        !value.is_empty()
            && value.len() <= 128
            && value
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || character == '_')
    })
    .unwrap_or("UNKNOWN")
    .to_owned()
}

fn sanitized_content_type(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()
        && value.len() <= 256
        && value
            .chars()
            .all(|character| character.is_ascii_graphic() || character == ' '))
    .then(|| value.to_owned())
}

fn sha256_hex(value: &[u8]) -> String {
    let digest = Sha256::digest(value);
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        write!(&mut output, "{byte:02x}").expect("writing to a String cannot fail");
    }
    output
}

fn transport_error(error: reqwest::Error) -> MediaError {
    MediaError::Transport {
        message: describe_transport_error(error),
    }
}

/// reqwest's own message is only "error sending request"; the reason (timed
/// out, connection reset, TLS) is in the error's sources. None of them carry
/// the URL or credentials.
fn describe_transport_error(error: reqwest::Error) -> String {
    if error.is_timeout() {
        return "the transfer timed out".to_owned();
    }
    let error = error.without_url();
    let mut message = error.to_string();
    let mut source = std::error::Error::source(&error);
    while let Some(cause) = source {
        let text = cause.to_string();
        if !text.is_empty() && !message.contains(&text) {
            message.push_str(": ");
            message.push_str(&text);
        }
        source = cause.source();
    }
    message
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        path::Path,
        sync::mpsc,
        thread,
    };

    use reqwest::StatusCode;
    use tempfile::TempDir;

    use super::{MAX_DOWNLOAD_BYTES, MAX_UPLOAD_BYTES, MediaClient, MediaError};
    use crate::auth::SecretString;

    const API_KEY: &str = "fixture-media-key-do-not-log";

    #[tokio::test]
    async fn uploads_authenticated_multipart_and_normalizes_markdown() {
        let responses = vec![MockResponse::json(
            StatusCode::OK,
            r#"{"result":"success","filename":"report [final].txt","url":"/user_uploads/1/ab/report.txt"}"#,
        )];
        let (server, requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let selected_file = fixture.path().join("selected.txt");
        tokio::fs::write(&selected_file, b"private fixture")
            .await
            .expect("write selected file");
        let client = media_client(&server, &fixture, "account-a");

        let uploaded = client
            .upload_file(&selected_file, "report [final].txt")
            .await
            .expect("upload file");

        assert_eq!(uploaded.filename, "report [final].txt");
        assert_eq!(uploaded.url, "/user_uploads/1/ab/report.txt");
        assert_eq!(
            uploaded.markdown,
            r"[report \[final\].txt](/user_uploads/1/ab/report.txt)"
        );
        let request = requests.recv().expect("upload request");
        assert!(request.starts_with("POST /api/v1/user_uploads HTTP/1.1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: basic ")
        );
        assert!(request.contains("name=\"filename\""));
        assert!(request.contains("filename=\"report [final].txt\""));
        assert!(request.contains("private fixture"));
        assert!(!request.contains(API_KEY));
    }

    #[tokio::test]
    async fn uploaded_screenshot_links_keep_the_server_spelling() {
        let responses = vec![MockResponse::json(
            StatusCode::OK,
            r#"{"result":"success","filename":"截屏2026-10-14 15.13.06.png","url":"/user_uploads/1/ab/xy/截屏2026-10-14-15.13.06.png"}"#,
        )];
        let (server, requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let selected_file = fixture.path().join("shot.png");
        tokio::fs::write(&selected_file, b"png")
            .await
            .expect("write selected file");
        let client = media_client(&server, &fixture, "account-a");

        let uploaded = client
            .upload_file(&selected_file, "截屏2026-10-14 15.13.06.png")
            .await
            .expect("upload screenshot");

        assert_eq!(
            uploaded.url,
            "/user_uploads/1/ab/xy/截屏2026-10-14-15.13.06.png"
        );
        assert_eq!(
            uploaded.markdown,
            "[截屏2026-10-14 15.13.06.png](/user_uploads/1/ab/xy/截屏2026-10-14-15.13.06.png)"
        );
        let _ = requests.recv().expect("upload request");
    }

    #[tokio::test]
    async fn rejects_oversized_and_unsafe_uploads_before_network_access() {
        let fixture = TempDir::new().expect("fixture directory");
        let selected_file = fixture.path().join("large.bin");
        let file = std::fs::File::create(&selected_file).expect("create sparse fixture");
        file.set_len((MAX_UPLOAD_BYTES + 1) as u64)
            .expect("size sparse fixture");
        let client = media_client("http://127.0.0.1:9/", &fixture, "account-a");

        assert!(matches!(
            client.upload_file(&selected_file, "large.bin").await,
            Err(MediaError::UploadTooLarge)
        ));
        assert!(matches!(
            client.upload_file(&selected_file, "../large.bin").await,
            Err(MediaError::InvalidInput)
        ));
        assert!(!format!("{:?}", MediaError::UploadTooLarge).contains(API_KEY));
    }

    #[tokio::test]
    async fn uploads_have_no_read_timeout_and_report_why_they_failed() {
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client("http://127.0.0.1:9/", &fixture, "account-a");
        // reqwest's read timeout also covers the time spent sending the body, so
        // a slow upload must not use the client that has one.
        assert!(format!("{:?}", client.http).contains("read_timeout"));
        assert!(!format!("{:?}", client.upload_http).contains("read_timeout"));

        let selected_file = fixture.path().join("shot.png");
        std::fs::write(&selected_file, b"fixture-png").expect("write fixture");
        let Err(MediaError::Transport { message }) =
            client.upload_file(&selected_file, "shot.png").await
        else {
            panic!("a refused connection is a transport error");
        };
        // More than reqwest's bare "error sending request": the cause follows.
        assert!(message.contains(": "), "{message}");
        assert!(!message.contains(API_KEY));
        assert!(!message.contains("127.0.0.1"));
    }

    #[tokio::test]
    async fn downloads_with_one_authenticated_resolution_then_hits_private_cache() {
        let responses = vec![
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/token/image.png"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "image/png", b"fixture-png".to_vec()),
        ];
        let (server, requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        let first = client
            .load_media("/user_uploads/1/ab/image.png")
            .await
            .expect("download media");
        let second = client
            .load_media("/user_uploads/1/ab/image.png")
            .await
            .expect("load cached media");

        assert!(!first.cache_hit);
        assert_eq!(first.content_type.as_deref(), Some("image/png"));
        assert_eq!(first.byte_count, 11);
        assert!(first.local_url.starts_with("file:///"));
        assert!(second.cache_hit);
        assert_eq!(second.local_url, first.local_url);

        let resolution = requests.recv().expect("temporary URL request");
        assert!(resolution.starts_with("GET /api/v1/user_uploads/1/ab/image.png HTTP/1.1"));
        assert!(
            resolution
                .to_ascii_lowercase()
                .contains("authorization: basic ")
        );
        let download = requests.recv().expect("download request");
        assert!(download.starts_with("GET /user_uploads/temporary/token/image.png HTTP/1.1"));
        assert!(!download.to_ascii_lowercase().contains("authorization:"));

        let local_path = url::Url::parse(&first.local_url)
            .expect("local URL")
            .to_file_path()
            .expect("cache path");
        assert_eq!(
            tokio::fs::read(local_path).await.expect("cached bytes"),
            b"fixture-png"
        );
    }

    #[tokio::test]
    async fn an_upload_without_a_download_link_is_fetched_with_credentials() {
        let responses = vec![
            MockResponse::json(
                StatusCode::NOT_FOUND,
                r#"{"result":"error","code":"BAD_REQUEST","msg":"File not found"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "image/png", b"fixture-png".to_vec()),
        ];
        let (server, requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        let media = client
            .load_media("/user_uploads/1/ab/截屏.png")
            .await
            .expect("direct download");

        assert_eq!(media.byte_count, 11);
        let _ = requests.recv().expect("temporary URL request");
        let direct = requests.recv().expect("direct request");
        assert!(direct.starts_with("GET /user_uploads/1/ab/%E6%88%AA%E5%B1%8F.png HTTP/1.1"));
        assert!(
            direct
                .to_ascii_lowercase()
                .contains("authorization: basic ")
        );
    }

    #[tokio::test]
    async fn preview_routes_load_the_upload_they_were_made_from() {
        let responses = vec![
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/token/image.png"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "image/png", b"fixture-png".to_vec()),
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/token/other.png"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "image/png", b"fixture-png-2".to_vec()),
        ];
        let (server, requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        let modern = client
            .load_media("/user_uploads/thumbnail/1/ab/cd/image.png/840x560.webp")
            .await
            .expect("modern preview route");
        assert_eq!(modern.remote_url, "/user_uploads/1/ab/cd/image.png");
        let resolution = requests.recv().expect("temporary URL request");
        assert!(resolution.starts_with("GET /api/v1/user_uploads/1/ab/cd/image.png HTTP/1.1"));
        let _ = requests.recv().expect("download");

        let legacy = client
            .load_media("/thumbnail?url=user_uploads%2F1%2Fef%2Fgh%2Fother.png&size=thumbnail")
            .await
            .expect("legacy preview route");
        assert_eq!(legacy.remote_url, "/user_uploads/1/ef/gh/other.png");
        let resolution = requests.recv().expect("temporary URL request");
        assert!(resolution.starts_with("GET /api/v1/user_uploads/1/ef/gh/other.png HTTP/1.1"));
    }

    #[tokio::test]
    async fn public_avatars_are_fetched_without_credentials_and_cached() {
        let responses = vec![
            MockResponse::bytes(StatusCode::OK, "image/png", b"avatar".to_vec()),
            MockResponse::bytes(StatusCode::OK, "text/html", b"<html>".to_vec()),
        ];
        let (server, requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        let first = client
            .load_media("/user_avatars/1/face.png")
            .await
            .expect("avatar download");
        let second = client
            .load_media("/user_avatars/1/face.png")
            .await
            .expect("cached avatar");
        assert!(!first.cache_hit);
        assert!(second.cache_hit);
        assert_eq!(second.local_url, first.local_url);

        let request = requests.recv().expect("avatar request");
        assert!(request.starts_with("GET /user_avatars/1/face.png HTTP/1.1"));
        assert!(!request.to_ascii_lowercase().contains("authorization:"));

        assert!(matches!(
            client.load_media("/user_avatars/1/page.png").await,
            Err(MediaError::InvalidResponse)
        ));
        for unsafe_url in [
            "http://cdn.example/avatar.png",
            "/user_avatars/../secrets.png",
            "/avatar/12",
        ] {
            assert!(matches!(
                client.load_media(unsafe_url).await,
                Err(MediaError::InvalidInput)
            ));
        }
    }

    #[tokio::test]
    async fn proxied_external_images_are_fetched_without_credentials() {
        let (server, requests) = spawn_mock(vec![MockResponse::bytes(
            StatusCode::OK,
            "image/jpeg",
            vec![7; 3 * 1_048_576],
        )]);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        let media = client
            .load_media("/external_content/ab12/cat")
            .await
            .expect("proxied image");
        assert_eq!(media.byte_count, 3 * 1_048_576);

        let request = requests.recv().expect("image request");
        assert!(request.starts_with("GET /external_content/ab12/cat HTTP/1.1"));
        assert!(!request.to_ascii_lowercase().contains("authorization:"));
    }

    #[tokio::test]
    async fn web_pages_are_not_cached_as_pictures_and_old_ones_are_replaced() {
        let responses = vec![
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/token/page.png"}"#,
            ),
            MockResponse::bytes(
                StatusCode::OK,
                "text/html; charset=utf-8",
                b"<html>".to_vec(),
            ),
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/token/page.png"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "image/png", b"real-png".to_vec()),
        ];
        let (server, _requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        assert!(matches!(
            client.load_media("/user_uploads/1/ab/page.png").await,
            Err(MediaError::NotAnImage(_))
        ));

        // A page cached by an older build is discarded rather than served again.
        let cached = client.account_cache_directory.join(format!(
            "{}.media",
            super::sha256_hex(b"/user_uploads/1/ab/page.png")
        ));
        tokio::fs::write(&cached, b"<!DOCTYPE html><html>login</html>")
            .await
            .expect("seed poisoned cache");
        let media = client
            .load_media("/user_uploads/1/ab/page.png")
            .await
            .expect("replacement download");
        assert!(!media.cache_hit);
        assert_eq!(
            tokio::fs::read(&cached).await.expect("cached bytes"),
            b"real-png"
        );
    }

    #[tokio::test]
    async fn isolates_accounts_and_rejects_cross_origin_message_urls() {
        let responses = vec![
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/a/file.bin"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "application/octet-stream", vec![1, 2, 3]),
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/b/file.bin"}"#,
            ),
            MockResponse::bytes(StatusCode::OK, "application/octet-stream", vec![1, 2, 3]),
        ];
        let (server, _requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let account_a = media_client(&server, &fixture, "account-a");
        let account_b = media_client(&server, &fixture, "account-b");

        let first = account_a
            .load_media("/user_uploads/1/ab/file.bin")
            .await
            .expect("account A media");
        let second = account_b
            .load_media("/user_uploads/1/ab/file.bin")
            .await
            .expect("account B media");
        assert_ne!(first.local_url, second.local_url);

        for unsafe_url in [
            "https://attacker.example/user_uploads/stolen.png",
            "/user_uploads/temporary/token/file.png",
            "/user_uploads/%2e%2e/secrets",
            "/static/logo.png",
        ] {
            assert!(matches!(
                account_a.load_media(unsafe_url).await,
                Err(MediaError::InvalidInput)
            ));
        }
    }

    #[tokio::test]
    async fn oversized_download_leaves_no_partial_cache_file() {
        let responses = vec![
            MockResponse::json(
                StatusCode::OK,
                r#"{"result":"success","url":"/user_uploads/temporary/token/huge.bin"}"#,
            ),
            MockResponse {
                status: StatusCode::OK,
                content_type: "application/octet-stream",
                body: Vec::new(),
                declared_length: Some((MAX_DOWNLOAD_BYTES + 1) as u64),
            },
        ];
        let (server, _requests) = spawn_mock(responses);
        let fixture = TempDir::new().expect("fixture directory");
        let client = media_client(&server, &fixture, "account-a");

        assert!(matches!(
            client.load_media("/user_uploads/1/ab/huge.bin").await,
            Err(MediaError::DownloadTooLarge)
        ));
        let mut entries = tokio::fs::read_dir(&client.account_cache_directory)
            .await
            .expect("cache directory");
        assert!(entries.next_entry().await.expect("cache entry").is_none());
    }

    fn media_client(server: &str, fixture: &TempDir, account_id: &str) -> MediaClient {
        MediaClient::new(
            server,
            "maya@example.com",
            SecretString::new(API_KEY),
            &fixture.path().join("cache"),
            account_id,
        )
        .expect("media client")
    }

    struct MockResponse {
        status: StatusCode,
        content_type: &'static str,
        body: Vec<u8>,
        declared_length: Option<u64>,
    }

    impl MockResponse {
        fn json(status: StatusCode, body: &str) -> Self {
            Self {
                status,
                content_type: "application/json",
                body: body.as_bytes().to_vec(),
                declared_length: None,
            }
        }

        fn bytes(status: StatusCode, content_type: &'static str, body: Vec<u8>) -> Self {
            Self {
                status,
                content_type,
                body,
                declared_length: None,
            }
        }
    }

    fn spawn_mock(responses: Vec<MockResponse>) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback mock server");
        let address = listener.local_addr().expect("mock server address");
        let (sender, receiver) = mpsc::channel();

        thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_http_request(&mut stream);
                let _ = sender.send(request);

                let reason = response.status.canonical_reason().unwrap_or("Unknown");
                let length = response
                    .declared_length
                    .unwrap_or(response.body.len() as u64);
                let headers = format!(
                    "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    response.status.as_u16(),
                    reason,
                    response.content_type,
                    length
                );
                stream
                    .write_all(headers.as_bytes())
                    .expect("write response headers");
                stream
                    .write_all(&response.body)
                    .expect("write response body");
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

    #[test]
    fn cache_helper_requires_absolute_roots() {
        let error = MediaClient::new(
            "https://example.com",
            "maya@example.com",
            SecretString::new(API_KEY),
            Path::new("relative-cache"),
            "account-a",
        )
        .expect_err("relative cache root");
        assert!(matches!(error, MediaError::InvalidInput));
    }
}
