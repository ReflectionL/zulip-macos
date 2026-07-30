//! Versioned, account-scoped `SQLite` cache.

use std::{path::Path, time::Duration};

use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use thiserror::Error;

const SCHEMA_VERSION: u32 = 1;
const MIGRATIONS: &[&str] = &[r"
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
"];

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

/// Persistence and migration failures.
#[derive(Debug, Error)]
pub enum DatabaseError {
    /// `SQLite` operation failed.
    #[error("SQLite cache error: {0}")]
    Sqlite(#[from] rusqlite::Error),
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
        AccountRecord, CacheDatabase, DatabaseError, DraftRecord, MessageRecord, SCHEMA_VERSION,
        apply_migrations,
    };

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
