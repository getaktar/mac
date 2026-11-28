//! SFTP destinations for Aktar (docs/storage-backends.md in the Mac repo,
//! "SFTP (phase 3)"): any SSH server with the SFTP subsystem (OpenSSH, a
//! Hetzner Storage Box, Synology, a VPS), with a web server serving the
//! same folder for links.
//!
//! This crate is shared by the desktop app (Windows and Linux) and the Mac
//! app, which wrap it in their own types and wording: it knows nothing of
//! destinations, credentials or translations. Its source of truth is the
//! desktop repo (`crates/sftp-core`); the Mac repo keeps an exact copy.
//!
//! The endpoint is `host`, `host:port` or `[v6address]:port` (22 when
//! left out), the folder is the base folder on the server, and a key is a
//! `/`-separated path under it, never with `..`. The secret is a
//! password, or a private key in OpenSSH (or PEM) format with an optional
//! passphrase.
//!
//! The server's host key is trusted on first use, like `ssh`: a client
//! without one takes the first key it sees and keeps it (and tells its
//! listener, see `Client::with_host_key_listener`); one with a different
//! key is refused before anything is sent, with `Error::HostKeyChanged`.
//!
//! Files go to `.<name>.aktar-part` next to their key and are renamed over
//! it once complete, so nobody ever downloads half a file; the part file
//! is removed when an upload fails or is cancelled. One SSH connection per
//! server and account is reused while operations follow each other, and
//! closed after a minute without any. Dropped connections and network
//! errors are tried again (three tries in all); sign-in and permission
//! errors aren't.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use russh::client;
use russh::keys::{HashAlg, PrivateKeyWithHashAlg};
use russh::MethodKind;
use russh_sftp::client::error::Error as SftpError;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::StatusCode;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};

/// russh's key types, for the apps' own tests and key handling.
pub use russh::keys;
pub use russh::keys::{PrivateKey, PublicKey};

pub const DEFAULT_PORT: u16 = 22;
/// Connecting, the key exchange and signing in, each.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// How long one SFTP request may wait for its answer.
const REQUEST_TIMEOUT_SECONDS: u64 = 60;
/// A connection nobody used for this long is closed.
pub const IDLE_CLOSE: Duration = Duration::from_secs(60);
/// How often an idle connection is looked at.
const IDLE_CHECK: Duration = Duration::from_secs(5);
/// Keepalives while the connection is open, so a long transfer through a
/// NAT or firewall isn't cut off; three unanswered ones end it.
const KEEPALIVE: Duration = Duration::from_secs(15);
/// The waits before the second and third try, as for WebDAV and S3.
pub const RETRY_DELAYS: [Duration; 2] = [Duration::from_secs(1), Duration::from_secs(2)];
/// What's read from a local file (or a remote one) at a time.
const CHUNK: usize = 256 * 1024;
const PART_SUFFIX: &str = ".aktar-part";

// MARK: - Errors

/// What went wrong, as kinds the apps word in their own language. Hosts
/// are as `Client::display_host` shows them; host keys are in OpenSSH
/// format (`host_key_text`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The endpoint isn't `host`, `host:port` or `[v6]:port`.
    InvalidEndpoint,
    /// The folder has a `..` in it.
    FolderHasParent,
    /// A key that can't be a path under the folder (it has `..`).
    InvalidName(String),
    /// The server didn't take the user name with the password or key.
    AuthFailed,
    /// An encrypted private key without its passphrase, or with a wrong one.
    KeyPassphrase,
    /// A private key of a type that can't sign in, by its name.
    UnsupportedKey(String),
    /// The private key's text can't be read.
    UnreadableKey,
    /// The host key kept for the server can't be read, so every connection
    /// is refused (never "any key") until a new one is saved.
    UnreadableHostKey,
    /// The server showed another key than the one kept for it (`stored`),
    /// so nothing was sent. `seen` is the key it showed, when known.
    HostKeyChanged { stored: Option<String>, seen: Option<String> },
    /// The server refused this (SFTP's permission denied).
    PermissionDenied,
    /// A folder that has to be there isn't (the base folder, or the folder
    /// being listed).
    FolderNotFound(String),
    /// The file isn't on the server.
    FileNotFound,
    /// A file is where a folder has to be made.
    FileInTheWay(String),
    /// The server refused the TCP connection.
    Refused { host: String },
    /// The server didn't answer in time while connecting.
    Timeout { host: String },
    /// The host name couldn't be looked up.
    HostNotFound { host: String },
    /// No key exchange, cipher or host key type in common.
    NoCommonAlgorithm { host: String, detail: String },
    /// The SSH server doesn't offer the SFTP subsystem.
    NoSftp,
    /// The server didn't show its host key.
    NoServerKey,
    /// The connection dropped or broke, with what was said about it.
    Dropped(String),
    /// An SFTP request went unanswered.
    ServerTimeout,
    /// The server's disk (or quota) is full.
    OutOfSpace,
    /// Another SFTP status, with the server's message (or the status code).
    ServerAnswered(String),
    /// The file is over the size asked for.
    TooLarge,
    /// An only-if-new upload found a file at the key.
    AlreadyExists,
    /// The operation was cancelled (`CancelToken`).
    Cancelled,
    /// A local file couldn't be read or written.
    Local(String),
    Other(String),
}

impl Error {
    /// Network trouble and dropped connections, which are tried again;
    /// never a sign-in, key or permission error.
    pub fn is_retryable(&self) -> bool {
        matches!(self, Error::Dropped(_) | Error::ServerTimeout | Error::Refused { .. } | Error::Timeout { .. } | Error::HostNotFound { .. })
    }
}

/// Plain English, for logs; the apps word errors themselves.
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::InvalidEndpoint => write!(f, "The server isn't a host name."),
            Error::FolderHasParent => write!(f, "The folder can't contain \"..\"."),
            Error::InvalidName(name) => write!(f, "This name can't be used on an SFTP server: {name}"),
            Error::AuthFailed => write!(f, "Could not sign in."),
            Error::KeyPassphrase => write!(f, "The key's passphrase is missing or wrong."),
            Error::UnsupportedKey(name) => write!(f, "Unsupported key type ({name})."),
            Error::UnreadableKey => write!(f, "The private key can't be read."),
            Error::UnreadableHostKey => write!(f, "The saved server key can't be read."),
            Error::HostKeyChanged { seen, .. } => write!(f, "The server's identity has changed ({}).", seen.as_deref().and_then(fingerprint_of).unwrap_or_default()),
            Error::PermissionDenied => write!(f, "Permission denied."),
            Error::FolderNotFound(path) => write!(f, "Folder not found on the server ({path})."),
            Error::FileNotFound => write!(f, "The file isn't on the server."),
            Error::FileInTheWay(folder) => write!(f, "A file is in the way of the folder {folder}."),
            Error::Refused { host } => write!(f, "{host} refused the connection."),
            Error::Timeout { host } => write!(f, "{host} didn't answer in time."),
            Error::HostNotFound { host } => write!(f, "{host} couldn't be found."),
            Error::NoCommonAlgorithm { host, detail } => write!(f, "No way of connecting to {host} in common ({detail})."),
            Error::NoSftp => write!(f, "This server doesn't offer SFTP."),
            Error::NoServerKey => write!(f, "The server didn't show its key."),
            Error::Dropped(message) => write!(f, "The connection broke: {message}"),
            Error::ServerTimeout => write!(f, "The server didn't answer in time."),
            Error::OutOfSpace => write!(f, "The server is out of space."),
            Error::ServerAnswered(message) => write!(f, "The server answered: {message}"),
            Error::TooLarge => write!(f, "The object is too large."),
            Error::AlreadyExists => write!(f, "Something is already at this name."),
            Error::Cancelled => write!(f, "Cancelled."),
            Error::Local(message) | Error::Other(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T, E = Error> = std::result::Result<T, E>;

// MARK: - Host keys

/// Host keys learned in this run, by trust ID and server, for a client
/// made from a copy of the destination taken before the key was saved.
fn learned_keys() -> &'static Mutex<HashMap<String, String>> {
    static LEARNED: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    LEARNED.get_or_init(Default::default)
}

/// The host key learned in this run for `trust_id` on `host:port`.
pub fn learned_host_key(trust_id: &str, host: &str, port: u16) -> Option<String> {
    learned_keys().lock().unwrap().get(&learned_key(trust_id, host, port)).cloned()
}

fn learned_key(trust_id: &str, host: &str, port: u16) -> String {
    format!("{trust_id}\n{host}:{port}")
}

/// A host key as stored (`ssh-ed25519 AAAA...`), or None when it can't be
/// read.
pub fn parse_host_key(text: &str) -> Option<PublicKey> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    PublicKey::from_openssh(text).ok()
}

/// How a host key is stored: algorithm and base64, without a comment.
pub fn host_key_text(key: &PublicKey) -> String {
    let mut key = key.clone();
    key.set_comment("");
    key.to_openssh().unwrap_or_default().trim().to_string()
}

/// A stored host key as it's kept (`host_key_text`), or None when it
/// can't be read.
pub fn normalize_host_key(text: &str) -> Option<String> {
    parse_host_key(text).map(|key| host_key_text(&key))
}

/// `SHA256:...`, as `ssh-keygen -l` prints it.
pub fn fingerprint(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

/// The fingerprint of a stored host key, when it can be read.
pub fn fingerprint_of(text: &str) -> Option<String> {
    parse_host_key(text).map(|key| fingerprint(&key))
}

/// Whether two host keys are the same key; comments don't count.
pub fn same_host_key(a: &PublicKey, b: &PublicKey) -> bool {
    a.key_data() == b.key_data()
}

/// Whether two stored host keys are the same key; false when either can't
/// be read.
pub fn same_host_key_text(a: &str, b: &str) -> bool {
    match (parse_host_key(a), parse_host_key(b)) {
        (Some(a), Some(b)) => same_host_key(&a, &b),
        _ => false,
    }
}

// MARK: - Endpoint, folder and keys

/// `host`, `host:port`, `[v6address]:port` or a bare IPv6 address, with
/// an `sftp://` (or `ssh://`) in front and a path after it tolerated.
pub fn parse_endpoint(endpoint: &str) -> Result<(String, u16)> {
    let invalid = || Error::InvalidEndpoint;
    let mut text = endpoint.trim();
    for scheme in ["sftp://", "ssh://"] {
        if text.len() >= scheme.len() && text[..scheme.len()].eq_ignore_ascii_case(scheme) {
            text = &text[scheme.len()..];
        }
    }
    // A user name in front ("me@host") isn't the place for it.
    if text.contains('@') {
        return Err(invalid());
    }
    let text = text.split('/').next().unwrap_or_default();
    if text.is_empty() {
        return Err(invalid());
    }
    let (host, port) = if let Some(rest) = text.strip_prefix('[') {
        let (host, after) = rest.split_once(']').ok_or_else(invalid)?;
        match after {
            "" => (host.to_string(), None),
            after => (host.to_string(), Some(after.strip_prefix(':').ok_or_else(invalid)?)),
        }
    } else if text.matches(':').count() > 1 {
        // A bare IPv6 address has no port.
        (text.to_string(), None)
    } else {
        match text.split_once(':') {
            Some((host, port)) => (host.to_string(), Some(port)),
            None => (text.to_string(), None),
        }
    };
    let port = match port {
        None => DEFAULT_PORT,
        Some(port) => port.parse::<u16>().ok().filter(|port| *port > 0).ok_or_else(invalid)?,
    };
    if host.is_empty() || host.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid());
    }
    Ok((host, port))
}

/// How a server is shown in messages: the host, with the port when it
/// isn't 22 (an IPv6 address in brackets then).
pub fn display_host(host: &str, port: u16) -> String {
    if port == DEFAULT_PORT {
        host.to_string()
    } else if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

/// The base folder as paths are made from it: "" for the login folder,
/// "/" for the root, else without a trailing "/" ("/var/www/files",
/// "files"). `~/` is the login folder too. `..` isn't allowed.
pub fn normalize_folder(folder: &str) -> Result<String> {
    let folder = folder.trim();
    let folder = folder.strip_prefix("~/").unwrap_or(if folder == "~" { "" } else { folder });
    let absolute = folder.starts_with('/');
    let mut segments = Vec::new();
    for segment in folder.split('/') {
        match segment {
            "" | "." => {}
            ".." => return Err(Error::FolderHasParent),
            segment => segments.push(segment),
        }
    }
    let joined = segments.join("/");
    Ok(if absolute { format!("/{joined}") } else { joined })
}

/// The path of `key` under `base` (see `normalize_folder`). Empty and "."
/// segments are left out; a key with ".." is refused, so nothing outside
/// the folder is ever touched. The base itself is "." for the login folder.
pub fn remote_path(base: &str, key: &str) -> Result<String> {
    let mut segments = Vec::new();
    for segment in key.split('/') {
        match segment {
            "" | "." => {}
            ".." => return Err(Error::InvalidName(key.to_string())),
            segment => segments.push(segment),
        }
    }
    let joined = segments.join("/");
    Ok(match (base, joined.as_str()) {
        ("", "") => ".".into(),
        ("", rest) => rest.to_string(),
        (base, "") => base.to_string(),
        ("/", rest) => format!("/{rest}"),
        (base, rest) => format!("{base}/{rest}"),
    })
}

/// Where a file is written before it's renamed over `path`:
/// `<dir>/.<name>.aktar-part`.
pub fn part_path(path: &str) -> String {
    match path.rfind('/') {
        Some(index) => format!("{}.{}{PART_SUFFIX}", &path[..=index], &path[index + 1..]),
        None => format!(".{path}{PART_SUFFIX}"),
    }
}

/// A part file left by an upload, which listings leave out.
pub fn is_part_file(name: &str) -> bool {
    name.starts_with('.') && name.ends_with(PART_SUFFIX) && name.len() > 1 + PART_SUFFIX.len()
}

/// The folders `path` is in below the base, from the top: for base
/// "/srv" and "/srv/a/b/c.txt", "/srv/a" and "/srv/a/b".
pub fn parent_folders(base: &str, path: &str) -> Vec<String> {
    let rest = match base {
        "" => path,
        "/" => path.strip_prefix('/').unwrap_or(path),
        base => path.strip_prefix(base).and_then(|rest| rest.strip_prefix('/')).unwrap_or(""),
    };
    let segments: Vec<&str> = rest.split('/').filter(|segment| !segment.is_empty()).collect();
    let mut folders = Vec::new();
    let mut current = match base {
        "" => String::new(),
        "/" => "/".to_string(),
        base => format!("{base}/"),
    };
    for segment in segments.iter().take(segments.len().saturating_sub(1)) {
        current.push_str(segment);
        folders.push(current.clone());
        current.push('/');
    }
    folders
}

/// "" or "a/b/": a folder key with exactly one trailing "/".
pub fn folder_prefix(raw: &str) -> String {
    let trimmed = raw.trim_matches('/');
    if trimmed.is_empty() {
        String::new()
    } else {
        format!("{trimmed}/")
    }
}

/// Whether the secret is a private key rather than a password.
pub fn is_private_key(secret: &str) -> bool {
    let secret = secret.trim_start();
    secret.starts_with("-----BEGIN") || secret.starts_with("PuTTY-User-Key-File-")
}

/// A pasted or picked private key, decrypted with `passphrase` when it's
/// encrypted. Line endings and the spaces around each line don't matter.
pub fn decode_private_key(text: &str, passphrase: Option<&str>) -> Result<PrivateKey> {
    let text = tidy_key(text);
    let passphrase = passphrase.filter(|passphrase| !passphrase.is_empty());
    // PEM says so in its header; OpenSSH only once it's read.
    let says_encrypted = text.contains("ENCRYPTED");
    let key = match keys::decode_secret_key(&text, None) {
        Ok(key) => Ok(key),
        Err(keys::Error::KeyIsEncrypted) => match passphrase {
            None => return Err(Error::KeyPassphrase),
            Some(passphrase) => keys::decode_secret_key(&text, Some(passphrase)).map_err(|_| Error::KeyPassphrase),
        },
        Err(_) if says_encrypted => match passphrase {
            None => return Err(Error::KeyPassphrase),
            Some(passphrase) => keys::decode_secret_key(&text, Some(passphrase)).map_err(|_| Error::KeyPassphrase),
        },
        Err(error) => Err(key_error(error)),
    }?;
    match key.algorithm() {
        keys::Algorithm::Ed25519 | keys::Algorithm::Rsa { .. } | keys::Algorithm::Ecdsa { .. } => Ok(key),
        other => Err(Error::UnsupportedKey(other.as_str().to_string())),
    }
}

/// What a private key is, read without its passphrase, for the form to
/// show ("ed25519 key, encrypted"). `algorithm` is the SSH name
/// (`ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, ...).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyInfo {
    pub algorithm: String,
    pub encrypted: bool,
}

/// See `KeyInfo`. OpenSSH keys say both without the passphrase; a PEM key
/// says whether it's encrypted, and its type only once it's read.
pub fn key_info(text: &str) -> Result<KeyInfo> {
    let text = tidy_key(text);
    if text.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----") {
        let key = keys::ssh_key::PrivateKey::from_openssh(&text).map_err(|error| key_error(keys::Error::SshKey(error)))?;
        return Ok(KeyInfo { algorithm: key.algorithm().as_str().to_string(), encrypted: key.is_encrypted() });
    }
    match keys::decode_secret_key(&text, None) {
        Ok(key) => Ok(KeyInfo { algorithm: key.algorithm().as_str().to_string(), encrypted: false }),
        Err(keys::Error::KeyIsEncrypted) => Ok(KeyInfo { algorithm: pem_algorithm(&text), encrypted: true }),
        Err(_) if text.contains("ENCRYPTED") => Ok(KeyInfo { algorithm: pem_algorithm(&text), encrypted: true }),
        Err(error) => Err(key_error(error)),
    }
}

/// The key type a PEM header names, as far as it does.
fn pem_algorithm(text: &str) -> String {
    if text.starts_with("-----BEGIN RSA PRIVATE KEY-----") {
        "ssh-rsa".into()
    } else if text.starts_with("-----BEGIN EC PRIVATE KEY-----") {
        "ecdsa".into()
    } else {
        String::new()
    }
}

fn tidy_key(text: &str) -> String {
    text.lines().map(str::trim).filter(|line| !line.is_empty()).collect::<Vec<_>>().join("\n") + "\n"
}

fn key_error(error: keys::Error) -> Error {
    match error {
        keys::Error::UnsupportedKeyType { key_type_string, .. } => Error::UnsupportedKey(key_type_string),
        keys::Error::SshKey(keys::ssh_key::Error::AlgorithmUnsupported { algorithm }) => Error::UnsupportedKey(algorithm.as_str().to_string()),
        keys::Error::SshKey(keys::ssh_key::Error::AlgorithmUnknown) => Error::UnsupportedKey("?".into()),
        _ => Error::UnreadableKey,
    }
}

#[derive(Debug)]
enum Auth {
    Password(String),
    Key { text: String, passphrase: Option<String> },
}

// MARK: - Progress and cancelling

/// Told how an upload goes: `start` with the file's size (again on each
/// try), then `advance` with each chunk's bytes as they're sent.
pub trait Progress: Send + Sync {
    fn start(&self, total: u64);
    fn advance(&self, bytes: u64);
}

/// Stops an upload or download from elsewhere: it ends with
/// `Error::Cancelled`, and an upload's part file is removed. Dropping the
/// operation's future does the same.
#[derive(Debug, Default)]
pub struct CancelToken {
    cancelled: AtomicBool,
    notify: tokio::sync::Notify,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

/// Runs `operation` until `cancel` (if any) is cancelled.
async fn cancellable<T>(cancel: Option<&CancelToken>, operation: impl Future<Output = Result<T>>) -> Result<T> {
    match cancel {
        None => operation.await,
        Some(token) => {
            if token.is_cancelled() {
                return Err(Error::Cancelled);
            }
            tokio::select! {
                result = operation => result,
                () = token.cancelled() => Err(Error::Cancelled),
            }
        }
    }
}

// MARK: - Connections

/// What the connection's handler saw of the server's key, and whether it
/// may go on.
struct Handler {
    expected: Option<PublicKey>,
    seen: Arc<Mutex<Option<PublicKey>>>,
}

impl client::Handler for Handler {
    type Error = russh::Error;

    async fn check_server_key(&mut self, server_public_key: &keys::PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let key = server_public_key.public_key();
        *self.seen.lock().unwrap() = Some(key.clone());
        Ok(self.expected.as_ref().is_none_or(|expected| same_host_key(expected, &key)))
    }
}

/// An SSH connection with its SFTP session.
pub struct Connection {
    handle: client::Handle<Handler>,
    sftp: SftpSession,
    host_key: PublicKey,
    /// Operations using it right now.
    busy: AtomicUsize,
    last_used: Mutex<Instant>,
    /// Folders made (or found there) through it, so each is asked for once.
    made_folders: Mutex<HashSet<String>>,
}

impl Connection {
    fn is_closed(&self) -> bool {
        self.handle.is_closed()
    }

    async fn close(&self) {
        let _ = self.sftp.close().await;
        let _ = self.handle.disconnect(russh::Disconnect::ByApplication, "", "en").await;
    }
}

/// A connection in use, given back to the pool when dropped.
struct Lease(Arc<Connection>);

impl Lease {
    fn new(connection: Arc<Connection>) -> Self {
        connection.busy.fetch_add(1, Ordering::SeqCst);
        Self(connection)
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        *self.0.last_used.lock().unwrap() = Instant::now();
        self.0.busy.fetch_sub(1, Ordering::SeqCst);
    }
}

fn pool() -> &'static Mutex<HashMap<String, Arc<Connection>>> {
    static POOL: OnceLock<Mutex<HashMap<String, Arc<Connection>>>> = OnceLock::new();
    POOL.get_or_init(Default::default)
}

/// One lock per pool key, so operations starting at once wait for one new
/// connection instead of each making their own.
fn connect_lock(key: &str) -> Arc<tokio::sync::Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    let mut locks = LOCKS.get_or_init(Default::default).lock().unwrap();
    // Locks nobody holds or waits for are let go of.
    locks.retain(|_, lock| Arc::strong_count(lock) > 1);
    locks.entry(key.to_string()).or_default().clone()
}

/// How many connections are pooled right now.
pub fn pooled_connections() -> usize {
    pool().lock().unwrap().len()
}

/// Closes every pooled connection (as if the server had dropped them).
pub async fn close_pooled_connections() {
    let pooled: Vec<Arc<Connection>> = pool().lock().unwrap().values().cloned().collect();
    for connection in pooled {
        connection.close().await;
    }
}

/// Closes the pooled connection once it's been idle for `IDLE_CLOSE`, or
/// forgets it once the server closed it.
fn watch_idle(key: String, connection: Arc<Connection>) {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
    runtime.spawn(async move {
        loop {
            tokio::time::sleep(IDLE_CHECK).await;
            let idle = connection.busy.load(Ordering::SeqCst) == 0 && connection.last_used.lock().unwrap().elapsed() >= IDLE_CLOSE;
            if idle || connection.is_closed() {
                {
                    let mut pool = pool().lock().unwrap();
                    if pool.get(&key).is_some_and(|pooled| Arc::ptr_eq(pooled, &connection)) {
                        pool.remove(&key);
                    }
                }
                if !connection.is_closed() {
                    connection.close().await;
                }
                return;
            }
        }
    });
}

// MARK: - Client

/// Where and how to connect.
#[derive(Debug, Clone, Default)]
pub struct ClientConfig {
    /// See `parse_endpoint`.
    pub endpoint: String,
    /// The base folder; see `normalize_folder`.
    pub folder: String,
    pub user: String,
    /// The password, or a private key (`is_private_key`).
    pub secret: String,
    pub key_passphrase: Option<String>,
    /// The host key kept for the server (OpenSSH format), if any.
    pub host_key: Option<String>,
    /// Which destination this is, for keys trusted on first use: a key
    /// learned under this ID (and server) is the expected one for later
    /// clients with the same ID and no stored key. Empty: none is learned
    /// for later.
    pub trust_id: String,
}

type HostKeyListener = Arc<dyn Fn(&str) + Send + Sync>;

/// One SFTP destination's connection settings and operations. Cheap to
/// make: connections come from the shared pool.
pub struct Client {
    host: String,
    port: u16,
    /// See `normalize_folder`.
    base: String,
    user: String,
    auth: Auth,
    /// The host key kept for the server, if any.
    stored_host_key: Option<PublicKey>,
    /// It keeps one this version can't read: every connection is refused
    /// until Test Connection shows the server's and it's saved.
    unreadable_host_key: bool,
    trust_id: String,
    on_learned: Option<HostKeyListener>,
}

/// What a folder holds, as far as a listing goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub is_folder: bool,
    pub size: i64,
    /// Unix milliseconds.
    pub last_modified: Option<i64>,
}

/// A file's size and when it was last written (Unix milliseconds).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileInfo {
    pub size: i64,
    pub last_modified: Option<i64>,
}

/// What Test Connection found.
pub enum TestOutcome {
    /// Connected and signed in to a server showing the expected key (or
    /// any, without one), with the folder there.
    Connected(TestSession),
    /// The server shows another key than the stored one: nothing was sent.
    /// `seen` is the key it shows, when a second look got it.
    HostKeyChanged { stored: Option<String>, seen: Option<String> },
}

/// Test Connection's own connection, kept open while the app checks the
/// test file's public link; `finish` deletes the file and closes it.
pub struct TestSession {
    connection: Arc<Connection>,
    /// The server's key (`host_key_text`) and its fingerprint.
    pub host_key: String,
    pub fingerprint: String,
    /// Whether the test file could be written.
    pub writable: bool,
    /// The test file's key under the folder.
    pub test_key: String,
    test_path: String,
}

impl TestSession {
    /// Deletes the test file and closes the connection.
    pub async fn finish(self) {
        if self.writable {
            let _ = self.connection.sftp.remove_file(self.test_path.as_str()).await;
        }
        self.connection.close().await;
    }
}

impl Client {
    /// Refuses a server or folder that can't be right before anything is sent.
    pub fn new(config: ClientConfig) -> Result<Self> {
        let (host, port) = parse_endpoint(&config.endpoint)?;
        let base = normalize_folder(&config.folder)?;
        let secret = config.secret;
        let auth = if is_private_key(&secret) {
            Auth::Key { text: secret, passphrase: config.key_passphrase.filter(|passphrase| !passphrase.is_empty()) }
        } else {
            Auth::Password(secret)
        };
        let saved_key = config.host_key.as_deref().map(str::trim).filter(|key| !key.is_empty());
        let stored_host_key = saved_key.and_then(parse_host_key);
        // Never "any key" for one that can't be read.
        let unreadable_host_key = saved_key.is_some() && stored_host_key.is_none();
        Ok(Self {
            host,
            port,
            base,
            user: config.user.trim().to_string(),
            auth,
            stored_host_key,
            unreadable_host_key,
            trust_id: config.trust_id,
            on_learned: None,
        })
    }

    /// Called with the host key (OpenSSH format) a first connection saw,
    /// when there was none to expect, so the app can keep it.
    pub fn with_host_key_listener(mut self, listener: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.on_learned = Some(Arc::new(listener));
        self
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The base folder (`normalize_folder`).
    pub fn base(&self) -> &str {
        &self.base
    }

    /// Whether it signs in with a private key rather than a password.
    pub fn uses_key(&self) -> bool {
        matches!(self.auth, Auth::Key { .. })
    }

    /// Whether the key's passphrase is set (an empty one counts as none).
    pub fn has_passphrase(&self) -> bool {
        matches!(&self.auth, Auth::Key { passphrase: Some(_), .. })
    }

    /// Whether the stored host key can't be read (see `Error::UnreadableHostKey`).
    pub fn has_unreadable_host_key(&self) -> bool {
        self.unreadable_host_key
    }

    /// The host key a connection has to show: the stored one, else one
    /// learned in this run.
    fn expected_host_key(&self) -> Option<PublicKey> {
        self.stored_host_key.clone().or_else(|| learned_host_key(&self.trust_id, &self.host, self.port).and_then(|text| parse_host_key(&text)))
    }

    /// Which pooled connection this client can use: same server, account,
    /// secret and host key.
    pub fn pool_key(&self) -> String {
        let mut hash = Sha256::new();
        for part in [self.host.as_str(), &self.port.to_string(), &self.user] {
            hash.update(part.as_bytes());
            hash.update([0]);
        }
        match &self.auth {
            Auth::Password(password) => hash.update(password.as_bytes()),
            Auth::Key { text, passphrase } => {
                hash.update(text.as_bytes());
                hash.update([0]);
                hash.update(passphrase.as_deref().unwrap_or_default().as_bytes());
            }
        }
        hash.update([0]);
        if let Some(key) = self.expected_host_key() {
            hash.update(host_key_text(&key).as_bytes());
        }
        hash.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
    }

    pub fn display_host(&self) -> String {
        display_host(&self.host, self.port)
    }

    /// Connects (with `expected` as the only host key allowed, or any when
    /// None), signs in and starts SFTP. The key the server showed comes
    /// back with the error when it isn't the expected one.
    async fn connect(&self, expected: Option<PublicKey>) -> Result<Connection> {
        let display = self.display_host();
        let addresses = match tokio::time::timeout(CONNECT_TIMEOUT, tokio::net::lookup_host((self.host.as_str(), self.port))).await {
            Err(_) => return Err(Error::Timeout { host: display }),
            Ok(Err(_)) => return Err(Error::HostNotFound { host: display }),
            Ok(Ok(addresses)) => addresses.collect::<Vec<_>>(),
        };
        if addresses.is_empty() {
            return Err(Error::HostNotFound { host: display });
        }
        let config = Arc::new(client::Config {
            keepalive_interval: Some(KEEPALIVE),
            keepalive_max: 3,
            nodelay: true,
            ..Default::default()
        });
        let seen = Arc::new(Mutex::new(None));
        let handler = Handler { expected: expected.clone(), seen: seen.clone() };
        let connected = tokio::time::timeout(CONNECT_TIMEOUT, client::connect(config, addresses.as_slice(), handler)).await;
        let mut handle = match connected {
            Err(_) => return Err(Error::Timeout { host: display }),
            Ok(Err(russh::Error::UnknownKey)) => {
                let seen = seen.lock().unwrap().clone();
                return Err(Error::HostKeyChanged { stored: expected.as_ref().map(host_key_text), seen: seen.as_ref().map(host_key_text) });
            }
            Ok(Err(error)) => return Err(connect_error(error, &display)),
            Ok(Ok(handle)) => handle,
        };
        let host_key = seen.lock().unwrap().clone().ok_or(Error::NoServerKey)?;
        match tokio::time::timeout(CONNECT_TIMEOUT, self.authenticate(&mut handle)).await {
            Err(_) => return Err(Error::Timeout { host: display }),
            Ok(result) => result?,
        }
        let channel = handle.channel_open_session().await.map_err(|error| connect_error(error, &display))?;
        channel.request_subsystem(true, "sftp").await.map_err(|error| connect_error(error, &display))?;
        let sftp_config = russh_sftp::client::Config { request_timeout_secs: REQUEST_TIMEOUT_SECONDS, ..Default::default() };
        let sftp = match tokio::time::timeout(CONNECT_TIMEOUT, SftpSession::new_with_config(channel.into_stream(), sftp_config)).await {
            Err(_) => return Err(Error::Timeout { host: display }),
            Ok(Err(_)) => return Err(Error::NoSftp),
            Ok(Ok(sftp)) => sftp,
        };
        Ok(Connection {
            handle,
            sftp,
            host_key,
            busy: AtomicUsize::new(0),
            last_used: Mutex::new(Instant::now()),
            made_folders: Mutex::new(HashSet::new()),
        })
    }

    /// Password (or keyboard-interactive with the password, for servers
    /// that only take that), or the private key.
    async fn authenticate(&self, handle: &mut client::Handle<Handler>) -> Result<()> {
        let user = self.user.clone();
        let failed = |error: russh::Error| Error::Dropped(error.to_string());
        let accepted = match &self.auth {
            Auth::Password(password) => match handle.authenticate_password(user.clone(), password.clone()).await.map_err(failed)? {
                client::AuthResult::Success => true,
                client::AuthResult::Failure { remaining_methods, .. } if remaining_methods.contains(&MethodKind::KeyboardInteractive) => {
                    self.keyboard_interactive(handle, password).await?
                }
                client::AuthResult::Failure { .. } => false,
            },
            Auth::Key { text, passphrase } => {
                let key = decode_private_key(text, passphrase.as_deref())?;
                let hash = if key.algorithm().is_rsa() {
                    // A server that doesn't say which RSA signatures it takes
                    // gets SHA-256 (OpenSSH refuses the old SHA-1 one).
                    match tokio::time::timeout(Duration::from_secs(5), handle.best_supported_rsa_hash()).await {
                        Ok(Ok(Some(hash))) => hash,
                        _ => Some(HashAlg::Sha256),
                    }
                } else {
                    None
                };
                handle.authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash)).await.map_err(failed)?.success()
            }
        };
        if accepted {
            Ok(())
        } else {
            Err(Error::AuthFailed)
        }
    }

    async fn keyboard_interactive(&self, handle: &mut client::Handle<Handler>, password: &str) -> Result<bool> {
        let failed = |error: russh::Error| Error::Dropped(error.to_string());
        let mut response = handle.authenticate_keyboard_interactive_start(self.user.clone(), None::<String>).await.map_err(failed)?;
        // A server asking over and over isn't taking the password.
        for _ in 0..3 {
            match response {
                client::KeyboardInteractiveAuthResponse::Success => return Ok(true),
                client::KeyboardInteractiveAuthResponse::Failure { .. } => return Ok(false),
                client::KeyboardInteractiveAuthResponse::InfoRequest { prompts, .. } => {
                    let answers = prompts.iter().map(|_| password.to_string()).collect();
                    response = handle.authenticate_keyboard_interactive_respond(answers).await.map_err(failed)?;
                }
            }
        }
        Ok(false)
    }

    /// A pooled connection, or a new one. A new one to a destination
    /// without a host key keeps the key it saw.
    async fn lease(&self) -> Result<Lease> {
        if self.unreadable_host_key {
            return Err(Error::UnreadableHostKey);
        }
        let key = self.pool_key();
        let pooled = || pool().lock().unwrap().get(&key).filter(|connection| !connection.is_closed()).cloned();
        if let Some(connection) = pooled() {
            return Ok(Lease::new(connection));
        }
        let lock = connect_lock(&key);
        let _connecting = lock.lock().await;
        // Made while this one waited.
        if let Some(connection) = pooled() {
            return Ok(Lease::new(connection));
        }
        let expected = self.expected_host_key();
        let connection = Arc::new(self.connect(expected.clone()).await?);
        if expected.is_none() {
            self.learn(&connection.host_key);
        }
        let lease = Lease::new(connection.clone());
        pool().lock().unwrap().insert(key.clone(), connection.clone());
        watch_idle(key, connection);
        Ok(lease)
    }

    fn learn(&self, key: &PublicKey) {
        let text = host_key_text(key);
        if !self.trust_id.is_empty() {
            learned_keys().lock().unwrap().insert(learned_key(&self.trust_id, &self.host, self.port), text.clone());
        }
        if let Some(listener) = &self.on_learned {
            listener(&text);
        }
    }

    /// Forgets the pooled connection, after it failed.
    fn drop_pooled(&self) {
        let key = self.pool_key();
        if let Some(connection) = pool().lock().unwrap().remove(&key) {
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move { connection.close().await });
            }
        }
    }

    /// Runs `operation` on a connection, tried again on a new one after a
    /// network error or dropped connection (`RETRY_DELAYS`).
    async fn run<T, F, Fut>(&self, operation: F) -> Result<T>
    where
        F: Fn(Arc<Connection>) -> Fut,
        Fut: Future<Output = Result<T>>,
    {
        let mut attempt = 0;
        loop {
            let result = match self.lease().await {
                Ok(lease) => {
                    let result = operation(lease.0.clone()).await;
                    drop(lease);
                    result
                }
                Err(error) => Err(error),
            };
            match result {
                Err(error) if error.is_retryable() && attempt < RETRY_DELAYS.len() => {
                    self.drop_pooled();
                    tokio::time::sleep(RETRY_DELAYS[attempt]).await;
                    attempt += 1;
                }
                result => return result,
            }
        }
    }

    /// The path of `key` under the base folder.
    pub fn path(&self, key: &str) -> Result<String> {
        remote_path(&self.base, key)
    }

    /// Connects afresh (shows the key), signs in, looks at the folder, and
    /// writes a test file. A server whose key isn't the stored one is
    /// reported before signing in, and nothing else is tried. A key seen
    /// here isn't learned: the app shows it and saving keeps it.
    pub async fn test_connection(&self) -> Result<TestOutcome> {
        let attempt = if self.unreadable_host_key { Err(Error::HostKeyChanged { stored: None, seen: None }) } else { self.connect(self.stored_host_key.clone()).await };
        let connection = match attempt {
            Ok(connection) => Arc::new(connection),
            Err(Error::HostKeyChanged { seen, .. }) => {
                // Once more, taking any key, only to show which it is.
                let shown = self.seen_key().await.map(|key| host_key_text(&key)).or(seen);
                return Ok(TestOutcome::HostKeyChanged { stored: self.stored_host_key.as_ref().map(host_key_text), seen: shown });
            }
            Err(error) => return Err(error),
        };
        let base = self.path("")?;
        let checked = match connection.sftp.metadata(base.as_str()).await {
            Ok(metadata) if metadata.is_dir() => Ok(()),
            Ok(_) => Err(Error::FolderNotFound(base)),
            Err(error) => Err(sftp_error(error, Some(&base))),
        };
        if let Err(error) = checked {
            connection.close().await;
            return Err(error);
        }
        let test_key = format!("_aktar_test_{}.txt", &uuid::Uuid::new_v4().to_string().to_uppercase()[..8]);
        let test_path = self.path(&test_key)?;
        let writable = write_file(&connection, &test_path, &mut &b"aktar connection test"[..], None).await.is_ok();
        Ok(TestOutcome::Connected(TestSession {
            host_key: host_key_text(&connection.host_key),
            fingerprint: fingerprint(&connection.host_key),
            connection,
            writable,
            test_key,
            test_path,
        }))
    }

    /// The key the server shows, without signing in.
    async fn seen_key(&self) -> Option<PublicKey> {
        let addresses: Vec<_> = tokio::net::lookup_host((self.host.as_str(), self.port)).await.ok()?.collect();
        let seen = Arc::new(Mutex::new(None));
        let handler = Handler { expected: None, seen: seen.clone() };
        let handle = tokio::time::timeout(CONNECT_TIMEOUT, client::connect(Arc::new(client::Config::default()), addresses.as_slice(), handler))
            .await
            .ok()?
            .ok()?;
        let _ = handle.disconnect(russh::Disconnect::ByApplication, "", "en").await;
        let key = seen.lock().unwrap().clone();
        key
    }

    /// Streams the local file to its part file, counting the bytes sent
    /// into `progress`, then renames it over the key, after making the
    /// folders it goes in. With `only_if_new`, a file already at the key is
    /// left alone (`Error::AlreadyExists`). Returns the file's size.
    pub async fn upload(&self, local: &Path, key: &str, progress: Option<Arc<dyn Progress>>, only_if_new: bool, cancel: Option<&CancelToken>) -> Result<u64> {
        let byte_size = tokio::fs::metadata(local).await.map_err(|error| Error::Local(error.to_string()))?.len();
        if let Some(progress) = &progress {
            progress.start(byte_size);
        }
        let remote = self.path(key)?;
        let base = self.base.clone();
        let upload = self.run(|connection| {
            let remote = remote.clone();
            let base = base.clone();
            let progress = progress.clone();
            async move {
                if only_if_new && stat(&connection, &remote).await?.is_some() {
                    return Err(Error::AlreadyExists);
                }
                if let Some(progress) = &progress {
                    progress.start(byte_size);
                }
                make_parents(&connection, &base, &remote).await?;
                let mut file = tokio::fs::File::open(local).await.map_err(|error| Error::Local(error.to_string()))?;
                write_file(&connection, &remote, &mut file, progress.as_deref()).await
            }
        });
        cancellable(cancel, upload).await?;
        Ok(byte_size)
    }

    /// A small file from memory (thumbnails, share pages).
    pub async fn put_bytes(&self, key: &str, data: &[u8]) -> Result<()> {
        let remote = self.path(key)?;
        let base = self.base.clone();
        self.run(|connection| {
            let remote = remote.clone();
            let base = base.clone();
            async move {
                make_parents(&connection, &base, &remote).await?;
                write_file(&connection, &remote, &mut &data[..], None).await
            }
        })
        .await
    }

    /// A small file and when it was last written, or None when it's not
    /// there (or is a folder). Anything over `max_bytes` is refused.
    pub async fn get_small(&self, key: &str, max_bytes: u64) -> Result<Option<(Vec<u8>, Option<i64>)>> {
        let remote = self.path(key)?;
        self.run(|connection| {
            let remote = remote.clone();
            async move {
                let Some(metadata) = stat(&connection, &remote).await? else { return Ok(None) };
                if metadata.is_dir() {
                    return Ok(None);
                }
                if metadata.size.is_some_and(|size| size > max_bytes) {
                    return Err(Error::TooLarge);
                }
                let file = connection.sftp.open(remote.as_str()).await.map_err(|error| sftp_error(error, None))?;
                let mut data = Vec::new();
                file.take(max_bytes + 1).read_to_end(&mut data).await.map_err(io_error)?;
                if data.len() as u64 > max_bytes {
                    return Err(Error::TooLarge);
                }
                Ok(Some((data, metadata.mtime.map(|seconds| seconds as i64 * 1000))))
            }
        })
        .await
    }

    /// Downloads the file at `key` to `destination`, stopping past
    /// `max_bytes` (the partial file is removed). False when there's no
    /// such file.
    pub async fn download(&self, key: &str, destination: &Path, max_bytes: u64, cancel: Option<&CancelToken>) -> Result<bool> {
        let remote = self.path(key)?;
        let download = self.run(|connection| {
            let remote = remote.clone();
            async move {
                let Some(metadata) = stat(&connection, &remote).await? else { return Ok(false) };
                if metadata.is_dir() {
                    return Ok(false);
                }
                if metadata.size.is_some_and(|size| size > max_bytes) {
                    return Err(Error::TooLarge);
                }
                let mut source = connection.sftp.open(remote.as_str()).await.map_err(|error| sftp_error(error, None))?;
                let mut file = tokio::fs::File::create(destination).await.map_err(|error| Error::Local(error.to_string()))?;
                let mut buffer = vec![0u8; CHUNK];
                let mut written = 0u64;
                let result: Result<()> = async {
                    loop {
                        let read = source.read(&mut buffer).await.map_err(io_error)?;
                        if read == 0 {
                            break;
                        }
                        written += read as u64;
                        if written > max_bytes {
                            return Err(Error::TooLarge);
                        }
                        file.write_all(&buffer[..read]).await.map_err(|error| Error::Local(error.to_string()))?;
                    }
                    file.flush().await.map_err(|error| Error::Local(error.to_string()))
                }
                .await;
                if result.is_err() {
                    drop(file);
                    let _ = tokio::fs::remove_file(destination).await;
                }
                result.map(|()| true)
            }
        });
        let result = cancellable(cancel, download).await;
        if matches!(result, Err(Error::Cancelled)) {
            let _ = tokio::fs::remove_file(destination).await;
        }
        result
    }

    /// `remove`; no such file counts as done. A folder (a key ending in
    /// "/") goes only when it's empty, and never the base folder itself.
    pub async fn delete(&self, key: &str) -> Result<()> {
        let remote = self.path(key)?;
        let is_folder = key.ends_with('/');
        if is_folder && remote == self.path("")? {
            return Ok(());
        }
        self.run(|connection| {
            let remote = remote.clone();
            async move {
                let result = if is_folder {
                    connection.made_folders.lock().unwrap().retain(|folder| !(folder == &remote || folder.starts_with(&format!("{remote}/"))));
                    match connection.sftp.read_dir(remote.as_str()).await {
                        Ok(mut entries) => {
                            if entries.next().is_some() {
                                return Ok(());
                            }
                            connection.sftp.remove_dir(remote.as_str()).await
                        }
                        Err(error) => Err(error),
                    }
                } else {
                    connection.sftp.remove_file(remote.as_str()).await
                };
                match result {
                    Ok(()) => Ok(()),
                    Err(error) if is_status(&error, StatusCode::NoSuchFile) => Ok(()),
                    Err(error) => Err(sftp_error(error, None)),
                }
            }
        })
        .await
    }

    /// `stat`: size and mtime, or None when there's no file (a folder
    /// isn't one).
    pub async fn info(&self, key: &str) -> Result<Option<FileInfo>> {
        let remote = self.path(key)?;
        self.run(|connection| {
            let remote = remote.clone();
            async move {
                Ok(stat(&connection, &remote).await?.filter(|metadata| !metadata.is_dir()).map(|metadata| FileInfo {
                    size: metadata.size.unwrap_or_default() as i64,
                    last_modified: metadata.mtime.map(|seconds| seconds as i64 * 1000),
                }))
            }
        })
        .await
    }

    /// The folders and files directly in the folder `prefix` (a folder
    /// key, see `folder_prefix`); `.`, `..` and part files are left out,
    /// and a link counts as what it points at. A folder that isn't there
    /// is `Error::FolderNotFound`.
    pub async fn list(&self, prefix: &str) -> Result<Vec<Entry>> {
        let remote = self.path(&folder_prefix(prefix))?;
        self.run(|connection| {
            let remote = remote.clone();
            async move { list_folder(&connection, &remote).await }
        })
        .await
    }

    /// Read and written again through the app (SFTP has no server-side
    /// copy), with the same part-file rule.
    pub async fn copy(&self, source_key: &str, destination_key: &str) -> Result<()> {
        let source = self.path(source_key)?;
        let destination = self.path(destination_key)?;
        let base = self.base.clone();
        self.run(|connection| {
            let source = source.clone();
            let destination = destination.clone();
            let base = base.clone();
            async move {
                make_parents(&connection, &base, &destination).await?;
                let mut file = connection.sftp.open(source.as_str()).await.map_err(|error| sftp_error(error, None))?;
                write_file(&connection, &destination, &mut file, None).await
            }
        })
        .await
    }

    /// A move on the server (`rename`, replacing what's at the target),
    /// after making the target's folders.
    pub async fn rename(&self, source_key: &str, destination_key: &str) -> Result<()> {
        let source = self.path(source_key)?;
        let destination = self.path(destination_key)?;
        let base = self.base.clone();
        self.run(|connection| {
            let source = source.clone();
            let destination = destination.clone();
            let base = base.clone();
            async move {
                make_parents(&connection, &base, &destination).await?;
                replace(&connection, &source, &destination).await
            }
        })
        .await
    }

    /// `mkdir` of the folder and each one it's in.
    pub async fn create_folder(&self, prefix: &str) -> Result<()> {
        let prefix = folder_prefix(prefix);
        if prefix.is_empty() {
            return Ok(());
        }
        let remote = self.path(&prefix)?;
        let base = self.base.clone();
        self.run(|connection| {
            let remote = remote.clone();
            let base = base.clone();
            async move {
                make_parents(&connection, &base, &remote).await?;
                make_folder(&connection, &remote).await
            }
        })
        .await
    }
}

async fn list_folder(connection: &Connection, remote: &str) -> Result<Vec<Entry>> {
    let entries = connection.sftp.read_dir(remote).await.map_err(|error| sftp_error(error, Some(remote)))?;
    let mut listed = Vec::new();
    for entry in entries {
        let name = entry.file_name();
        if name == "." || name == ".." || name.contains('/') || is_part_file(&name) {
            continue;
        }
        let mut metadata = entry.metadata();
        if metadata.is_symlink() {
            // What the link points at decides whether it's a folder.
            let target = if remote == "." { name.clone() } else { format!("{}/{name}", remote.trim_end_matches('/')) };
            if let Ok(followed) = connection.sftp.metadata(target.as_str()).await {
                metadata = followed;
            }
        }
        listed.push(Entry {
            name,
            is_folder: metadata.is_dir(),
            size: metadata.size.unwrap_or_default() as i64,
            last_modified: metadata.mtime.map(|seconds| seconds as i64 * 1000),
        });
    }
    Ok(listed)
}

/// `stat`, or None for no such file.
async fn stat(connection: &Connection, remote: &str) -> Result<Option<russh_sftp::client::fs::Metadata>> {
    match connection.sftp.metadata(remote).await {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if is_status(&error, StatusCode::NoSuchFile) => Ok(None),
        Err(error) => Err(sftp_error(error, None)),
    }
}

/// `mkdir` for each folder `path` is in, below the base (which has to
/// exist: a missing one is "folder not found").
async fn make_parents(connection: &Connection, base: &str, path: &str) -> Result<()> {
    for folder in parent_folders(base, path) {
        make_folder(connection, &folder).await.map_err(|error| match error {
            Error::FolderNotFound(_) => Error::FolderNotFound(if base.is_empty() { ".".into() } else { base.to_string() }),
            other => other,
        })?;
    }
    Ok(())
}

/// One `mkdir`, unless this connection made the folder already; one
/// that's there is fine.
async fn make_folder(connection: &Connection, folder: &str) -> Result<()> {
    if connection.made_folders.lock().unwrap().contains(folder) {
        return Ok(());
    }
    if let Err(error) = connection.sftp.create_dir(folder).await {
        match connection.sftp.metadata(folder).await {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => return Err(Error::FileInTheWay(folder.to_string())),
            Err(_) if is_status(&error, StatusCode::NoSuchFile) => return Err(Error::FolderNotFound(folder.to_string())),
            Err(_) => return Err(sftp_error(error, None)),
        }
    }
    connection.made_folders.lock().unwrap().insert(folder.to_string());
    Ok(())
}

/// Removes a part file that never got renamed (an upload that failed, or
/// was dropped when it was cancelled).
struct PartGuard {
    connection: Option<Arc<Connection>>,
    path: String,
}

impl PartGuard {
    fn disarm(&mut self) {
        self.connection = None;
    }
}

impl Drop for PartGuard {
    fn drop(&mut self) {
        let Some(connection) = self.connection.take() else { return };
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        let path = std::mem::take(&mut self.path);
        runtime.spawn(async move {
            let _ = connection.sftp.remove_file(path.as_str()).await;
        });
    }
}

/// Writes `source` to the part file next to `path`, then renames it over
/// `path`. `progress` counts the bytes as they go.
async fn write_file<R: AsyncRead + Unpin>(connection: &Arc<Connection>, path: &str, source: &mut R, progress: Option<&dyn Progress>) -> Result<()> {
    let part = part_path(path);
    let mut guard = PartGuard { connection: Some(connection.clone()), path: part.clone() };
    let mut file = connection.sftp.create(part.as_str()).await.map_err(|error| sftp_error(error, None))?;
    let mut buffer = vec![0u8; CHUNK];
    loop {
        let read = source.read(&mut buffer).await.map_err(|error| Error::Local(error.to_string()))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read]).await.map_err(io_error)?;
        if let Some(progress) = progress {
            progress.advance(read as u64);
        }
    }
    // Waits for every write to be confirmed.
    file.shutdown().await.map_err(io_error)?;
    replace(connection, &part, path).await?;
    guard.disarm();
    Ok(())
}

/// Moves `from` over `to`: `posix-rename@openssh.com` where the server
/// has it, else removing `to` first (plain SFTP rename won't replace).
async fn replace(connection: &Connection, from: &str, to: &str) -> Result<()> {
    match connection.sftp.posix_rename(from, to).await {
        Ok(true) => return Ok(()),
        Ok(false) => {}
        Err(error) => return Err(sftp_error(error, None)),
    }
    match connection.sftp.remove_file(to).await {
        Ok(()) => {}
        Err(error) if is_status(&error, StatusCode::NoSuchFile) => {}
        Err(error) => return Err(sftp_error(error, None)),
    }
    connection.sftp.rename(from, to).await.map_err(|error| sftp_error(error, None))
}

// MARK: - Error mapping

fn is_status(error: &SftpError, code: StatusCode) -> bool {
    matches!(error, SftpError::Status(status) if status.status_code == code)
}

/// An SFTP error as an `Error`. `folder`: what was asked for is a folder
/// that has to exist, so no such file is that folder missing.
fn sftp_error(error: SftpError, folder: Option<&str>) -> Error {
    match error {
        SftpError::Status(status) => match status.status_code {
            StatusCode::NoSuchFile => match folder {
                Some(folder) => Error::FolderNotFound(folder.to_string()),
                None => Error::FileNotFound,
            },
            StatusCode::PermissionDenied => Error::PermissionDenied,
            StatusCode::NoConnection | StatusCode::ConnectionLost => Error::Dropped(status.status_code.to_string()),
            _ if mentions_full_disk(&status.error_message) => Error::OutOfSpace,
            code => {
                let message = status.error_message.trim();
                Error::ServerAnswered(if message.is_empty() { code.to_string() } else { message.to_string() })
            }
        },
        SftpError::Timeout => Error::ServerTimeout,
        SftpError::IO(message) => Error::Dropped(message),
        SftpError::UnexpectedBehavior(message) => Error::Dropped(message),
        other => Error::Other(other.to_string()),
    }
}

/// An error writing or reading a remote file (the SFTP status is only
/// left as its message by then).
fn io_error(error: std::io::Error) -> Error {
    let message = error.to_string();
    if mentions_full_disk(&message) {
        return Error::OutOfSpace;
    }
    if message.to_ascii_lowercase().contains("permission denied") {
        return Error::PermissionDenied;
    }
    Error::Dropped(message)
}

fn mentions_full_disk(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("no space") || message.contains("quota") || message.contains("disk full")
}

fn connect_error(error: russh::Error, host: &str) -> Error {
    match &error {
        russh::Error::IO(io) => match io.kind() {
            std::io::ErrorKind::ConnectionRefused => Error::Refused { host: host.to_string() },
            std::io::ErrorKind::TimedOut => Error::Timeout { host: host.to_string() },
            _ => Error::Dropped(error.to_string()),
        },
        russh::Error::ConnectionTimeout | russh::Error::KeepaliveTimeout | russh::Error::InactivityTimeout => Error::Timeout { host: host.to_string() },
        russh::Error::NoCommonAlgo { .. } | russh::Error::UnknownAlgo => Error::NoCommonAlgorithm { host: host.to_string(), detail: error.to_string() },
        _ => Error::Dropped(error.to_string()),
    }
}

#[cfg(test)]
mod tests;
