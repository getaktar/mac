// node docs/share-page/test.mjs [--samples <dir>]
//
// Checks reference.mjs against the page's own decryptor (the AKTAR-CRYPTO
// block of template.html), checks that the page's script parses, and writes
// vectors.json, which the apps' unit tests compare their encryption with.
// --samples writes example pages (one per kind) for looking at in a browser.

import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TEMPLATE, base64url, buildPage, encrypt, encryptedSize, escapeHTML, excerpt, formatSize, metaJSON, passwordKey } from './reference.mjs';

const here = fileURLToPath(new URL('.', import.meta.url));
const hex = (b) => Buffer.from(b).toString('hex');
const fromHex = (s) => new Uint8Array(Buffer.from(s, 'hex'));
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
// Plaintext of `size` bytes: byte i is i % 251.
const pattern = (size) => { const b = new Uint8Array(size); for (let i = 0; i < size; i++) b[i] = i % 251; return b; };

// --- The page's decryptor, run as it is.
const block = TEMPLATE.slice(TEMPLATE.indexOf('/* AKTAR-CRYPTO-BEGIN */'), TEMPLATE.indexOf('/* AKTAR-CRYPTO-END */'));
const page = new Function('crypto', 'atob', `${block}; return { aktarDecrypt, aktarDeriveKey, aktarImportKey, aktarKeyFromFragment, aktarParseHeader };`)(webcrypto, globalThis.atob);

// The whole page script must at least parse.
const script = TEMPLATE.slice(TEMPLATE.lastIndexOf('<script>') + 8, TEMPLATE.lastIndexOf('</script>'));
new Function(script);

function reader(bytes, chunk = 7777) {
  let at = 0;
  return () => Promise.resolve(at >= bytes.length ? null : bytes.subarray(at, (at += chunk)));
}
async function open(bytes, keyFor) {
  const { meta, parts } = await page.aktarDecrypt(reader(bytes), keyFor);
  const out = Buffer.concat(parts.map((p) => Buffer.from(p)));
  return { meta, out };
}

const rawKey = fromHex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
const noncePrefix = fromHex('a0a1a2a3a4a5a6a7');
const salt = fromHex('5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a');
const password = 'correct horse battery staple';
const vectors = { note: 'See docs/share-pages.md, "Encrypted links". plaintext[i] = i % 251.', rawKey: hex(rawKey), noncePrefix: hex(noncePrefix), link: [], password: null };

for (const size of [0, 5, 65535, 65536, 65537, 200000]) {
  const meta = { name: `file-${size}.bin`, type: 'application/octet-stream', size };
  const plain = pattern(size);
  const sealed = await encrypt(plain, meta, { rawKey, noncePrefix });
  assert.equal(sealed.length, encryptedSize(size, metaJSON(meta).length));
  const key = page.aktarKeyFromFragment('#k=' + base64url(rawKey));
  const { meta: got, out } = await open(sealed, () => page.aktarImportKey(key));
  assert.deepEqual(got, meta);
  assert.equal(sha256(out), sha256(plain));
  // Cut at a record boundary or inside one: never accepted.
  for (const cut of [sealed.length - 16, sealed.length - 1, 42 + metaJSON(meta).length + 16]) {
    if (cut <= 42 || cut >= sealed.length) continue;
    await assert.rejects(open(sealed.subarray(0, cut), () => page.aktarImportKey(key)));
  }
  // One flipped bit anywhere after the header: rejected.
  const flipped = new Uint8Array(sealed); flipped[sealed.length - 3] ^= 1;
  await assert.rejects(open(flipped, () => page.aktarImportKey(key)));
  vectors.link.push({ size, meta: new TextDecoder().decode(metaJSON(meta)), encryptedLength: sealed.length, sha256: sha256(sealed), hex: sealed.length <= 400 ? hex(sealed) : undefined });
}

// Wrong key: the metadata record fails, reported as wrongKey.
{
  const sealed = await encrypt(pattern(10), { name: 'a', type: 'text/plain', size: 10 }, { rawKey, noncePrefix });
  const other = new Uint8Array(32).fill(7);
  await assert.rejects(open(sealed, () => page.aktarImportKey(other)), (e) => e.aktar === 'wrongKey');
}

// Password: PBKDF2-HMAC-SHA256, 600 000 iterations, NFC.
{
  const derived = await passwordKey(password, salt);
  const meta = { name: 'notes.md', type: 'text/markdown', size: 1000, syntax: 'markdown' };
  const plain = pattern(1000);
  const sealed = await encrypt(plain, meta, { rawKey: derived, noncePrefix, kdf: 1, salt, iterations: 600000 });
  const { meta: got, out } = await open(sealed, (h) => page.aktarDeriveKey(password, h));
  assert.deepEqual(got, meta);
  assert.equal(sha256(out), sha256(plain));
  await assert.rejects(open(sealed, (h) => page.aktarDeriveKey('wrong', h)), (e) => e.aktar === 'wrongKey');
  // "é" typed as e + combining accent derives the same key as U+00E9.
  assert.equal(hex(await passwordKey('caf\u00e9', salt, 100000)), hex(await passwordKey('cafe\u0301', salt, 100000)));
  vectors.password = { password, salt: hex(salt), iterations: 600000, derivedKey: hex(derived), size: 1000, meta: new TextDecoder().decode(metaJSON(meta)), encryptedLength: sealed.length, sha256: sha256(sealed) };
}

// --- Filling the template.
assert.equal(escapeHTML(`<a href="x">{{DATA}}</a> & 'q'`), '&lt;a href=&quot;x&quot;&gt;&#123;&#123;DATA&#125;&#125;&lt;/a&gt; &amp; &#39;q&#39;');
assert.equal(formatSize(0), '0 B');
assert.equal(formatSize(999), '999 B');
assert.equal(formatSize(1000), '1.0 KB');
assert.equal(formatSize(2_400_000), '2.4 MB');
assert.equal(formatSize(512_000), '512 KB');
assert.equal(excerpt('  a\n\n b  '), 'a b');
assert.equal(Array.from(excerpt('x'.repeat(300))).length, 200);
{
  const html = buildPage({
    kind: 'file', lang: 'tr', created: '2026-11-09T10:00:00Z', expires: null,
    files: [{ name: '</script><script>alert(1)</script>{{META}}.png', url: 'https://cdn.example.com/a.png', size: 2400000, type: 'image/png', ogImage: 'https://cdn.example.com/a.png' }]
  });
  const outsideData = html.replace(/<script id="aktar-data"[^>]*>[\s\S]*?<\/script>/, '');
  assert.ok(!outsideData.includes('{{'), 'no placeholder left outside the data');
  assert.equal(html.split('</script>').length - 1, 2, 'only the two script elements end');
  assert.ok(html.includes('<meta property="og:image" content="https://cdn.example.com/a.png">'));
  assert.ok(html.includes('<meta name="twitter:card" content="summary_large_image">'));
  assert.ok(html.includes('content="2.4 MB · PNG"'));
}

writeFileSync(join(here, 'vectors.json'), JSON.stringify(vectors, null, 2) + '\n');
console.log('ok: reference and page decryptor agree; vectors.json written');

// --- Example pages.
const at = process.argv.indexOf('--samples');
if (at > 0) {
  const dir = process.argv[at + 1];
  mkdirSync(dir, { recursive: true });
  const base = 'http://localhost:8765';
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAIAAAAuKetIAAAAQklEQVR42u3PMQ0AAAgDoL9/aSFGXAvIgEIyj5SlpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKTk4QLdAQAB/9S9BAAAAABJRU5ErkJggg==', 'base64');
  writeFileSync(join(dir, 'shot.png'), png);
  writeFileSync(join(dir, 'notes.txt'), 'hello\n');
  const code = 'import Foundation\n\n// Greets someone.\nfunc greet(_ name: String) -> String {\n    let count = 42\n    return "Hello, \\(name)! \\(count)"\n}\n';
  writeFileSync(join(dir, 'greet.swift'), code);
  const created = new Date().toISOString();
  const later = new Date(Date.now() + 86400000).toISOString();
  writeFileSync(join(dir, 'file.html'), buildPage({ kind: 'file', lang: 'en', created, expires: later, files: [{ name: 'shot.png', url: `${base}/shot.png`, size: png.length, type: 'image/png', ogImage: `${base}/shot.png` }] }));
  writeFileSync(join(dir, 'text.html'), buildPage({ kind: 'text', lang: 'en', created, files: [{ name: 'greet.swift', url: `${base}/greet.swift`, size: code.length, type: 'text/x-swift' }], text: code, syntax: 'swift' }));
  writeFileSync(join(dir, 'gallery.html'), buildPage({ kind: 'gallery', lang: 'en', created, files: [
    { name: 'shot.png', url: `${base}/shot.png`, size: png.length, type: 'image/png', ogImage: `${base}/shot.png` },
    { name: 'shot.png', url: `${base}/shot.png`, size: png.length, type: 'image/png' },
    { name: 'notes.txt', url: `${base}/notes.txt`, size: 6, type: 'text/plain' }
  ] }));
  const secret = new TextEncoder().encode(code);
  const sealed = await encrypt(secret, { name: 'greet.swift', type: 'text/x-swift', size: secret.length, syntax: 'swift' }, { rawKey, noncePrefix });
  writeFileSync(join(dir, 'secret.bin'), sealed);
  writeFileSync(join(dir, 'encrypted.html'), buildPage({ kind: 'encrypted', lang: 'en', created, encrypted: { url: `${base}/secret.bin`, size: sealed.length, password: false } }));
  const derived = await passwordKey('pw', salt, 100000);
  const sealedPw = await encrypt(png, { name: 'shot.png', type: 'image/png', size: png.length }, { rawKey: derived, noncePrefix, kdf: 1, salt, iterations: 100000 });
  writeFileSync(join(dir, 'secret-pw.bin'), sealedPw);
  writeFileSync(join(dir, 'encrypted-pw.html'), buildPage({ kind: 'encrypted', lang: 'en', created, encrypted: { url: `${base}/secret-pw.bin`, size: sealedPw.length, password: true } }));
  writeFileSync(join(dir, 'request.html'), buildPage({ kind: 'request', lang: 'en', created, expires: later, request: { title: 'Logs for the crash', note: 'Please send the app logs\nand a screenshot.', maxBytes: 2000000000, conditional: true, slots: [1, 2, 3].map((n) => ({ file: `${base}/upload/${n}`, meta: `${base}/upload/${n}.json` })) } }));
  console.log(`samples in ${dir}; serve it on :8765, open encrypted.html#k=${base64url(rawKey)} (password page: "pw")`);
}
