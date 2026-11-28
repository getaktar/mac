//! Swift's way into Aktar's SFTP core (`aktar_sftp_core`, an exact copy of
//! getaktar/desktop's crates/sftp-core), through UniFFI: the client and
//! its operations as async methods, the pure helpers (paths, keys, host
//! keys) as functions, and the core's errors as `SftpError`, which the app
//! words itself (Storage/SFTPBackend.swift).
//!
//! Every async call runs on this library's own Tokio runtime, so the
//! connection pool, its idle timers and keepalives live there whatever
//! thread Swift awaits from. Nothing here is Mac-only: the same crate
//! builds for iOS (aarch64-apple-ios, aarch64-apple-ios-sim).

use std::future::Future;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};

use aktar_sftp_core as core;

uniffi::setup_scaffolding!();

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("aktar-sftp")
        .enable_all()
        .build()
        .expect("the SFTP runtime")
});

/// Runs `future` on the runtime and waits for it from any executor.
async fn on_runtime<T: Send + 'static>(future: impl Future<Output = Result<T, SftpError>> + Send + 'static) -> Result<T, SftpError> {
    match RUNTIME.spawn(future).await {
        Ok(result) => result,
        Err(error) => Err(SftpError::Other { message: format!("The SFTP task failed: {error}") }),
    }
}

// MARK: - Errors

/// The core's `Error`, field for field (see its documentation).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum SftpError {
    InvalidEndpoint,
    FolderHasParent,
    InvalidName { name: String },
    AuthFailed,
    KeyPassphrase,
    UnsupportedKey { name: String },
    UnreadableKey,
    UnreadableHostKey,
    HostKeyChanged { stored: Option<String>, seen: Option<String> },
    PermissionDenied,
    FolderNotFound { path: String },
    FileNotFound,
    FileInTheWay { folder: String },
    Refused { host: String },
    Timeout { host: String },
    HostNotFound { host: String },
    NoCommonAlgorithm { host: String, detail: String },
    NoSftp,
    NoServerKey,
    Dropped { message: String },
    ServerTimeout,
    OutOfSpace,
    ServerAnswered { message: String },
    TooLarge,
    AlreadyExists,
    Cancelled,
    Local { message: String },
    Other { message: String },
}

impl std::fmt::Display for SftpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for SftpError {}

impl From<core::Error> for SftpError {
    fn from(error: core::Error) -> Self {
        use core::Error as E;
        match error {
            E::InvalidEndpoint => Self::InvalidEndpoint,
            E::FolderHasParent => Self::FolderHasParent,
            E::InvalidName(name) => Self::InvalidName { name },
            E::AuthFailed => Self::AuthFailed,
            E::KeyPassphrase => Self::KeyPassphrase,
            E::UnsupportedKey(name) => Self::UnsupportedKey { name },
            E::UnreadableKey => Self::UnreadableKey,
            E::UnreadableHostKey => Self::UnreadableHostKey,
            E::HostKeyChanged { stored, seen } => Self::HostKeyChanged { stored, seen },
            E::PermissionDenied => Self::PermissionDenied,
            E::FolderNotFound(path) => Self::FolderNotFound { path },
            E::FileNotFound => Self::FileNotFound,
            E::FileInTheWay(folder) => Self::FileInTheWay { folder },
            E::Refused { host } => Self::Refused { host },
            E::Timeout { host } => Self::Timeout { host },
            E::HostNotFound { host } => Self::HostNotFound { host },
            E::NoCommonAlgorithm { host, detail } => Self::NoCommonAlgorithm { host, detail },
            E::NoSftp => Self::NoSftp,
            E::NoServerKey => Self::NoServerKey,
            E::Dropped(message) => Self::Dropped { message },
            E::ServerTimeout => Self::ServerTimeout,
            E::OutOfSpace => Self::OutOfSpace,
            E::ServerAnswered(message) => Self::ServerAnswered { message },
            E::TooLarge => Self::TooLarge,
            E::AlreadyExists => Self::AlreadyExists,
            E::Cancelled => Self::Cancelled,
            E::Local(message) => Self::Local { message },
            E::Other(message) => Self::Other { message },
        }
    }
}

// MARK: - Records and callbacks

/// Where and how to connect; see `core::ClientConfig`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SftpConfig {
    pub endpoint: String,
    pub folder: String,
    pub user: String,
    pub secret: String,
    pub key_passphrase: Option<String>,
    pub host_key: Option<String>,
    pub trust_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SftpEndpoint {
    pub host: String,
    pub port: u16,
}

/// A folder's entry; `last_modified_ms` is Unix milliseconds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SftpEntry {
    pub name: String,
    pub is_folder: bool,
    pub size: i64,
    pub last_modified_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SftpFileInfo {
    pub size: i64,
    pub last_modified_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SftpSmallFile {
    pub data: Vec<u8>,
    pub last_modified_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SftpKeyInfo {
    pub algorithm: String,
    pub encrypted: bool,
}

/// Told how an upload goes (implemented in Swift).
#[uniffi::export(with_foreign)]
pub trait SftpProgress: Send + Sync {
    /// The file's size, again on each try.
    fn start(&self, total: u64);
    /// Bytes sent since the last call.
    fn advance(&self, bytes: u64);
}

/// Told the host key (OpenSSH format) a destination without one trusted
/// on its first connection (implemented in Swift).
#[uniffi::export(with_foreign)]
pub trait SftpHostKeyListener: Send + Sync {
    fn learned(&self, host_key: String);
}

struct ProgressBridge(Arc<dyn SftpProgress>);

impl core::Progress for ProgressBridge {
    fn start(&self, total: u64) {
        self.0.start(total);
    }

    fn advance(&self, bytes: u64) {
        self.0.advance(bytes);
    }
}

/// Cancels an upload or download it was given (`Error::Cancelled`; an
/// upload's part file is removed).
#[derive(Debug, Default, uniffi::Object)]
pub struct SftpCancel(Arc<core::CancelToken>);

#[uniffi::export]
impl SftpCancel {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.cancel();
    }
}

// MARK: - Test Connection

/// Test Connection's own connection, signed in, with the test file
/// written (when `writable`); `finish` deletes it and closes.
#[derive(uniffi::Object)]
pub struct SftpTestSession {
    session: Mutex<Option<core::TestSession>>,
    host_key: String,
    fingerprint: String,
    writable: bool,
    test_key: String,
}

#[uniffi::export]
impl SftpTestSession {
    pub fn host_key(&self) -> String {
        self.host_key.clone()
    }

    pub fn fingerprint(&self) -> String {
        self.fingerprint.clone()
    }

    pub fn writable(&self) -> bool {
        self.writable
    }

    /// The test file's key under the folder.
    pub fn test_key(&self) -> String {
        self.test_key.clone()
    }

    pub async fn finish(&self) {
        let Some(session) = self.session.lock().unwrap().take() else { return };
        let _ = on_runtime(async move {
            session.finish().await;
            Ok(())
        })
        .await;
    }
}

// MARK: - Client

/// One SFTP destination; cheap to make, connections come from the core's
/// shared pool.
#[derive(uniffi::Object)]
pub struct SftpClient(Arc<core::Client>);

#[uniffi::export]
impl SftpClient {
    /// Refuses a server or folder that can't be right before anything is
    /// sent.
    #[uniffi::constructor]
    pub fn new(config: SftpConfig, listener: Option<Arc<dyn SftpHostKeyListener>>) -> Result<Self, SftpError> {
        let mut client = core::Client::new(core::ClientConfig {
            endpoint: config.endpoint,
            folder: config.folder,
            user: config.user,
            secret: config.secret,
            key_passphrase: config.key_passphrase,
            host_key: config.host_key,
            trust_id: config.trust_id,
        })?;
        if let Some(listener) = listener {
            client = client.with_host_key_listener(move |key| listener.learned(key.to_string()));
        }
        Ok(Self(Arc::new(client)))
    }

    pub fn host(&self) -> String {
        self.0.host().to_string()
    }

    pub fn port(&self) -> u16 {
        self.0.port()
    }

    /// `host`, or `host:port` when the port isn't 22.
    pub fn display_host(&self) -> String {
        self.0.display_host()
    }

    /// The base folder as paths are made from it.
    pub fn base(&self) -> String {
        self.0.base().to_string()
    }

    /// A fresh connection, signed in, with the folder looked at and a test
    /// file written. A server with another key than the stored one is
    /// `SftpError::HostKeyChanged` with the key it shows, and isn't signed
    /// in to.
    pub async fn test_connection(&self) -> Result<Arc<SftpTestSession>, SftpError> {
        let client = self.0.clone();
        let outcome = on_runtime(async move { Ok(client.test_connection().await?) }).await?;
        match outcome {
            core::TestOutcome::HostKeyChanged { stored, seen } => Err(SftpError::HostKeyChanged { stored, seen }),
            core::TestOutcome::Connected(session) => Ok(Arc::new(SftpTestSession {
                host_key: session.host_key.clone(),
                fingerprint: session.fingerprint.clone(),
                writable: session.writable,
                test_key: session.test_key.clone(),
                session: Mutex::new(Some(session)),
            })),
        }
    }

    /// Uploads the local file at `path` to `key` through a part file;
    /// returns its size.
    pub async fn upload(&self, path: String, key: String, only_if_new: bool, progress: Option<Arc<dyn SftpProgress>>, cancel: Option<Arc<SftpCancel>>) -> Result<u64, SftpError> {
        let client = self.0.clone();
        on_runtime(async move {
            let progress = progress.map(|progress| Arc::new(ProgressBridge(progress)) as Arc<dyn core::Progress>);
            let token = cancel.map(|cancel| cancel.0.clone());
            Ok(client.upload(&PathBuf::from(path), &key, progress, only_if_new, token.as_deref()).await?)
        })
        .await
    }

    pub async fn put_bytes(&self, key: String, data: Vec<u8>) -> Result<(), SftpError> {
        let client = self.0.clone();
        on_runtime(async move { Ok(client.put_bytes(&key, &data).await?) }).await
    }

    /// None when there's no such file; over `max_bytes` is `TooLarge`.
    pub async fn get_small(&self, key: String, max_bytes: u64) -> Result<Option<SftpSmallFile>, SftpError> {
        let client = self.0.clone();
        on_runtime(async move {
            let file = client.get_small(&key, max_bytes).await?;
            Ok(file.map(|(data, last_modified_ms)| SftpSmallFile { data, last_modified_ms }))
        })
        .await
    }

    /// Downloads to the local `path`; false when there's no such file.
    pub async fn download(&self, key: String, path: String, max_bytes: u64, cancel: Option<Arc<SftpCancel>>) -> Result<bool, SftpError> {
        let client = self.0.clone();
        on_runtime(async move {
            let token = cancel.map(|cancel| cancel.0.clone());
            Ok(client.download(&key, &PathBuf::from(path), max_bytes, token.as_deref()).await?)
        })
        .await
    }

    pub async fn delete(&self, key: String) -> Result<(), SftpError> {
        let client = self.0.clone();
        on_runtime(async move { Ok(client.delete(&key).await?) }).await
    }

    pub async fn info(&self, key: String) -> Result<Option<SftpFileInfo>, SftpError> {
        let client = self.0.clone();
        on_runtime(async move {
            let info = client.info(&key).await?;
            Ok(info.map(|info| SftpFileInfo { size: info.size, last_modified_ms: info.last_modified }))
        })
        .await
    }

    /// The folder `prefix`'s entries; a missing folder is `FolderNotFound`.
    pub async fn list(&self, prefix: String) -> Result<Vec<SftpEntry>, SftpError> {
        let client = self.0.clone();
        on_runtime(async move {
            let entries = client.list(&prefix).await?;
            Ok(entries
                .into_iter()
                .map(|entry| SftpEntry { name: entry.name, is_folder: entry.is_folder, size: entry.size, last_modified_ms: entry.last_modified })
                .collect())
        })
        .await
    }

    pub async fn copy(&self, source: String, destination: String) -> Result<(), SftpError> {
        let client = self.0.clone();
        on_runtime(async move { Ok(client.copy(&source, &destination).await?) }).await
    }

    pub async fn rename(&self, source: String, destination: String) -> Result<(), SftpError> {
        let client = self.0.clone();
        on_runtime(async move { Ok(client.rename(&source, &destination).await?) }).await
    }

    pub async fn create_folder(&self, prefix: String) -> Result<(), SftpError> {
        let client = self.0.clone();
        on_runtime(async move { Ok(client.create_folder(&prefix).await?) }).await
    }
}

// MARK: - Helpers

#[uniffi::export]
pub fn sftp_parse_endpoint(endpoint: String) -> Result<SftpEndpoint, SftpError> {
    let (host, port) = core::parse_endpoint(&endpoint)?;
    Ok(SftpEndpoint { host, port })
}

#[uniffi::export]
pub fn sftp_normalize_folder(folder: String) -> Result<String, SftpError> {
    Ok(core::normalize_folder(&folder)?)
}

#[uniffi::export]
pub fn sftp_remote_path(base: String, key: String) -> Result<String, SftpError> {
    Ok(core::remote_path(&base, &key)?)
}

#[uniffi::export]
pub fn sftp_part_path(path: String) -> String {
    core::part_path(&path)
}

#[uniffi::export]
pub fn sftp_is_part_file(name: String) -> bool {
    core::is_part_file(&name)
}

/// A stored host key without its comment, or None when it can't be read.
#[uniffi::export]
pub fn sftp_normalize_host_key(host_key: String) -> Option<String> {
    core::normalize_host_key(&host_key)
}

/// `SHA256:...`, as `ssh-keygen -l` prints it.
#[uniffi::export]
pub fn sftp_fingerprint(host_key: String) -> Option<String> {
    core::fingerprint_of(&host_key)
}

#[uniffi::export]
pub fn sftp_same_host_key(a: String, b: String) -> bool {
    core::same_host_key_text(&a, &b)
}

/// The host key learned in this run for a destination (`trust_id`) on
/// `host:port`.
#[uniffi::export]
pub fn sftp_learned_host_key(trust_id: String, host: String, port: u16) -> Option<String> {
    core::learned_host_key(&trust_id, &host, port)
}

/// What a private key is, without its passphrase.
#[uniffi::export]
pub fn sftp_key_info(key: String) -> Result<SftpKeyInfo, SftpError> {
    let info = core::key_info(&key)?;
    Ok(SftpKeyInfo { algorithm: info.algorithm, encrypted: info.encrypted })
}

/// Reads (and decrypts) a private key as a sign-in would; returns its
/// algorithm.
#[uniffi::export]
pub fn sftp_check_private_key(key: String, passphrase: Option<String>) -> Result<String, SftpError> {
    let key = core::decode_private_key(&key, passphrase.as_deref())?;
    Ok(key.algorithm().as_str().to_string())
}
