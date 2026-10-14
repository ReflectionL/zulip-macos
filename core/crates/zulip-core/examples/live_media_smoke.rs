//! Redacted live attachment smoke using a Keychain-loaded API key on stdin.

use std::{env, error::Error, io};

use tempfile::TempDir;
use zeroize::Zeroize;
use zulip_core::{
    auth::{AuthenticationClient, SecretString},
    content::{ContentBlock, parse_zulip_html},
    media::MediaClient,
    messages::{ConversationTarget, MessageClient, OutgoingMessage},
};

const ONE_PIXEL_PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0,
    0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100, 248, 15, 0, 1, 5, 1, 1,
    39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = env::args().skip(1);
    let server = arguments.next().ok_or("missing server URL")?;
    let email = arguments.next().ok_or("missing email")?;
    if arguments.next().is_some() {
        return Err("invalid smoke arguments".into());
    }

    let mut api_key = String::new();
    io::stdin().read_line(&mut api_key)?;
    let trimmed_api_key = api_key.trim_end_matches(['\r', '\n']).to_owned();
    api_key.zeroize();
    if trimmed_api_key.is_empty() {
        return Err("missing API key on stdin".into());
    }
    let authenticated = AuthenticationClient::new()?
        .authenticate_with_api_key(&server, &email, SecretString::new(trimmed_api_key))
        .await?;
    let media_api_key = authenticated.api_key.expose_secret().to_owned();
    let message_api_key = authenticated.api_key.expose_secret().to_owned();

    let fixture = TempDir::new()?;
    let selected_file = fixture.path().join("zulip-mac-mvp-004-smoke.png");
    tokio::fs::write(&selected_file, ONE_PIXEL_PNG).await?;
    let media = MediaClient::new(
        &authenticated.server_url,
        authenticated.email.clone(),
        SecretString::new(media_api_key),
        &fixture.path().join("cache"),
        "mvp-004-live-smoke",
    )?;
    let messages = MessageClient::new(
        &authenticated.server_url,
        authenticated.email,
        SecretString::new(message_api_key),
    )?;

    let uploaded = media
        .upload_file(&selected_file, "zulip-mac-mvp-004-smoke.png")
        .await?;
    println!("PASS upload_bounded_png");

    let message_id = messages
        .send_message(
            OutgoingMessage::Direct {
                recipient_ids: vec![authenticated.user_id],
                content: format!(
                    "Zulip Mac MVP-004 disposable media smoke\n\n{}",
                    uploaded.markdown
                ),
            },
            None,
        )
        .await?;
    println!("PASS send_attachment_link");

    let result =
        verify_render_and_download(&messages, &media, authenticated.user_id, message_id).await;
    let cleanup = messages.delete_message(message_id).await;
    if cleanup.is_ok() {
        println!("PASS delete_disposable_message_and_attachment_reference");
    }
    cleanup?;
    result
}

async fn verify_render_and_download(
    messages: &MessageClient,
    media: &MediaClient,
    own_user_id: i64,
    message_id: i64,
) -> Result<(), Box<dyn Error>> {
    let direct = messages
        .fetch_conversation(
            ConversationTarget::Direct {
                recipient_ids: vec![own_user_id],
            },
            30,
        )
        .await?;
    let message = direct
        .messages
        .iter()
        .find(|message| message.id == message_id)
        .ok_or("attachment message was not returned")?;
    let blocks = parse_zulip_html(&message.content_html);
    let image_url = find_image_url(&blocks).ok_or("server did not render an image preview")?;
    println!("PASS parse_server_rendered_image");

    let first = media.load_media(&image_url).await?;
    if first.cache_hit || first.byte_count != ONE_PIXEL_PNG.len() as u64 {
        return Err("first media load did not download the expected bytes".into());
    }
    let local_path = url::Url::parse(&first.local_url)
        .map_err(|_| "invalid cache URL")?
        .to_file_path()
        .map_err(|()| "cache URL was not local")?;
    if tokio::fs::read(local_path).await? != ONE_PIXEL_PNG {
        return Err("cached media bytes differ from the upload".into());
    }
    println!("PASS authenticated_media_download");

    let second = media.load_media(&image_url).await?;
    if !second.cache_hit || second.local_url != first.local_url {
        return Err("second media load missed the account cache".into());
    }
    println!("PASS account_cache_hit");
    Ok(())
}

fn find_image_url(blocks: &[ContentBlock]) -> Option<String> {
    for block in blocks {
        match block {
            ContentBlock::Image { url, .. } => return Some(url.clone()),
            ContentBlock::Quote(blocks) => {
                if let Some(url) = find_image_url(blocks) {
                    return Some(url);
                }
            }
            ContentBlock::List { items, .. } => {
                for item in items {
                    if let Some(url) = find_image_url(item) {
                        return Some(url);
                    }
                }
            }
            ContentBlock::Paragraph(_)
            | ContentBlock::Heading { .. }
            | ContentBlock::Code { .. }
            | ContentBlock::LinkPreview { .. }
            | ContentBlock::Unsupported { .. } => {}
        }
    }
    None
}
