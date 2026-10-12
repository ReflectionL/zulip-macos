//! Versioned, account-scoped `SQLite` cache.

use std::{path::Path, time::Duration};

use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    messages::TopicSummary,
    sync::{ChannelSummary, MessageSummary, UserSummary},
};

const ACCOUNT_STATE_KEY: &str = "account";
const SNAPSHOT_STATE_KEY: &str = "snapshot";
const CONVERSATION_STATE_PREFIX: &str = "conversation:";
/// Conversations kept per account; the least recently saved are pruned.
const MAXIMUM_CACHED_CONVERSATIONS: i64 = 40;
/// Messages kept per cached conversation or snapshot (newest first).
const MAXIMUM_CACHED_MESSAGES: usize = 300;

const SCHEMA_VERSION: u32 = 2;
const MIGRATIONS: &[&str] = &[
    r"
    CREATE TABLE accounts (
        account_id TEXT PRIMARY KEY NOT NULL,
        server_url TEXT NOT NULL,
        email TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        display_name TEXT NOT NULL,
        created_at INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE users (
        account_id TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        email TEXT,
        full_name TEXT NOT NULL,
        is_bot INTEGER NOT NULL DEFAULT 0 CHECK (is_bot IN (0, 1)),
        is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        avatar_url TEXT,
        PRIMARY KEY (account_id, user_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE channels (
        account_id TEXT NOT NULL,
        stream_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        color TEXT NOT NULL,
        is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
        PRIMARY KEY (account_id, stream_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE topics (
        account_id TEXT NOT NULL,
        stream_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        max_message_id INTEGER,
        unread_count INTEGER NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
        PRIMARY KEY (account_id, stream_id, name),
        FOREIGN KEY (account_id, stream_id)
            REFERENCES channels(account_id, stream_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE messages (
        account_id TEXT NOT NULL,
        message_id INTEGER NOT NULL,
        sender_id INTEGER NOT NULL,
        message_type TEXT NOT NULL CHECK (message_type IN ('stream', 'private')),
        stream_id INTEGER,
        topic TEXT,
        recipient_ids_json TEXT,
        timestamp INTEGER NOT NULL,
        content_json TEXT NOT NULL,
        is_starred INTEGER NOT NULL DEFAULT 0 CHECK (is_starred IN (0, 1)),
        PRIMARY KEY (account_id, message_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) STRICT;

    CREATE INDEX messages_stream_topic_time
        ON messages(account_id, stream_id, topic, timestamp);
    CREATE INDEX messages_sender_time
        ON messages(account_id, sender_id, timestamp);

    CREATE TABLE unread_state (
        account_id TEXT NOT NULL,
        message_id INTEGER NOT NULL,
        is_unread INTEGER NOT NULL DEFAULT 1 CHECK (is_unread IN (0, 1)),
        is_mentioned INTEGER NOT NULL DEFAULT 0 CHECK (is_mentioned IN (0, 1)),
        PRIMARY KEY (account_id, message_id),
        FOREIGN KEY (account_id, message_id)
            REFERENCES messages(account_id, message_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE drafts (
        account_id TEXT NOT NULL,
        draft_id TEXT NOT NULL,
        conversation_key TEXT NOT NULL,
        content TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_id, draft_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) STRICT;

    CREATE INDEX drafts_conversation
        ON drafts(account_id, conversation_key, updated_at DESC);

    CREATE TABLE sync_metadata (
        account_id TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_id, key),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) STRICT;
",
    r"
    CREATE TABLE cached_state (
        account_id TEXT NOT NULL,
        key TEXT NOT NULL,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (account_id, key),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) STRICT;
",
];

/// Non-secret account metadata cached in `SQLite`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountRecord {
    /// Stable client account ID.
    pub account_id: String,
    /// Normalized Zulip server root.
    pub server_url: String,
    /// Zulip API email.
    pub email: String,
    /// Zulip user ID.
    pub user_id: i64,
    /// User-facing name.
    pub display_name: String,
    /// Unix timestamp.
    pub created_at: i64,
}

/// Normalized message payload persisted without transport response types.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MessageRecord {
    /// Account partition.
    pub account_id: String,
    /// Zulip message ID.
    pub message_id: i64,
    /// Sender's Zulip user ID.
    pub sender_id: i64,
    /// `stream` or `private`.
    pub message_type: String,
    /// Stream ID for channel messages.
    pub stream_id: Option<i64>,
    /// Topic for channel messages.
    pub topic: Option<String>,
    /// JSON array of recipient IDs for private messages.
    pub recipient_ids_json: Option<String>,
    /// Unix timestamp.
    pub timestamp: i64,
    /// Serialized normalized `ContentBlock` values.
    pub content_json: String,
    /// Current star state.
    pub is_starred: bool,
}

/// Local draft scoped to one account and conversation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DraftRecord {
    /// Account partition.
    pub account_id: String,
    /// Stable local draft identifier.
    pub draft_id: String,
    /// Serialized `ConversationKey`.
    pub conversation_key: String,
    /// Draft Markdown/plain text.
    pub content: String,
    /// Unix timestamp.
    pub updated_at: i64,
}

/// Non-secret identity needed to show a cached account without the network.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CachedAccount {
    /// Normalized Zulip server root.
    pub server_url: String,
    /// Zulip API email.
    pub email: String,
    /// Zulip user ID.
    pub user_id: i64,
    /// User-facing name.
    pub full_name: String,
}

/// The most recent navigation state for one account.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct CachedSnapshot {
    /// Organization users.
    pub users: Vec<UserSummary>,
    /// Subscribed channels.
    pub channels: Vec<ChannelSummary>,
    /// Known topics.
    pub topics: Vec<TopicSummary>,
    /// Recent messages, ascending by identifier.
    pub messages: Vec<MessageSummary>,
}

/// One conversation as last fetched from the server.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CachedConversation {
    /// Messages sorted by identifier.
    pub messages: Vec<MessageSummary>,
    /// Whether the oldest matching message was reached.
    pub found_oldest: bool,
    /// Whether the newest matching message was reached.
    pub found_newest: bool,
}

/// Persistence and migration failures.
#[derive(Debug, Error)]
pub enum DatabaseError {
    /// `SQLite` operation failed.
    #[error("SQLite cache error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    /// A cache value could not be serialized.
    #[error("cache value could not be serialized")]
    Serialization,
    /// Database was created by a newer application schema.
    #[error("cache schema version {found} is newer than supported version {supported}")]
    SchemaTooNew {
        /// Version found in `PRAGMA user_version`.
        found: u32,
        /// Maximum version supported by this build.
        supported: u32,
    },
}

/// Rust-owned `SQLite` connection. The core actor must keep all access off the
/// Swift main actor.
#[derive(Debug)]
pub struct CacheDatabase {
    connection: Connection,
}

impl CacheDatabase {
    /// Opens, configures, and migrates a file-backed cache.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for open, pragma, migration, or compatibility
    /// failures.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, DatabaseError> {
        let mut connection = Connection::open(path)?;
        configure(&connection, true)?;
        migrate(&mut connection)?;
        Ok(Self { connection })
    }

    /// Opens a migrated in-memory cache for tests and fixture sessions.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for `SQLite` configuration or migration
    /// failures.
    pub fn open_in_memory() -> Result<Self, DatabaseError> {
        let mut connection = Connection::open_in_memory()?;
        configure(&connection, false)?;
        migrate(&mut connection)?;
        Ok(Self { connection })
    }

    /// Returns the applied schema version.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] if `SQLite` cannot read `user_version`.
    pub fn schema_version(&self) -> Result<u32, DatabaseError> {
        Ok(self
            .connection
            .pragma_query_value(None, "user_version", |row| row.get(0))?)
    }

    /// Inserts or updates non-secret account metadata.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] if the write fails.
    pub fn upsert_account(&self, account: &AccountRecord) -> Result<(), DatabaseError> {
        self.connection.execute(
            r"
            INSERT INTO accounts (
                account_id, server_url, email, user_id, display_name, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(account_id) DO UPDATE SET
                server_url = excluded.server_url,
                email = excluded.email,
                user_id = excluded.user_id,
                display_name = excluded.display_name
            ",
            params![
                account.account_id,
                account.server_url,
                account.email,
                account.user_id,
                account.display_name,
                account.created_at
            ],
        )?;
        Ok(())
    }

    /// Replaces the cached identity and navigation snapshot for an account.
    ///
    /// Only the newest [`MAXIMUM_CACHED_MESSAGES`] messages are kept.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for serialization or write failures.
    pub fn save_account_cache(
        &self,
        account_id: &str,
        account: &CachedAccount,
        snapshot: &CachedSnapshot,
        now: i64,
    ) -> Result<(), DatabaseError> {
        let mut snapshot = snapshot.clone();
        keep_newest(&mut snapshot.messages);
        let transaction = self.connection.unchecked_transaction()?;
        self.upsert_account(&AccountRecord {
            account_id: account_id.to_owned(),
            server_url: account.server_url.clone(),
            email: account.email.clone(),
            user_id: account.user_id,
            display_name: account.full_name.clone(),
            created_at: now,
        })?;
        self.put_state(account_id, ACCOUNT_STATE_KEY, account, now)?;
        self.put_state(account_id, SNAPSHOT_STATE_KEY, &snapshot, now)?;
        transaction.commit()?;
        Ok(())
    }

    /// Replaces only the cached navigation snapshot of an already cached account.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for serialization, foreign-key, or write
    /// failures.
    pub fn save_snapshot(
        &self,
        account_id: &str,
        snapshot: &CachedSnapshot,
        now: i64,
    ) -> Result<(), DatabaseError> {
        let mut snapshot = snapshot.clone();
        keep_newest(&mut snapshot.messages);
        self.put_state(account_id, SNAPSHOT_STATE_KEY, &snapshot, now)
    }

    /// Removes every cached row for an account, as when the user disconnects.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] if the delete fails.
    pub fn delete_account_cache(&self, account_id: &str) -> Result<(), DatabaseError> {
        self.connection
            .execute("DELETE FROM accounts WHERE account_id = ?1", [account_id])?;
        Ok(())
    }

    /// Loads the cached identity and snapshot for an account, if both exist.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for read failures. Unreadable payloads are
    /// treated as absent so a damaged cache never blocks a fresh sync.
    pub fn account_cache(
        &self,
        account_id: &str,
    ) -> Result<Option<(CachedAccount, CachedSnapshot)>, DatabaseError> {
        let account = self.state(account_id, ACCOUNT_STATE_KEY)?;
        let snapshot = self.state(account_id, SNAPSHOT_STATE_KEY)?;
        Ok(account.zip(snapshot))
    }

    /// Stores the latest page of one conversation and prunes old entries.
    ///
    /// The account row must exist, which [`Self::save_account_cache`] ensures.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for serialization, foreign-key, or write
    /// failures.
    pub fn save_conversation(
        &self,
        account_id: &str,
        conversation_key: &str,
        conversation: &CachedConversation,
        now: i64,
    ) -> Result<(), DatabaseError> {
        let mut conversation = conversation.clone();
        keep_newest(&mut conversation.messages);
        let state_key = format!("{CONVERSATION_STATE_PREFIX}{conversation_key}");
        let transaction = self.connection.unchecked_transaction()?;
        self.put_state(account_id, &state_key, &conversation, now)?;
        self.connection.execute(
            r"
            DELETE FROM cached_state
            WHERE account_id = ?1 AND key LIKE ?2 ESCAPE '\'
              AND key NOT IN (
                  SELECT key FROM cached_state
                  WHERE account_id = ?1 AND key LIKE ?2 ESCAPE '\'
                  ORDER BY updated_at DESC, key
                  LIMIT ?3
              )
            ",
            params![
                account_id,
                format!("{CONVERSATION_STATE_PREFIX}%"),
                MAXIMUM_CACHED_CONVERSATIONS
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// Loads a previously cached conversation.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for read failures.
    pub fn conversation(
        &self,
        account_id: &str,
        conversation_key: &str,
    ) -> Result<Option<CachedConversation>, DatabaseError> {
        self.state(
            account_id,
            &format!("{CONVERSATION_STATE_PREFIX}{conversation_key}"),
        )
    }

    fn put_state<T: Serialize>(
        &self,
        account_id: &str,
        key: &str,
        value: &T,
        now: i64,
    ) -> Result<(), DatabaseError> {
        let payload = serde_json::to_string(value).map_err(|_| DatabaseError::Serialization)?;
        self.connection.execute(
            r"
            INSERT INTO cached_state (account_id, key, payload, updated_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(account_id, key) DO UPDATE SET
                payload = excluded.payload,
                updated_at = excluded.updated_at
            ",
            params![account_id, key, payload, now],
        )?;
        Ok(())
    }

    fn state<T: for<'de> Deserialize<'de>>(
        &self,
        account_id: &str,
        key: &str,
    ) -> Result<Option<T>, DatabaseError> {
        let payload: Option<String> = self
            .connection
            .query_row(
                "SELECT payload FROM cached_state WHERE account_id = ?1 AND key = ?2",
                params![account_id, key],
                |row| row.get(0),
            )
            .optional()?;
        Ok(payload.and_then(|payload| serde_json::from_str(&payload).ok()))
    }

    /// Inserts or updates a normalized message in its account partition.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for constraint or write failures.
    pub fn upsert_message(&self, message: &MessageRecord) -> Result<(), DatabaseError> {
        self.connection.execute(
            r"
            INSERT INTO messages (
                account_id, message_id, sender_id, message_type, stream_id,
                topic, recipient_ids_json, timestamp, content_json, is_starred
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(account_id, message_id) DO UPDATE SET
                sender_id = excluded.sender_id,
                message_type = excluded.message_type,
                stream_id = excluded.stream_id,
                topic = excluded.topic,
                recipient_ids_json = excluded.recipient_ids_json,
                timestamp = excluded.timestamp,
                content_json = excluded.content_json,
                is_starred = excluded.is_starred
            ",
            params![
                message.account_id,
                message.message_id,
                message.sender_id,
                message.message_type,
                message.stream_id,
                message.topic,
                message.recipient_ids_json,
                message.timestamp,
                message.content_json,
                message.is_starred
            ],
        )?;
        Ok(())
    }

    /// Counts messages in one account partition.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] when the query fails.
    pub fn message_count(&self, account_id: &str) -> Result<i64, DatabaseError> {
        Ok(self.connection.query_row(
            "SELECT COUNT(*) FROM messages WHERE account_id = ?1",
            [account_id],
            |row| row.get(0),
        )?)
    }

    /// Saves a local draft without touching credentials.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] for constraint or write failures.
    pub fn save_draft(&self, draft: &DraftRecord) -> Result<(), DatabaseError> {
        self.connection.execute(
            r"
            INSERT INTO drafts (
                account_id, draft_id, conversation_key, content, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(account_id, draft_id) DO UPDATE SET
                conversation_key = excluded.conversation_key,
                content = excluded.content,
                updated_at = excluded.updated_at
            ",
            params![
                draft.account_id,
                draft.draft_id,
                draft.conversation_key,
                draft.content,
                draft.updated_at
            ],
        )?;
        Ok(())
    }

    /// Loads one draft from one account partition.
    ///
    /// # Errors
    ///
    /// Returns [`DatabaseError`] when the query fails.
    pub fn draft(
        &self,
        account_id: &str,
        draft_id: &str,
    ) -> Result<Option<DraftRecord>, DatabaseError> {
        Ok(self
            .connection
            .query_row(
                r"
                SELECT account_id, draft_id, conversation_key, content, updated_at
                FROM drafts
                WHERE account_id = ?1 AND draft_id = ?2
                ",
                params![account_id, draft_id],
                |row| {
                    Ok(DraftRecord {
                        account_id: row.get(0)?,
                        draft_id: row.get(1)?,
                        conversation_key: row.get(2)?,
                        content: row.get(3)?,
                        updated_at: row.get(4)?,
                    })
                },
            )
            .optional()?)
    }
}

fn keep_newest(messages: &mut Vec<MessageSummary>) {
    messages.sort_by_key(|message| message.id);
    if messages.len() > MAXIMUM_CACHED_MESSAGES {
        messages.drain(..messages.len() - MAXIMUM_CACHED_MESSAGES);
    }
}

fn configure(connection: &Connection, enable_wal: bool) -> Result<(), rusqlite::Error> {
    connection.busy_timeout(Duration::from_secs(5))?;
    connection.pragma_update(None, "foreign_keys", true)?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    if enable_wal {
        connection.pragma_update(None, "journal_mode", "WAL")?;
    }
    Ok(())
}

fn migrate(connection: &mut Connection) -> Result<(), DatabaseError> {
    let current: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if current > SCHEMA_VERSION {
        return Err(DatabaseError::SchemaTooNew {
            found: current,
            supported: SCHEMA_VERSION,
        });
    }

    apply_migrations(connection, current, MIGRATIONS)
}

fn apply_migrations(
    connection: &mut Connection,
    current: u32,
    migrations: &[&str],
) -> Result<(), DatabaseError> {
    for (index, sql) in migrations
        .iter()
        .enumerate()
        .skip(usize::try_from(current).unwrap_or(usize::MAX))
    {
        let version = u32::try_from(index + 1).map_err(|_| DatabaseError::SchemaTooNew {
            found: u32::MAX,
            supported: SCHEMA_VERSION,
        })?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(sql)?;
        transaction.pragma_update(None, "user_version", version)?;
        transaction.commit()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;
    use tempfile::NamedTempFile;

    use super::{
        AccountRecord, CacheDatabase, CachedAccount, CachedConversation, CachedSnapshot,
        DatabaseError, DraftRecord, MessageRecord, SCHEMA_VERSION, apply_migrations,
    };
    use crate::sync::MessageSummary;

    #[test]
    fn caches_account_snapshot_and_conversations_with_pruning() {
        let database = CacheDatabase::open_in_memory().expect("database");
        let account = CachedAccount {
            server_url: "https://acme.zulipchat.com".to_owned(),
            email: "maya@example.com".to_owned(),
            user_id: 9,
            full_name: "Maya".to_owned(),
        };
        let messages = (1..=400)
            .map(|id| MessageSummary {
                id,
                sender_id: 2,
                sender_full_name: "Theo".to_owned(),
                timestamp: 1_700_000_000 + id,
                content_html: format!("<p>{id}</p>"),
                stream_id: Some(5),
                topic: Some("macOS".to_owned()),
                recipient_ids: Vec::new(),
                flags: vec!["read".to_owned()],
                reactions: Vec::new(),
            })
            .collect::<Vec<_>>();
        let snapshot = CachedSnapshot {
            users: Vec::new(),
            channels: Vec::new(),
            topics: Vec::new(),
            messages: messages.clone(),
        };
        assert!(database.account_cache("acme|maya").expect("read").is_none());
        database
            .save_account_cache("acme|maya", &account, &snapshot, 10)
            .expect("save account cache");
        let (cached_account, cached_snapshot) = database
            .account_cache("acme|maya")
            .expect("read")
            .expect("cached");
        assert_eq!(cached_account, account);
        assert_eq!(cached_snapshot.messages.len(), 300);
        assert_eq!(cached_snapshot.messages.last().map(|m| m.id), Some(400));
        assert_eq!(cached_snapshot.messages.first().map(|m| m.id), Some(101));

        for index in 0..45_i64 {
            database
                .save_conversation(
                    "acme|maya",
                    &format!("topic-{index}"),
                    &CachedConversation {
                        messages: messages[..3].to_vec(),
                        found_oldest: true,
                        found_newest: true,
                    },
                    100 + index,
                )
                .expect("save conversation");
        }
        assert!(
            database
                .conversation("acme|maya", "topic-0")
                .expect("read")
                .is_none(),
            "oldest conversations are pruned"
        );
        let newest = database
            .conversation("acme|maya", "topic-44")
            .expect("read")
            .expect("newest kept");
        assert_eq!(newest.messages.len(), 3);
        assert!(newest.found_oldest);
        assert!(
            database.account_cache("acme|maya").expect("read").is_some(),
            "pruning never removes the account snapshot"
        );
        assert!(
            database
                .conversation("other-account", "topic-44")
                .expect("read")
                .is_none(),
            "cache is account scoped"
        );

        database
            .delete_account_cache("acme|maya")
            .expect("delete account cache");
        assert!(database.account_cache("acme|maya").expect("read").is_none());
        assert!(
            database
                .conversation("acme|maya", "topic-44")
                .expect("read")
                .is_none(),
            "disconnecting forgets cached conversations"
        );
    }

    #[test]
    fn migrates_and_reopens_file_database() {
        let file = NamedTempFile::new().expect("temporary database");
        {
            let database = CacheDatabase::open(file.path()).expect("migrate cache");
            assert_eq!(
                database.schema_version().expect("schema version"),
                SCHEMA_VERSION
            );
            database
                .upsert_account(&account("account-a", 1))
                .expect("insert account");
        }

        let reopened = CacheDatabase::open(file.path()).expect("reopen cache");
        assert_eq!(
            reopened.schema_version().expect("schema version"),
            SCHEMA_VERSION
        );
        assert_eq!(
            reopened.message_count("account-a").expect("message count"),
            0
        );
    }

    #[test]
    fn message_and_draft_ids_are_isolated_by_account() {
        let database = CacheDatabase::open_in_memory().expect("cache");
        database
            .upsert_account(&account("account-a", 1))
            .expect("account A");
        database
            .upsert_account(&account("account-b", 2))
            .expect("account B");

        database
            .upsert_message(&message("account-a", 42, "A"))
            .expect("message A");
        database
            .upsert_message(&message("account-b", 42, "B"))
            .expect("message B");
        assert_eq!(database.message_count("account-a").expect("count A"), 1);
        assert_eq!(database.message_count("account-b").expect("count B"), 1);

        database
            .save_draft(&draft("account-a", "draft-1", "A"))
            .expect("draft A");
        database
            .save_draft(&draft("account-b", "draft-1", "B"))
            .expect("draft B");
        assert_eq!(
            database
                .draft("account-a", "draft-1")
                .expect("draft query")
                .expect("draft")
                .content,
            "A"
        );
        assert_eq!(
            database
                .draft("account-b", "draft-1")
                .expect("draft query")
                .expect("draft")
                .content,
            "B"
        );
    }

    #[test]
    fn foreign_keys_prevent_cross_account_or_orphan_rows() {
        let database = CacheDatabase::open_in_memory().expect("cache");
        let error = database
            .upsert_message(&message("missing-account", 1, "orphan"))
            .expect_err("orphan message must fail");
        assert!(matches!(error, DatabaseError::Sqlite(_)));
    }

    #[test]
    fn failing_migration_rolls_back_schema_and_version() {
        let mut connection = Connection::open_in_memory().expect("SQLite");
        let error = apply_migrations(
            &mut connection,
            0,
            &["CREATE TABLE partial (id INTEGER); THIS IS NOT SQL;"],
        )
        .expect_err("migration must fail");
        assert!(matches!(error, DatabaseError::Sqlite(_)));

        let version: u32 = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .expect("version");
        let table_exists: bool = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name = 'partial')",
                [],
                |row| row.get(0),
            )
            .expect("schema query");
        assert_eq!(version, 0);
        assert!(!table_exists);
    }

    #[test]
    fn schema_never_contains_credential_columns() {
        let database = CacheDatabase::open_in_memory().expect("cache");
        let mut statement = database
            .connection
            .prepare("SELECT sql FROM sqlite_schema WHERE type = 'table' AND sql IS NOT NULL")
            .expect("schema statement");
        let schema = statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("schema rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("schema SQL")
            .join("\n")
            .to_lowercase();

        assert!(!schema.contains("password"));
        assert!(!schema.contains("api_key"));
        assert!(!schema.contains("credential"));
    }

    fn account(account_id: &str, user_id: i64) -> AccountRecord {
        AccountRecord {
            account_id: account_id.to_owned(),
            server_url: "https://example.zulipchat.com/".to_owned(),
            email: format!("{account_id}@example.com"),
            user_id,
            display_name: account_id.to_owned(),
            created_at: 1_700_000_000,
        }
    }

    fn message(account_id: &str, message_id: i64, content: &str) -> MessageRecord {
        MessageRecord {
            account_id: account_id.to_owned(),
            message_id,
            sender_id: 101,
            message_type: "private".to_owned(),
            stream_id: None,
            topic: None,
            recipient_ids_json: Some("[101]".to_owned()),
            timestamp: 1_700_000_000,
            content_json: format!(r#"[{{"type":"paragraph","text":"{content}"}}]"#),
            is_starred: false,
        }
    }

    fn draft(account_id: &str, draft_id: &str, content: &str) -> DraftRecord {
        DraftRecord {
            account_id: account_id.to_owned(),
            draft_id: draft_id.to_owned(),
            conversation_key: "dm:101".to_owned(),
            content: content.to_owned(),
            updated_at: 1_700_000_000,
        }
    }
}
