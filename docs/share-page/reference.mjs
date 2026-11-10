// Reference implementation of docs/share-pages.md in plain Node (no
// dependencies): filling template.html, the head tags, and the encrypted
// file format. The apps port this; `node test.mjs` checks it against the
// page's own decryptor and writes vectors.json for the apps' unit tests.

import { webcrypto as crypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const TEMPLATE = readFileSync(fileURLToPath(new URL('./template.html', import.meta.url)), 'utf8');

// --- Escaping

export function escapeHTML(value) {
  return String(value).replace(/[&<>"'{}]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;', '{': '&#123;', '}': '&#125;'
  })[c]);
}

// JSON for inside <script type="application/json">: nothing in it can end
// the script element or start a comment.
export function escapeJSON(object) {
  return JSON.stringify(object)
    .replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026')
    .replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
}

// --- Head

// "2.4 MB": decimal units, one decimal below 100, none for bytes.
export function formatSize(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let n = bytes, i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  const digits = i === 0 || n >= 100 ? 0 : 1;
  return `${n.toFixed(digits)} ${units[i]}`;
}

function extensionLabel(name) {
  const dot = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).toUpperCase() : '';
}

// The text excerpt for og:description: whitespace collapsed, 200 characters
// (code points) at most, with an ellipsis when cut.
export function excerpt(text) {
  const flat = text.replace(/\s+/g, ' ').trim();
  const chars = Array.from(flat);
  return chars.length > 200 ? chars.slice(0, 199).join('') + '\u2026' : flat;
}

// The <title> and the tags in place of {{META}}, in this order.
export function headFor(page) {
  const tags = [];
  let title;
  let description;
  let image = null;
  let video = null;
  if (page.kind === 'encrypted') {
    title = 'Encrypted file';
    description = 'Open the link to decrypt it in the browser.';
  } else if (page.kind === 'request') {
    title = page.request.title || 'Send files';
    description = page.request.note ? excerpt(page.request.note) : 'Upload files straight to the requester\u2019s storage.';
  } else if (page.kind === 'gallery') {
    const [first] = page.files;
    title = `${first.name} +${page.files.length - 1}`;
    const total = page.files.reduce((n, f) => n + f.size, 0);
    description = `${page.files.length} files \u00b7 ${formatSize(total)}`;
    const shown = page.files.find((f) => f.ogImage);
    image = shown ? shown.ogImage : null;
  } else {
    const [file] = page.files;
    title = file.name;
    description = page.kind === 'text' && page.text
      ? excerpt(page.text)
      : [formatSize(file.size), extensionLabel(file.name)].filter(Boolean).join(' \u00b7 ');
    image = file.ogImage || null;
    if (/^video\/(mp4|webm)$/.test(file.type)) video = file;
  }
  tags.push(['name', 'description', description]);
  tags.push(['property', 'og:title', title]);
  tags.push(['property', 'og:description', description]);
  tags.push(['property', 'og:type', video ? 'video.other' : 'website']);
  if (image) {
    tags.push(['property', 'og:image', image]);
    tags.push(['property', 'og:image:alt', title]);
  }
  if (video) {
    tags.push(['property', 'og:video', video.url]);
    tags.push(['property', 'og:video:secure_url', video.url]);
    tags.push(['property', 'og:video:type', video.type]);
  }
  tags.push(['name', 'twitter:card', image ? 'summary_large_image' : 'summary']);
  tags.push(['name', 'twitter:title', title]);
  const meta = tags.map(([attr, key, value]) => `<meta ${attr}="${key}" content="${escapeHTML(value)}">`).join('\n');
  return { title, meta };
}

// --- The page

// page: { kind, lang, created, expires, files: [{ name, url, size, type,
// thumb, ogImage }], text, syntax, encrypted, request, brand }. ogImage is
// only for the head (see "og:image" in the spec); it isn't in the data.
export function buildPage(page) {
  const { title, meta } = headFor(page);
  const data = { v: 1, kind: page.kind, lang: page.lang || 'en', created: page.created, expires: page.expires ?? null };
  if (page.files) data.files = page.files.map((f) => ({ name: f.name, url: f.url, size: f.size, type: f.type, thumb: f.thumb ?? null }));
  if (page.kind === 'text') { data.text = page.text; data.syntax = page.syntax ?? null; }
  if (page.kind === 'encrypted') data.encrypted = page.encrypted;
  if (page.kind === 'request') data.request = page.request;
  if (page.brand === false) data.brand = false;
  // In this order, each once: what goes in can't contain a placeholder
  // ({ and } are escaped in the first three, and DATA comes last). Every
  // value is passed as a function, so `$&` or `$'` in a name is inserted as
  // it is rather than read as a replacement pattern.
  return TEMPLATE
    .replace('{{LANG}}', () => escapeHTML(data.lang))
    .replace('{{TITLE}}', () => escapeHTML(title))
    .replace('{{META}}', () => meta)
    .replace('{{DATA}}', () => escapeJSON(data));
}

// --- Encryption

export const HEADER_LENGTH = 42;
export const RECORD_SIZE = 65536;
export const PASSWORD_ITERATIONS = 600000;

function header({ kdf, iterations, salt, noncePrefix, metaLength }) {
  const h = new Uint8Array(HEADER_LENGTH);
  const view = new DataView(h.buffer);
  h.set([0x41, 0x4b, 0x45, 0x31], 0);
  h[4] = 1;
  h[5] = kdf;
  view.setUint32(6, iterations);
  h.set(salt, 10);
  h.set(noncePrefix, 26);
  view.setUint32(34, RECORD_SIZE);
  view.setUint32(38, metaLength);
  return h;
}

async function seal(key, h, index, final, plain) {
  const nonce = new Uint8Array(12);
  nonce.set(h.subarray(26, 34), 0);
  new DataView(nonce.buffer).setUint32(8, index);
  const aad = new Uint8Array(HEADER_LENGTH + 1);
  aad.set(h, 0);
  aad[HEADER_LENGTH] = final ? 1 : 0;
  return new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad, tagLength: 128 }, key, plain));
}

export async function passwordKey(password, salt, iterations = PASSWORD_ITERATIONS) {
  const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(password.normalize('NFC')), 'PBKDF2', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', salt, iterations, hash: 'SHA-256' }, base, 256));
}

// The metadata record's plaintext, exactly: {"name":..,"type":..,"size":..}
// plus "syntax" for text with a known language.
export function metaJSON({ name, type, size, syntax }) {
  const meta = { name, type, size };
  if (syntax) meta.syntax = syntax;
  return new TextEncoder().encode(JSON.stringify(meta));
}

// rawKey: 32 bytes (the link's key, or the password's derived key).
// kdf 0: key in the link (salt all zeros, iterations 0); kdf 1: password.
export async function encrypt(plain, meta, { rawKey, noncePrefix, kdf = 0, salt = new Uint8Array(16), iterations = 0 }) {
  const key = await crypto.subtle.importKey('raw', rawKey, { name: 'AES-GCM' }, false, ['encrypt']);
  const metaPlain = metaJSON(meta);
  const h = header({ kdf, iterations, salt, noncePrefix, metaLength: metaPlain.length + 16 });
  const out = [h, await seal(key, h, 0, false, metaPlain)];
  const count = Math.max(1, Math.ceil(plain.length / RECORD_SIZE));
  for (let i = 0; i < count; i++) {
    const chunk = plain.subarray(i * RECORD_SIZE, Math.min(plain.length, (i + 1) * RECORD_SIZE));
    out.push(await seal(key, h, i + 1, i === count - 1, chunk));
  }
  const total = out.reduce((n, p) => n + p.length, 0);
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const p of out) { bytes.set(p, at); at += p.length; }
  return bytes;
}

// Size of the encrypted file for a plaintext of `size` bytes.
export function encryptedSize(size, metaLength) {
  const records = Math.max(1, Math.ceil(size / RECORD_SIZE));
  return HEADER_LENGTH + metaLength + 16 + size + records * 16;
}

export function base64url(bytes) {
  return Buffer.from(bytes).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
