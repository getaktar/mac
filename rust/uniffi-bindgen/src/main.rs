//! `cargo run -p uniffi-bindgen -- generate --library <lib> --language swift
//! --out-dir <dir>`, as scripts/build-sftp-core.sh runs it.
fn main() {
    uniffi::uniffi_bindgen_main()
}
