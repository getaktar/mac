use super::*;

/// An ed25519 key from a fixed seed, in OpenSSH format, for tests that
/// don't need `ssh-keygen`. Never a real key.
fn seeded_key(seed: u8) -> PrivateKey {
    let pair = keys::ssh_key::private::Ed25519Keypair::from_seed(&[seed; 32]);
    PrivateKey::from(pair)
}

fn openssh(key: &PrivateKey) -> String {
    key.to_openssh(keys::ssh_key::LineEnding::LF).unwrap().to_string()
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

/// A key made by `ssh-keygen` (`-t` type, `-b` bits, `-N` passphrase,
/// `-m PEM` with `pem`), or None when it isn't installed.
fn keygen_with(kind: &str, bits: Option<&str>, passphrase: &str, pem: bool) -> Option<(String, String)> {
    let directory = std::env::temp_dir().join(format!("aktar-sftp-key-{}-{}", std::process::id(), new_id()));
    std::fs::create_dir_all(&directory).ok()?;
    let path = directory.join("key");
    let mut command = std::process::Command::new("ssh-keygen");
    command.args(["-q", "-t", kind, "-N", passphrase, "-C", "aktar-test", "-f"]).arg(&path);
    if let Some(bits) = bits {
        command.args(["-b", bits]);
    }
    if pem {
        command.args(["-m", "PEM"]);
    }
    let status = command.stdin(std::process::Stdio::null()).output().ok()?.status;
    let private = std::fs::read_to_string(&path).ok().filter(|_| status.success());
    let public = std::fs::read_to_string(path.with_extension("pub")).ok();
    let _ = std::fs::remove_dir_all(&directory);
    Some((private?, public?))
}

fn keygen(kind: &str, bits: Option<&str>, passphrase: &str) -> Option<(String, String)> {
    keygen_with(kind, bits, passphrase, false)
}

#[test]
fn reads_servers() {
    assert_eq!(parse_endpoint("files.example.com").unwrap(), ("files.example.com".into(), 22));
    assert_eq!(parse_endpoint(" files.example.com:2222 ").unwrap(), ("files.example.com".into(), 2222));
    assert_eq!(parse_endpoint("sftp://u123.your-storagebox.de:23/home").unwrap(), ("u123.your-storagebox.de".into(), 23));
    assert_eq!(parse_endpoint("SSH://host").unwrap(), ("host".into(), 22));
    assert_eq!(parse_endpoint("[2001:db8::1]:2200").unwrap(), ("2001:db8::1".into(), 2200));
    assert_eq!(parse_endpoint("[::1]").unwrap(), ("::1".into(), 22));
    assert_eq!(parse_endpoint("2001:db8::1").unwrap(), ("2001:db8::1".into(), 22));
    assert_eq!(parse_endpoint("127.0.0.1:2022").unwrap(), ("127.0.0.1".into(), 2022));
    for bad in ["", "  ", "host:0", "host:99999", "host:abc", "me@host", "[::1]x", "ho st"] {
        assert_eq!(parse_endpoint(bad), Err(Error::InvalidEndpoint), "{bad}");
    }
    assert_eq!(display_host("host", 22), "host");
    assert_eq!(display_host("host", 2200), "host:2200");
    assert_eq!(display_host("::1", 2200), "[::1]:2200");
}

#[test]
fn maps_keys_to_paths_under_the_folder() {
    assert_eq!(normalize_folder("/var/www/files/").unwrap(), "/var/www/files");
    assert_eq!(normalize_folder(" files ").unwrap(), "files");
    assert_eq!(normalize_folder("~/files").unwrap(), "files");
    assert_eq!(normalize_folder("~").unwrap(), "");
    assert_eq!(normalize_folder("").unwrap(), "");
    assert_eq!(normalize_folder("/").unwrap(), "/");
    assert_eq!(normalize_folder("//srv//./a/").unwrap(), "/srv/a");
    assert_eq!(normalize_folder("/srv/../etc"), Err(Error::FolderHasParent));

    assert_eq!(remote_path("/var/www/files", "2026/11/a b.png").unwrap(), "/var/www/files/2026/11/a b.png");
    assert_eq!(remote_path("files", "a.png").unwrap(), "files/a.png");
    assert_eq!(remote_path("", "a/b.png").unwrap(), "a/b.png");
    assert_eq!(remote_path("", "").unwrap(), ".");
    assert_eq!(remote_path("/", "a.png").unwrap(), "/a.png");
    assert_eq!(remote_path("/srv", "").unwrap(), "/srv");
    assert_eq!(remote_path("/srv", "/a//./b/").unwrap(), "/srv/a/b");
    // Nothing outside the folder, however the key is written.
    for bad in ["../etc/passwd", "a/../../b", "a/.."] {
        assert_eq!(remote_path("/srv", bad), Err(Error::InvalidName(bad.into())), "{bad}");
    }
    assert_eq!(remote_path("/srv", "a..b/..c").unwrap(), "/srv/a..b/..c");
    assert_eq!(folder_prefix("/a/b//"), "a/b/");
    assert_eq!(folder_prefix("/"), "");
}

#[test]
fn finds_the_folders_to_make() {
    assert_eq!(parent_folders("/srv", "/srv/a/b/c.txt"), vec!["/srv/a", "/srv/a/b"]);
    assert_eq!(parent_folders("/srv", "/srv/c.txt"), Vec::<String>::new());
    assert_eq!(parent_folders("", "a/b/c.txt"), vec!["a", "a/b"]);
    assert_eq!(parent_folders("/", "/a/c.txt"), vec!["/a"]);
    assert_eq!(parent_folders("files", "files/x/y/"), vec!["files/x"]);
}

#[test]
fn names_part_files() {
    assert_eq!(part_path("/srv/a/shot.png"), "/srv/a/.shot.png.aktar-part");
    assert_eq!(part_path("shot.png"), ".shot.png.aktar-part");
    assert!(is_part_file(".shot.png.aktar-part"));
    assert!(!is_part_file(".aktar-part"));
    assert!(!is_part_file("shot.png.aktar-part"));
    assert!(!is_part_file(".hidden"));
}

#[test]
fn tells_keys_from_passwords() {
    assert!(is_private_key("-----BEGIN OPENSSH PRIVATE KEY-----\nabc"));
    assert!(is_private_key("\n  -----BEGIN RSA PRIVATE KEY-----"));
    assert!(is_private_key("PuTTY-User-Key-File-3: ssh-ed25519"));
    assert!(!is_private_key("hunter2"));
    assert!(!is_private_key("my -----BEGIN password"));
}

#[test]
fn reads_openssh_keys_however_they_were_pasted() {
    let key = seeded_key(7);
    let text = openssh(&key);
    let decoded = decode_private_key(&text, None).unwrap();
    assert_eq!(decoded.public_key().key_data(), key.public_key().key_data());
    // Windows line endings, spaces around the lines, no final newline,
    // and a passphrase that isn't needed.
    let pasted = format!("  {}  ", text.replace('\n', "\r\n  ").trim_end());
    let decoded = decode_private_key(&pasted, Some("unused")).unwrap();
    assert_eq!(decoded.public_key().key_data(), key.public_key().key_data());
    assert_eq!(key_info(&pasted).unwrap(), KeyInfo { algorithm: "ssh-ed25519".into(), encrypted: false });
    assert!(matches!(decode_private_key("-----BEGIN OPENSSH PRIVATE KEY-----\nnot a key\n-----END OPENSSH PRIVATE KEY-----", None), Err(Error::UnreadableKey)));
    assert!(matches!(decode_private_key("hello", None), Err(Error::UnreadableKey)));
    assert!(key_info("hello").is_err());
}

#[test]
fn reads_encrypted_and_rsa_keys() {
    let Some((encrypted, _)) = keygen("ed25519", None, "correct horse") else {
        eprintln!("ssh-keygen isn't installed; skipped");
        return;
    };
    assert_eq!(decode_private_key(&encrypted, None).err(), Some(Error::KeyPassphrase));
    assert_eq!(decode_private_key(&encrypted, Some("")).err(), Some(Error::KeyPassphrase));
    assert_eq!(decode_private_key(&encrypted, Some("wrong")).err(), Some(Error::KeyPassphrase));
    assert!(decode_private_key(&encrypted, Some("correct horse")).is_ok());
    assert_eq!(key_info(&encrypted).unwrap(), KeyInfo { algorithm: "ssh-ed25519".into(), encrypted: true });

    let (rsa, _) = keygen("rsa", Some("2048"), "").unwrap();
    assert!(decode_private_key(&rsa, None).unwrap().algorithm().is_rsa());
    assert_eq!(key_info(&rsa).unwrap().algorithm, "ssh-rsa");
    let (ecdsa, _) = keygen("ecdsa", Some("256"), "").unwrap();
    assert!(matches!(decode_private_key(&ecdsa, None).unwrap().algorithm(), keys::Algorithm::Ecdsa { .. }));
    assert_eq!(key_info(&ecdsa).unwrap().algorithm, "ecdsa-sha2-nistp256");
    // Old PEM RSA keys, plain and encrypted.
    if let Some((pem, _)) = keygen_with("rsa", Some("2048"), "", true) {
        assert!(pem.starts_with("-----BEGIN RSA PRIVATE KEY-----"));
        assert!(decode_private_key(&pem, None).unwrap().algorithm().is_rsa());
        assert_eq!(key_info(&pem).unwrap(), KeyInfo { algorithm: "ssh-rsa".into(), encrypted: false });
    }
    if let Some((pem, _)) = keygen_with("rsa", Some("2048"), "secret", true) {
        assert_eq!(decode_private_key(&pem, None).err(), Some(Error::KeyPassphrase));
        assert_eq!(decode_private_key(&pem, Some("wrong")).err(), Some(Error::KeyPassphrase));
        assert!(decode_private_key(&pem, Some("secret")).unwrap().algorithm().is_rsa());
        assert_eq!(key_info(&pem).unwrap(), KeyInfo { algorithm: "ssh-rsa".into(), encrypted: true });
    }
}

#[test]
fn compares_and_prints_host_keys() {
    let a = seeded_key(1).public_key().clone();
    let b = seeded_key(2).public_key().clone();
    let text = host_key_text(&a);
    assert!(text.starts_with("ssh-ed25519 AAAA"), "{text}");
    assert_eq!(text.split(' ').count(), 2, "no comment: {text}");
    let parsed = parse_host_key(&format!("  {text} root@server \n")).unwrap();
    assert!(same_host_key(&a, &parsed));
    assert!(!same_host_key(&a, &b));
    assert!(same_host_key_text(&text, &format!("{text} comment")));
    assert!(!same_host_key_text(&text, &host_key_text(&b)));
    assert!(!same_host_key_text("junk", "junk"));
    assert_eq!(normalize_host_key(&format!(" {text} root@server ")), Some(text.clone()));
    assert!(fingerprint(&a).starts_with("SHA256:"));
    assert_eq!(fingerprint_of(&text), Some(fingerprint(&a)));
    assert_ne!(fingerprint(&a), fingerprint(&b));
    assert!(parse_host_key("").is_none());
    assert!(parse_host_key("ssh-ed25519 not-base64").is_none());
    // RSA and ECDSA host keys too.
    for (kind, bits) in [("rsa", "2048"), ("ecdsa", "256")] {
        let Some((_, public)) = keygen(kind, Some(bits), "") else { return };
        let normalized = normalize_host_key(&public).unwrap();
        assert!(same_host_key_text(&normalized, &public), "{kind}");
        assert!(!normalized.contains("aktar-test"));
    }
}

#[test]
fn matches_ssh_keygen_fingerprints() {
    let Some((_, public)) = keygen("ed25519", None, "") else { return };
    let path = std::env::temp_dir().join(format!("aktar-sftp-fp-{}.pub", new_id()));
    std::fs::write(&path, &public).unwrap();
    let output = std::process::Command::new("ssh-keygen").args(["-l", "-E", "sha256", "-f"]).arg(&path).output().unwrap();
    let _ = std::fs::remove_file(&path);
    let printed = String::from_utf8_lossy(&output.stdout);
    let expected = printed.split_whitespace().nth(1).unwrap();
    assert_eq!(fingerprint_of(&public), Some(expected.to_string()));
}

#[test]
fn sorts_errors() {
    let status = |code: StatusCode, message: &str| {
        SftpError::Status(russh_sftp::protocol::Status { id: 1, status_code: code, error_message: message.into(), language_tag: "en".into() })
    };
    assert_eq!(sftp_error(status(StatusCode::PermissionDenied, ""), None), Error::PermissionDenied);
    assert_eq!(sftp_error(status(StatusCode::NoSuchFile, ""), Some("/srv")), Error::FolderNotFound("/srv".into()));
    assert_eq!(sftp_error(status(StatusCode::NoSuchFile, ""), None), Error::FileNotFound);
    assert_eq!(sftp_error(status(StatusCode::Failure, "No space left on device"), None), Error::OutOfSpace);
    assert_eq!(sftp_error(status(StatusCode::Failure, " odd "), None), Error::ServerAnswered("odd".into()));
    assert!(matches!(sftp_error(status(StatusCode::ConnectionLost, ""), None), Error::Dropped(_)));
    assert_eq!(sftp_error(SftpError::Timeout, None), Error::ServerTimeout);
    let refused = connect_error(russh::Error::IO(std::io::Error::from(std::io::ErrorKind::ConnectionRefused)), "files.example.com:2222");
    assert_eq!(refused, Error::Refused { host: "files.example.com:2222".into() });
    // Network trouble is tried again; signing in and permissions aren't.
    assert!(refused.is_retryable());
    assert!(Error::Dropped("reset".into()).is_retryable());
    assert!(Error::ServerTimeout.is_retryable());
    for error in [Error::AuthFailed, Error::KeyPassphrase, Error::PermissionDenied, Error::HostKeyChanged { stored: None, seen: None }, Error::UnreadableHostKey, Error::Cancelled] {
        assert!(!error.is_retryable(), "{error:?}");
    }
    assert!(io_error(std::io::Error::other("Permission denied")) == Error::PermissionDenied);
}

#[test]
fn clients_refuse_what_cant_be_right() {
    let config = |endpoint: &str, folder: &str, secret: &str| ClientConfig {
        endpoint: endpoint.into(),
        folder: folder.into(),
        user: " me ".into(),
        secret: secret.into(),
        trust_id: "S".into(),
        ..Default::default()
    };
    assert!(Client::new(config("files.example.com", "/srv", "pw")).is_ok());
    assert_eq!(Client::new(config("", "/srv", "pw")).err(), Some(Error::InvalidEndpoint));
    assert_eq!(Client::new(config("host", "/srv/../etc", "pw")).err(), Some(Error::FolderHasParent));
    let client = Client::new(config("host:2200", "/srv/", "pw")).unwrap();
    assert!(!client.uses_key());
    assert_eq!(client.display_host(), "host:2200");
    assert_eq!(client.base(), "/srv");
    assert_eq!(client.user, "me");
    let with_key = ClientConfig { key_passphrase: Some(String::new()), ..config("host", "", &openssh(&seeded_key(3))) };
    let client = Client::new(with_key).unwrap();
    assert!(client.uses_key() && !client.has_passphrase());
    // Another key, password or host key is another connection.
    let a = Client::new(config("host", "/a", "pw")).unwrap();
    let b = Client::new(config("host", "/b", "pw")).unwrap();
    assert_eq!(a.pool_key(), b.pool_key());
    let other = Client::new(config("host", "/a", "other")).unwrap();
    assert_ne!(a.pool_key(), other.pool_key());
    let pinned = Client::new(ClientConfig { host_key: Some(host_key_text(seeded_key(4).public_key())), ..config("host", "/a", "pw") }).unwrap();
    assert_ne!(a.pool_key(), pinned.pool_key());
    // A saved key that can't be read is never "any key".
    let unreadable = Client::new(ClientConfig { host_key: Some("ssh-ed25519 garbage".into()), ..config("host", "/a", "pw") }).unwrap();
    assert!(unreadable.has_unreadable_host_key());
    let blank = Client::new(ClientConfig { host_key: Some("  ".into()), ..config("host", "/a", "pw") }).unwrap();
    assert!(!blank.has_unreadable_host_key());
}

#[tokio::test]
async fn cancel_tokens_stop_what_they_guard() {
    let token = Arc::new(CancelToken::new());
    let canceller = token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        canceller.cancel();
    });
    let result: Result<()> = cancellable(Some(&token), async {
        tokio::time::sleep(Duration::from_secs(30)).await;
        Ok(())
    })
    .await;
    assert_eq!(result, Err(Error::Cancelled));
    // Already cancelled: nothing runs.
    let result = cancellable(Some(&token), async { Ok(1) }).await;
    assert_eq!(result, Err(Error::Cancelled));
    assert_eq!(cancellable(None, async { Ok(2) }).await, Ok(2));
}

/// Against `rclone serve sftp` and OpenSSH's own `sshd` (run as the user
/// on a free port, keys only), ignored by default: `cargo test --
/// --ignored` starts its own servers (rclone, sshd and ssh-keygen have to
/// be installed; a test is skipped without them).
mod live {
    use super::*;
    use std::path::PathBuf;

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum Kind {
        Rclone,
        OpenSsh,
    }

    struct Server {
        kind: Kind,
        child: std::process::Child,
        port: u16,
        directory: PathBuf,
        /// The destination folder, as a client is given it.
        folder: String,
        /// The same folder on this computer.
        local: PathBuf,
        /// The server's host key, as stored.
        host_key: String,
        /// Client keys it accepts, by name: ed25519, ed25519-encrypted,
        /// rsa, rsa-encrypted, rsa-pem, rsa-pem-encrypted, ecdsa (the
        /// encrypted ones with `PASSPHRASE`).
        client_keys: HashMap<&'static str, String>,
    }

    const PASSPHRASE: &str = "key words";

    impl Drop for Server {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    fn free_port() -> u16 {
        std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
    }

    fn installed(program: &str) -> bool {
        std::path::Path::new(program).is_absolute() && std::path::Path::new(program).exists()
            || std::process::Command::new("which").arg(program).output().is_ok_and(|output| output.status.success())
    }

    fn sshd() -> Option<&'static str> {
        ["/usr/sbin/sshd", "/usr/bin/sshd"].into_iter().find(|path| std::path::Path::new(path).exists())
    }

    fn user_name() -> String {
        std::env::var("USER").ok().filter(|user| !user.is_empty()).unwrap_or_else(|| {
            String::from_utf8_lossy(&std::process::Command::new("id").arg("-un").output().unwrap().stdout).trim().to_string()
        })
    }

    async fn start(kind: Kind) -> Option<Server> {
        if keygen("ed25519", None, "").is_none() {
            eprintln!("ssh-keygen isn't installed; skipped");
            return None;
        }
        match kind {
            Kind::Rclone if !installed("rclone") => {
                eprintln!("rclone isn't installed; skipped");
                return None;
            }
            Kind::OpenSsh if sshd().is_none() => {
                eprintln!("sshd isn't installed; skipped");
                return None;
            }
            _ => {}
        }
        let directory = std::env::temp_dir().join(format!("aktar-sftp-core-live-{}", new_id()));
        std::fs::create_dir_all(directory.join("served/base")).unwrap();
        let directory = directory.canonicalize().unwrap();
        let (host_private, host_public) = keygen("ed25519", None, "").unwrap();
        let host_key_path = directory.join("host_key");
        std::fs::write(&host_key_path, host_private).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&host_key_path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let mut client_keys = HashMap::new();
        let mut authorized = String::new();
        for (name, kind, bits, passphrase, pem) in [
            ("ed25519", "ed25519", None, "", false),
            ("ed25519-encrypted", "ed25519", None, PASSPHRASE, false),
            ("rsa", "rsa", Some("3072"), "", false),
            ("rsa-encrypted", "rsa", Some("3072"), PASSPHRASE, false),
            ("rsa-pem", "rsa", Some("2048"), "", true),
            ("rsa-pem-encrypted", "rsa", Some("2048"), PASSPHRASE, true),
            ("ecdsa", "ecdsa", Some("256"), "", false),
        ] {
            let (private, public) = keygen_with(kind, bits, passphrase, pem).unwrap();
            authorized.push_str(&public);
            client_keys.insert(name, private);
        }
        let authorized_path = directory.join("authorized_keys");
        std::fs::write(&authorized_path, authorized).unwrap();
        let port = free_port();
        let (child, folder) = match kind {
            Kind::Rclone => {
                let child = std::process::Command::new("rclone")
                    .args(["serve", "sftp"])
                    .arg(directory.join("served"))
                    .args(["--addr", &format!("127.0.0.1:{port}"), "--user", "u", "--pass", "p", "--key"])
                    .arg(&host_key_path)
                    .arg("--authorized-keys")
                    .arg(&authorized_path)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .ok()?;
                (child, "/base".to_string())
            }
            Kind::OpenSsh => {
                let config = directory.join("sshd_config");
                std::fs::write(
                    &config,
                    format!(
                        "Port {port}\nListenAddress 127.0.0.1\nHostKey {}\nPidFile {}\nAuthorizedKeysFile {}\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nSubsystem sftp internal-sftp\n",
                        host_key_path.display(),
                        directory.join("sshd.pid").display(),
                        authorized_path.display()
                    ),
                )
                .unwrap();
                let child = std::process::Command::new(sshd().unwrap())
                    .args(["-D", "-e", "-f"])
                    .arg(&config)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .ok()?;
                (child, directory.join("served/base").display().to_string())
            }
        };
        let mut up = false;
        for _ in 0..100 {
            if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
                up = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(up, "{kind:?} didn't start on {port}");
        let host_key = host_key_text(&parse_host_key(&host_public).unwrap());
        Some(Server { kind, child, port, local: directory.join("served/base"), directory, folder, host_key, client_keys })
    }

    impl Server {
        /// A client signing in with the password (rclone) or the ed25519
        /// key (OpenSSH, which can't check passwords when run as a user).
        fn client(&self, host_key: Option<&str>) -> Client {
            match self.kind {
                Kind::Rclone => self.with_secret(host_key, "p", None),
                Kind::OpenSsh => self.with_key("ed25519", host_key, None),
            }
        }

        fn config(&self, host_key: Option<&str>, secret: &str, passphrase: Option<&str>) -> ClientConfig {
            ClientConfig {
                endpoint: format!("127.0.0.1:{}", self.port),
                folder: self.folder.clone(),
                user: if self.kind == Kind::Rclone { "u".into() } else { user_name() },
                secret: secret.into(),
                key_passphrase: passphrase.map(str::to_string),
                host_key: host_key.map(str::to_string),
                trust_id: format!("SFTP-CORE-TEST-{}", new_id()),
            }
        }

        fn with_secret(&self, host_key: Option<&str>, secret: &str, passphrase: Option<&str>) -> Client {
            Client::new(self.config(host_key, secret, passphrase)).unwrap()
        }

        fn with_key(&self, name: &str, host_key: Option<&str>, passphrase: Option<&str>) -> Client {
            self.with_secret(host_key, &self.client_keys[name], passphrase)
        }
    }

    #[derive(Default)]
    struct Counted {
        total: std::sync::atomic::AtomicU64,
        sent: std::sync::atomic::AtomicU64,
    }

    impl Progress for Counted {
        fn start(&self, total: u64) {
            self.total.store(total, Ordering::SeqCst);
            self.sent.store(0, Ordering::SeqCst);
        }

        fn advance(&self, bytes: u64) {
            self.sent.fetch_add(bytes, Ordering::SeqCst);
        }
    }

    fn names_in(folder: &std::path::Path) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
        let mut names: Vec<String> = entries.map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        names
    }

    async fn round_trip(kind: Kind) {
        let Some(server) = start(kind).await else { return };
        let client = server.client(Some(&server.host_key));

        let TestOutcome::Connected(session) = client.test_connection().await.unwrap() else { panic!("host key") };
        assert!(session.writable);
        assert_eq!(session.host_key, server.host_key);
        assert_eq!(Some(session.fingerprint.clone()), fingerprint_of(&server.host_key));
        assert!(server.local.join(&session.test_key).exists());
        let test_key = session.test_key.clone();
        session.finish().await;
        assert!(!server.local.join(&test_key).exists());

        let directory = server.directory.join("local");
        std::fs::create_dir_all(&directory).unwrap();
        let file = directory.join("small ü.txt");
        std::fs::write(&file, b"hello from aktar").unwrap();
        let progress = Arc::new(Counted::default());
        let key = "live/deep/er/small ü+(1).txt";
        assert_eq!(client.upload(&file, key, Some(progress.clone()), false, None).await.unwrap(), 16);
        assert_eq!(progress.total.load(Ordering::SeqCst), 16);
        assert_eq!(progress.sent.load(Ordering::SeqCst), 16);
        let on_disk = server.local.join(key);
        assert_eq!(std::fs::read(&on_disk).unwrap(), b"hello from aktar");
        assert_eq!(names_in(on_disk.parent().unwrap()), vec!["small ü+(1).txt"]);
        assert_eq!(client.upload(&file, key, None, true, None).await, Err(Error::AlreadyExists));

        let info = client.info(key).await.unwrap().unwrap();
        assert_eq!(info.size, 16);
        assert!(info.last_modified.is_some());
        assert!(client.info("live/deep/").await.unwrap().is_none(), "a folder isn't a file");
        assert!(client.info("live/nope").await.unwrap().is_none());
        assert_eq!(client.get_small(key, 100).await.unwrap().map(|(data, _)| data), Some(b"hello from aktar".to_vec()));
        assert!(client.get_small("live/missing.txt", 100).await.unwrap().is_none());
        assert_eq!(client.get_small(key, 4).await, Err(Error::TooLarge));
        let downloaded = directory.join("downloaded.txt");
        assert!(client.download(key, &downloaded, 100, None).await.unwrap());
        assert_eq!(std::fs::read(&downloaded).unwrap(), b"hello from aktar");
        assert!(!client.download("live/missing.txt", &downloaded, 100, None).await.unwrap());

        client.put_bytes(key, b"replaced").await.unwrap();
        assert_eq!(std::fs::read(&on_disk).unwrap(), b"replaced");
        client.put_bytes("live/thumbs/a.webp", &[1, 2, 3]).await.unwrap();
        client.create_folder("live/empty/nested/").await.unwrap();
        std::fs::write(server.local.join("live/.stale.png.aktar-part"), b"x").unwrap();
        let mut level = client.list("live/").await.unwrap();
        level.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(level.iter().map(|entry| (entry.name.as_str(), entry.is_folder)).collect::<Vec<_>>(), vec![("deep", true), ("empty", true), ("thumbs", true)]);
        assert!(matches!(client.list("live/nothing/").await, Err(Error::FolderNotFound(_))));

        client.rename(key, "moved/into/new folder/renamed.txt").await.unwrap();
        assert!(client.info(key).await.unwrap().is_none());
        client.copy("moved/into/new folder/renamed.txt", "live/copy.txt").await.unwrap();
        assert_eq!(client.get_small("live/copy.txt", 100).await.unwrap().unwrap().0, b"replaced");
        // Over an existing file, both replace it.
        client.put_bytes("live/other.txt", b"other").await.unwrap();
        client.copy("live/copy.txt", "live/other.txt").await.unwrap();
        assert_eq!(std::fs::read(server.local.join("live/other.txt")).unwrap(), b"replaced");
        client.put_bytes("live/third.txt", b"third").await.unwrap();
        client.rename("live/third.txt", "live/other.txt").await.unwrap();
        assert_eq!(std::fs::read(server.local.join("live/other.txt")).unwrap(), b"third");

        client.delete("live/").await.unwrap();
        assert!(client.info("live/copy.txt").await.unwrap().is_some(), "a folder with files stays");
        client.delete("live/empty/nested/").await.unwrap();
        assert!(!server.local.join("live/empty/nested").exists());
        client.delete("live/copy.txt").await.unwrap();
        client.delete("live/copy.txt").await.unwrap();
        assert!(client.info("live/copy.txt").await.unwrap().is_none());
        client.delete("/").await.unwrap();
        assert!(server.local.exists(), "never the base folder");
        assert_eq!(client.get_small("../outside.txt", 100).await, Err(Error::InvalidName("../outside.txt".into())));
        assert_eq!(client.copy("missing.txt", "x.txt").await, Err(Error::FileNotFound));
    }

    #[tokio::test]
    #[ignore]
    async fn rclone_round_trip() {
        round_trip(Kind::Rclone).await;
    }

    #[tokio::test]
    #[ignore]
    async fn openssh_round_trip() {
        round_trip(Kind::OpenSsh).await;
    }

    async fn signs_in_with_keys(kind: Kind) {
        let Some(server) = start(kind).await else { return };
        let pinned = Some(server.host_key.as_str());
        for (name, passphrase) in [
            ("ed25519", None),
            ("ed25519-encrypted", Some(PASSPHRASE)),
            ("rsa", None),
            ("rsa-encrypted", Some(PASSPHRASE)),
            ("rsa-pem", None),
            ("rsa-pem-encrypted", Some(PASSPHRASE)),
            ("ecdsa", None),
        ] {
            let client = server.with_key(name, pinned, passphrase);
            let key = format!("by-key/{name}.txt");
            client.put_bytes(&key, name.as_bytes()).await.unwrap_or_else(|error| panic!("{kind:?} {name}: {error:?}"));
            assert_eq!(std::fs::read(server.local.join(&key)).unwrap(), name.as_bytes(), "{name}");
        }
        for name in ["ed25519-encrypted", "rsa-encrypted", "rsa-pem-encrypted"] {
            assert_eq!(server.with_key(name, pinned, None).put_bytes("x.txt", b"x").await, Err(Error::KeyPassphrase), "{name}");
            assert_eq!(server.with_key(name, pinned, Some("wrong")).put_bytes("x.txt", b"x").await, Err(Error::KeyPassphrase), "{name}");
        }
        // A key the server doesn't know, and a wrong password.
        assert_eq!(server.with_secret(pinned, &openssh(&seeded_key(9)), None).put_bytes("x.txt", b"x").await, Err(Error::AuthFailed));
        assert_eq!(server.with_secret(pinned, "wrong", None).put_bytes("x.txt", b"x").await, Err(Error::AuthFailed));
        // A missing base folder.
        let missing = Client::new(ClientConfig { folder: format!("{}/no/such", server.folder), ..server.config(pinned, &server.client_keys["ed25519"], None) }).unwrap();
        assert!(matches!(missing.test_connection().await, Err(Error::FolderNotFound(_))));
        assert!(matches!(missing.put_bytes("a/b.txt", b"x").await, Err(Error::FolderNotFound(_))));
        // Nothing listening.
        let closed = Client::new(ClientConfig { endpoint: format!("127.0.0.1:{}", free_port()), ..server.config(None, "p", None) }).unwrap();
        assert!(matches!(closed.test_connection().await, Err(Error::Refused { host }) if host.starts_with("127.0.0.1:")));
    }

    #[tokio::test]
    #[ignore]
    async fn rclone_signs_in_with_keys() {
        signs_in_with_keys(Kind::Rclone).await;
    }

    #[tokio::test]
    #[ignore]
    async fn openssh_signs_in_with_keys() {
        signs_in_with_keys(Kind::OpenSsh).await;
    }

    async fn trusts_on_first_use(kind: Kind) {
        let Some(server) = start(kind).await else { return };
        let Some(other) = start(kind).await else { return };
        let learned: Arc<Mutex<Vec<String>>> = Arc::default();
        let sink = learned.clone();
        let config = server.config(None, if kind == Kind::Rclone { "p" } else { &server.client_keys["ed25519"] }, None);
        let trust_id = config.trust_id.clone();
        let client = Client::new(config.clone()).unwrap().with_host_key_listener(move |key| sink.lock().unwrap().push(key.to_string()));
        client.put_bytes("tofu.txt", b"x").await.unwrap();
        assert_eq!(*learned.lock().unwrap(), vec![server.host_key.clone()]);
        assert_eq!(learned_host_key(&trust_id, "127.0.0.1", server.port), Some(server.host_key.clone()));
        // Test Connection doesn't learn: the app saves what it shows.
        let fresh = Client::new(ClientConfig { trust_id: String::new(), ..config.clone() }).unwrap();
        let TestOutcome::Connected(session) = fresh.test_connection().await.unwrap() else { panic!() };
        assert_eq!(session.host_key, server.host_key);
        session.finish().await;

        // The same destination pointed at a server with another key.
        let secret = if kind == Kind::Rclone { "p".to_string() } else { other.client_keys["ed25519"].clone() };
        let moved = Client::new(ClientConfig { endpoint: format!("127.0.0.1:{}", other.port), folder: other.folder.clone(), host_key: Some(server.host_key.clone()), ..other.config(None, &secret, None) }).unwrap();
        match moved.put_bytes("x.txt", b"x").await {
            Err(Error::HostKeyChanged { stored, seen }) => {
                assert_eq!(stored.as_deref(), Some(server.host_key.as_str()));
                assert_eq!(seen.as_deref(), Some(other.host_key.as_str()));
            }
            other => panic!("{other:?}"),
        }
        assert!(!other.local.join("x.txt").exists());
        match moved.test_connection().await.unwrap() {
            TestOutcome::HostKeyChanged { stored, seen } => {
                assert_eq!(stored.as_deref(), Some(server.host_key.as_str()));
                assert_eq!(seen.as_deref(), Some(other.host_key.as_str()));
            }
            TestOutcome::Connected(_) => panic!("connected to a changed key"),
        }
        let saved = Client::new(ClientConfig { host_key: Some(other.host_key.clone()), ..other.config(None, &secret, None) }).unwrap();
        saved.put_bytes("x.txt", b"x").await.unwrap();
        assert!(other.local.join("x.txt").exists());
        // A stored key that can't be read is refused.
        let unreadable = Client::new(ClientConfig { host_key: Some("ssh-ed25519 garbage".into()), ..other.config(None, &secret, None) }).unwrap();
        assert_eq!(unreadable.put_bytes("y.txt", b"y").await, Err(Error::UnreadableHostKey));
        assert!(matches!(unreadable.test_connection().await.unwrap(), TestOutcome::HostKeyChanged { stored: None, seen: Some(_) }));
    }

    #[tokio::test]
    #[ignore]
    async fn rclone_trusts_on_first_use() {
        trusts_on_first_use(Kind::Rclone).await;
    }

    #[tokio::test]
    #[ignore]
    async fn openssh_trusts_on_first_use() {
        trusts_on_first_use(Kind::OpenSsh).await;
    }

    async fn big_files_reuse_and_cancel(kind: Kind) {
        let Some(server) = start(kind).await else { return };
        let client = Arc::new(server.client(Some(&server.host_key)));
        let file = server.directory.join("big.bin");
        let size: u64 = 40 * 1024 * 1024 + 17;
        {
            use std::io::Write;
            let mut writer = std::io::BufWriter::new(std::fs::File::create(&file).unwrap());
            let block: Vec<u8> = (0..1024 * 1024).map(|index| (index % 251) as u8).collect();
            let mut written = 0;
            while written < size {
                let take = (size - written).min(block.len() as u64) as usize;
                writer.write_all(&block[..take]).unwrap();
                written += take as u64;
            }
        }
        let progress = Arc::new(Counted::default());
        client.upload(&file, "big/one stream.bin", Some(progress.clone()), false, None).await.unwrap();
        assert_eq!(progress.sent.load(Ordering::SeqCst), size);
        let back = server.directory.join("back.bin");
        assert!(client.download("big/one stream.bin", &back, size, None).await.unwrap());
        assert_eq!(std::fs::read(&back).unwrap(), std::fs::read(&file).unwrap());
        assert_eq!(client.download("big/one stream.bin", &back, 1024, None).await, Err(Error::TooLarge));
        assert!(pooled_connections() >= 1);

        // Many at once share one connection.
        let mut tasks = Vec::new();
        for index in 0..12 {
            let client = client.clone();
            tasks.push(tokio::spawn(async move { client.put_bytes(&format!("many/{index}.txt"), index.to_string().as_bytes()).await }));
        }
        for task in tasks {
            task.await.unwrap().unwrap();
        }
        assert_eq!(client.list("many").await.unwrap().len(), 12);

        // A cancelled upload leaves no part file.
        let token = Arc::new(CancelToken::new());
        let started = Arc::new(Counted::default());
        let upload = {
            let client = client.clone();
            let token = token.clone();
            let file = file.clone();
            let started = started.clone();
            tokio::spawn(async move { client.upload(&file, "cancel/file.bin", Some(started), false, Some(&token)).await })
        };
        for _ in 0..500 {
            if started.sent.load(Ordering::SeqCst) > 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        token.cancel();
        let result = upload.await.unwrap();
        if result != Err(Error::Cancelled) {
            eprintln!("the upload finished before it was cancelled: {result:?}");
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
        let left = names_in(&server.local.join("cancel"));
        assert!(left.iter().all(|name| !name.ends_with(PART_SUFFIX)), "{left:?}");

        // A dropped connection is replaced on the next operation.
        close_pooled_connections().await;
        assert!(client.info("big/one stream.bin").await.unwrap().is_some());
    }

    #[tokio::test]
    #[ignore]
    async fn rclone_big_files_reuse_and_cancel() {
        big_files_reuse_and_cancel(Kind::Rclone).await;
    }

    #[tokio::test]
    #[ignore]
    async fn openssh_big_files_reuse_and_cancel() {
        big_files_reuse_and_cancel(Kind::OpenSsh).await;
    }
}
