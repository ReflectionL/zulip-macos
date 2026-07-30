//! Redacted live-server smoke test reading server, email, and password from stdin.

use std::{
    error::Error,
    io::{self, BufRead},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use zulip_core::{
    auth::{AuthenticationClient, SecretString},
    messages::{ConversationTarget, MessageClient, OutgoingMessage},
    sync::{EventQueueClient, RecoveryPolicy, SyncCycle, SyncSession},
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let mut input = io::stdin().lock();
    let server = read_field(&mut input, "server URL")?;
    let email = read_field(&mut input, "email")?;
    let password = read_field(&mut input, "password")?;

    let authenticated = AuthenticationClient::default()
        .authenticate_with_password(&server, &email, SecretString::new(password))
        .await?;
    println!("PASS authentication");

    let api_key = authenticated.api_key.expose_secret().to_owned();
    let sync_client = EventQueueClient::new(
        &authenticated.server_url,
        authenticated.email.clone(),
        SecretString::new(api_key.clone()),
    )?;
    let messages = MessageClient::new(
        &authenticated.server_url,
        authenticated.email.clone(),
        SecretString::new(api_key),
    )?;
    let (mut sync, snapshot) =
        SyncSession::start(sync_client, RecoveryPolicy::default(), 1).await?;
    println!(
        "PASS initial_sync users={} channels={} messages={}",
        snapshot.users.len(),
        snapshot.channels.len(),
        snapshot.messages.len()
    );

    let inbox = messages
        .fetch_conversation(ConversationTarget::Combined, 20)
        .await?;
    println!("PASS open_inbox messages={}", inbox.messages.len());

    let marker = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let local_id = format!("zulip-mac-live-smoke-{marker}");
    let queue_id = sync.queue().id.clone();
    let message_id = messages
        .send_message(
            OutgoingMessage::Direct {
                recipient_ids: vec![authenticated.user_id],
                content: format!("Zulip Mac live smoke test `{marker}`"),
            },
            Some((&queue_id, &local_id)),
        )
        .await?;
    println!("PASS send_self_dm");

    let cycle = tokio::time::timeout(Duration::from_secs(30), sync.advance()).await?;
    match cycle {
        SyncCycle::Events(outcome)
            if outcome.snapshot.as_ref().is_some_and(|updated| {
                updated
                    .messages
                    .iter()
                    .any(|message| message.id == message_id)
            }) =>
        {
            println!("PASS receive_live_event");
        }
        SyncCycle::Events(_) => {
            return Err("live event did not contain the sent message".into());
        }
        SyncCycle::Resynchronized { .. } => {
            return Err("unexpected resynchronization during live smoke".into());
        }
        SyncCycle::RetryAfter { error, .. } | SyncCycle::Fatal { error } => {
            return Err(error.into());
        }
    }

    let direct = messages
        .fetch_conversation(
            ConversationTarget::Direct {
                recipient_ids: vec![authenticated.user_id],
            },
            20,
        )
        .await?;
    if !direct
        .messages
        .iter()
        .any(|message| message.id == message_id)
    {
        return Err("sent message was not returned by conversation fetch".into());
    }
    println!("PASS reopen_self_dm");

    messages.mark_read(&[message_id]).await?;
    println!("PASS mark_read");

    Ok(())
}

fn read_field(input: &mut impl BufRead, label: &str) -> Result<String, Box<dyn Error>> {
    let mut value = String::new();
    input.read_line(&mut value)?;
    let value = value.trim_end_matches(['\r', '\n']).to_owned();
    if value.is_empty() {
        Err(format!("missing {label}").into())
    } else {
        Ok(value)
    }
}
