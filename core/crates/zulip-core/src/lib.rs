#![doc = "Domain core for the native Zulip macOS client."]

pub mod auth;
pub mod content;
pub mod database;
pub mod math;
pub mod media;
pub mod messages;
pub mod server;
pub mod sync;

/// Compile-time identity for the embedded core.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CoreIdentity {
    /// Human-readable core name.
    pub name: &'static str,
    /// Cargo package version.
    pub version: &'static str,
}

/// Returns the identity of the embedded Rust core.
#[must_use]
pub const fn identity() -> CoreIdentity {
    CoreIdentity {
        name: "zulip-core",
        version: env!("CARGO_PKG_VERSION"),
    }
}

#[cfg(test)]
mod tests {
    use super::identity;

    #[test]
    fn identity_is_stable() {
        let identity = identity();
        assert_eq!(identity.name, "zulip-core");
        assert!(!identity.version.is_empty());
    }
}
