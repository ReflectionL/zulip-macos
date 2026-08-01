//! Redacted daily-write smoke test using a Keychain-loaded API key on stdin.

use std::{env, error::Error, io};

use zulip_core::{
    auth::SecretString,
    messages::{
        ConversationTarget, MessageClient, MessageFlag, MessageWriteOperation, OutgoingMessage,
    },
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = env::args().skip(1);
    let server = arguments.next().ok_or("missing server URL")?;
    let email = arguments.next().ok_or("missing email")?;
    let own_user_id = arguments
        .next()
        .ok_or("missing own user ID")?
        .parse::<i64>()?;
    if own_user_id <= 0 {
        return Err("invalid own user ID".into());
    }
    if arguments.next().is_some() {
        return Err("unexpected arguments".into());
    }

    let mut api_key = String::new();
    io::stdin().read_line(&mut api_key)?;
    let api_key = api_key.trim_end_matches(['\r', '\n']);
    if api_key.is_empty() {
        return Err("missing API key on stdin".into());
    }

    let client = MessageClient::new(&server, email, SecretString::new(api_key))?;
    let existing = client
        .fetch_conversation(
            ConversationTarget::Direct {
                recipient_ids: vec![own_user_id],
            },
            100,
        )
        .await?;
    for message in existing.messages.iter().filter(|message| {
        message
            .content_html
            .contains("Zulip Mac MVP-003 action smoke 2026-08-01")
    }) {
        client.delete_message(message.id).await?;
    }
    println!("PASS cleanup_previous_disposable_messages");

    let message_id = client
        .send_message(
            OutgoingMessage::Direct {
                recipient_ids: vec![own_user_id],
                content: "Zulip Mac MVP-003 disposable action smoke".to_owned(),
            },
            None,
        )
        .await?;
    println!("PASS send_pending_reconcile");

    client
        .update_message_content(message_id, "Zulip Mac MVP-003 edited action smoke")
        .await?;
    println!("PASS edit_content");

    client
        .update_reaction(message_id, "thumbs_up", MessageWriteOperation::Add)
        .await?;
    println!("PASS add_reaction");

    client
        .update_message_flag(
            &[message_id],
            MessageFlag::Starred,
            MessageWriteOperation::Add,
        )
        .await?;
    println!("PASS star_message");

    client
        .update_message_flag(
            &[message_id],
            MessageFlag::Read,
            MessageWriteOperation::Remove,
        )
        .await?;
    client
        .update_message_flag(&[message_id], MessageFlag::Read, MessageWriteOperation::Add)
        .await?;
    println!("PASS unread_and_read");

    let direct = client
        .fetch_conversation(
            ConversationTarget::Direct {
                recipient_ids: vec![own_user_id],
            },
            20,
        )
        .await?;
    let message = direct
        .messages
        .iter()
        .find(|message| message.id == message_id)
        .ok_or("action message was not returned")?;
    if !message.content_html.contains("edited action smoke")
        || !message.flags.iter().any(|flag| flag == "starred")
        || !message
            .reactions
            .iter()
            .any(|reaction| reaction.emoji_name == "thumbs_up")
    {
        return Err("server state did not reconcile all message actions".into());
    }
    println!("PASS reconcile_server_state");

    client.delete_message(message_id).await?;
    println!("PASS delete_disposable_message");
    Ok(())
}
