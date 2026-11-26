// SPDX-License-Identifier: MIT
// h173/proto.uc - pure helpers for the Brovi/Zowee H173-386 HiLink-style API
//   hex/bin, HMAC-SHA256, PBKDF2-SHA256, Huawei-flavoured SCRAM,
//   minimal XML parse/build, LTE band masks, error codes.
// No I/O except random_hex() (reads /dev/urandom).

'use strict';

import * as digest from 'digest';
import { open } from 'fs';

const HEX = '0123456789abcdef';

export function bin2hex(b) {
	let out = [];
	for (let i = 0; i < length(b); i++) {
		let c = ord(b, i);
		push(out, substr(HEX, c >> 4, 1), substr(HEX, c & 15, 1));
	}
	return join('', out);
};

// lookup table: "00".."ff" -> single byte string
const HEXMAP = {};
for (let i = 0; i < 256; i++)
	HEXMAP[substr(HEX, i >> 4, 1) + substr(HEX, i & 15, 1)] = chr(i);

export function hex2bin(h) {
	h = lc(h ?? '');
	let out = [];
	for (let i = 0; i + 1 < length(h); i += 2)
		push(out, HEXMAP[substr(h, i, 2)] ?? '\x00');
	return join('', out);
};

function bytes_of(s) {
	let a = [];
	for (let i = 0; i < length(s); i++)
		push(a, ord(s, i));
	return a;
}

function str_of(a) {
	let parts = [];
	for (let i = 0; i < length(a); i += 256)
		push(parts, chr(...slice(a, i, i + 256)));
	return join('', parts);
}

export function xor_bin(a, b) {
	let n = length(a), out = [];
	for (let i = 0; i < n; i++)
		push(out, ord(a, i) ^ ord(b, i));
	return str_of(out);
};

export function sha256_bin(b) {
	return hex2bin(digest.sha256(b));
};

export function sha256_hex(s) {
	return digest.sha256(s);
};

// precomputed inner/outer pads for a key
function hmac_pads(key) {
	if (length(key) > 64)
		key = sha256_bin(key);

	let k = bytes_of(key);
	while (length(k) < 64)
		push(k, 0);

	let ipad = [], opad = [];
	for (let i = 0; i < 64; i++) {
		push(ipad, k[i] ^ 0x36);
		push(opad, k[i] ^ 0x5c);
	}
	return [ str_of(ipad), str_of(opad) ];
}

function hmac_with(pads, msg) {
	return sha256_bin(pads[1] + sha256_bin(pads[0] + msg));
}

// HMAC-SHA256(key, msg) -> binary string
export function hmac_sha256(key, msg) {
	return hmac_with(hmac_pads(key), msg);
};

// PBKDF2-HMAC-SHA256 -> binary string
export function pbkdf2_sha256(pwd, salt, iterations, dklen) {
	dklen ??= 32;
	let pads = hmac_pads(pwd);
	let blocks = [], have = 0;
	for (let blk = 1; have < dklen; blk++) {
		let u = hmac_with(pads, salt + chr((blk >> 24) & 255, (blk >> 16) & 255, (blk >> 8) & 255, blk & 255));
		let t = bytes_of(u);
		for (let i = 1; i < iterations; i++) {
			u = hmac_with(pads, u);
			for (let j = 0; j < 32; j++)
				t[j] ^= ord(u, j);
		}
		push(blocks, str_of(t));
		have += 32;
	}
	return substr(join('', blocks), 0, dklen);
};

/*
 * Huawei/Brovi SCRAM, taken from the device's own main.js:
 *   salted      = PBKDF2-SHA256(password, salt, iterations, 32)
 *   clientKey   = HMAC(key="Client Key", msg=salted)      <-- note: key/msg swapped vs RFC 5802
 *   storedKey   = SHA256(clientKey)
 *   authMsg     = firstnonce + "," + servernonce + "," + servernonce
 *   clientSig   = HMAC(key=authMsg, msg=storedKey)
 *   clientproof = clientKey XOR clientSig                   (hex)
 *   serverKey   = HMAC(key="Server Key", msg=salted)
 *   serversig   = HMAC(key=authMsg, msg=serverKey)          (hex, returned by device)
 */
export function scram(password, salt_hex, iterations, firstnonce, servernonce) {
	let salted = pbkdf2_sha256(password, hex2bin(salt_hex), +iterations, 32);
	let client_key = hmac_sha256('Client Key', salted);
	let stored_key = sha256_bin(client_key);
	let auth_msg = firstnonce + ',' + servernonce + ',' + servernonce;
	let client_sig = hmac_sha256(auth_msg, stored_key);
	let server_key = hmac_sha256('Server Key', salted);

	return {
		auth_msg,
		salted_hex: bin2hex(salted),
		clientproof: bin2hex(xor_bin(client_key, client_sig)),
		serversignature: bin2hex(hmac_sha256(auth_msg, server_key)),
		server_key: server_key
	};
};

// Extra fields the web UI sends when the device answers newType == "1"
// (password hash migration). Mirrors main.js exactly.
export function scram_newtype(password, new_salt_hex, new_iterations, clientproof) {
	let salted = pbkdf2_sha256(password, hex2bin(new_salt_hex), +new_iterations, 32);
	let stored = sha256_hex(hmac_sha256('Client Key', salted));
	let server = bin2hex(hmac_sha256('Server Key', salted));
	return {
		hashOldNewPwd: sha256_hex(stored + server + clientproof),
		newStoredKey: stored,
		newServerKey: server
	};
};

export function random_hex(nbytes) {
	let f = open('/dev/urandom', 'r');
	let b = f ? f.read(nbytes) : null;
	f?.close();
	if (length(b) != nbytes) {
		// should never happen on OpenWrt; weak fallback
		let a = [];
		for (let i = 0; i < nbytes; i++)
			push(a, (time() * 7919 + i * 104729 + int(clock()[1] ?? 0)) & 255);
		b = str_of(a);
	}
	return bin2hex(b);
};

/* ---------------- XML ---------------- */

function xml_unescape(s) {
	s = replace(s, /&#x([0-9a-fA-F]+);/g, (m, h) => chr(hex(h)));
	s = replace(s, /&#([0-9]+);/g, (m, d) => chr(+d));
	s = replace(s, /&lt;/g, '<');
	s = replace(s, /&gt;/g, '>');
	s = replace(s, /&quot;/g, '"');
	s = replace(s, /&apos;/g, "'");
	return replace(s, /&amp;/g, '&');
}

export function xml_escape(s) {
	s = '' + s;
	s = replace(s, /&/g, '&amp;');
	s = replace(s, /</g, '&lt;');
	return replace(s, />/g, '&gt;');
};

// Parses the simple, attribute-light XML the device returns.
// Returns { name: <root tag>, value: <object|string> } or null.
//  - element with only text  -> string
//  - element with children   -> object; repeated child names -> array
//  - empty element           -> ""
export function xml_parse(s) {
	if (type(s) != 'string')
		return null;

	s = replace(s, /<\?[^>]*\?>/g, '');
	s = replace(s, /<!--[\s\S]*?-->/g, '');
	s = replace(s, /<!\[CDATA\[([\s\S]*?)\]\]>/g, (m, c) => xml_escape(c));

	let pos = 0, n = length(s);

	function skip_ws() {
		while (pos < n && index(' \t\r\n', substr(s, pos, 1)) >= 0)
			pos++;
	}

	function parse_elem() {
		skip_ws();
		if (substr(s, pos, 1) != '<')
			return null;

		let close = index(substr(s, pos), '>');
		if (close < 0)
			return null;

		let tag = substr(s, pos + 1, close - 1);
		pos += close + 1;

		let selfclose = (substr(tag, -1) == '/');
		if (selfclose)
			tag = substr(tag, 0, length(tag) - 1);

		let name = split(trim(tag), /[ \t\r\n]/)[0];
		if (selfclose)
			return { name, value: '' };

		let children = null, multi = {}, text = [];

		while (pos < n) {
			let lt = index(substr(s, pos), '<');
			if (lt < 0) { pos = n; break; }
			if (lt > 0) {
				push(text, substr(s, pos, lt));
				pos += lt;
			}
			if (substr(s, pos, 2) == '</') {
				let gt = index(substr(s, pos), '>');
				pos += (gt < 0) ? (n - pos) : gt + 1;
				break;
			}
			let child = parse_elem();
			if (!child) { pos = n; break; }
			children ??= {};
			if (exists(children, child.name)) {
				if (!multi[child.name]) {
					children[child.name] = [ children[child.name] ];
					multi[child.name] = true;
				}
				push(children[child.name], child.value);
			}
			else {
				children[child.name] = child.value;
			}
		}

		if (children)
			return { name, value: children };

		return { name, value: xml_unescape(trim(join('', text))) };
	}

	return parse_elem();
};

// Mirrors the web UI's jsonToXml(name, value)
export function xml_build(name, v) {
	let t = type(v);
	if (v == null)
		return '';
	if (t == 'string' || t == 'int' || t == 'double' || t == 'bool')
		return `<${name}>${xml_escape(t == 'bool' ? (v ? 1 : 0) : v)}</${name}>`;
	if (t == 'array')
		return join('', map(v, (e) => xml_build(name, e)));
	if (t == 'object') {
		let inner = join('', map(keys(v), (k) => xml_build(k, v[k])));
		return `<${name}>${inner}</${name}>`;
	}
	return '';
};

export function request_body(obj) {
	return '<?xml version="1.0" encoding="UTF-8"?>' + xml_build('request', obj ?? {});
};

/* ---------------- LTE band masks ---------------- */

export const LTE_ALL = '7FFFFFFFFFFFFFFF';

export function lte_mask_to_bands(h) {
	if (!h || !match(h, /^[0-9A-Fa-f]{1,16}$/))
		return [];
	let v = hex(h), out = [];
	for (let bit = 0; bit < 63; bit++)
		if ((v >> bit) & 1)
			push(out, bit + 1);
	return out;
};

export function lte_bands_to_mask(bands) {
	let v = 0;
	for (let b in bands) {
		b = +b;
		if (b >= 1 && b <= 63)
			v |= (1 << (b - 1));
	}
	return v ? uc(sprintf('%X', v)) : LTE_ALL;
};

/* ---------------- error codes ---------------- */

export const ERRORS = {
	'100002': 'not supported',
	'100003': 'no rights (login required)',
	'100004': 'system busy',
	'100005': 'format error',
	'100006': 'parameter error',
	'108001': 'wrong username',
	'108002': 'wrong password',
	'108003': 'already logged in',
	'108006': 'wrong password',
	'108007': 'too many failed logins, wait',
	'113018': 'system busy',
	'125001': 'token error',
	'125002': 'session error',
	'125003': 'session/token error',
	'113004': 'SMS: busy / sending',
	'113017': 'SMS: storage full',
	'113053': 'SMS: send failed',
	'decrypt': 'could not decrypt the encrypted reply'
};

// codes after which a fresh login + single retry makes sense
export const RELOGIN_CODES = { '100003': 1, '125001': 1, '125002': 1, '125003': 1, 'decrypt': 1 };

export function error_text(code) {
	return ERRORS['' + code] ?? ('error ' + code);
};
