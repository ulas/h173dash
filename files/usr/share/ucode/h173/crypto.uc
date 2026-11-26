// SPDX-License-Identifier: MIT
// h173/crypto.uc - pure-ucode crypto needed for the device's encrypted endpoints (SMS etc.)
//
//  * curve25519 key agreement, bit-compatible with elliptic.js "curve25519" as used by the
//    web UI: keys/shared secret are BIG-endian x coordinates and the scalar is NOT clamped.
//    Field arithmetic follows TweetNaCl (16 x 16-bit limbs in 64-bit integers).
//  * AES-256 (encryption direction) and AES-GCM encrypt/decrypt.
//  * The device's envelope: hex( len32le | iv(12) | tag(16) | ciphertext ), AAD = 16 zero bytes.
//
// Everything works on "binary strings" (one char per byte).

'use strict';

import * as P from 'h173.proto';
import { open } from 'fs';

/* ------------------------------------------------------------------ */
/* curve25519 field arithmetic (TweetNaCl port)                         */
/* ------------------------------------------------------------------ */

function gf(init) {
	let o = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];
	if (init)
		for (let i = 0; i < length(init); i++)
			o[i] = init[i];
	return o;
}

function car25519(o) {
	let c = 1;
	for (let i = 0; i < 16; i++) {
		let v = o[i] + c + 65535;
		c = v >> 16;                 // arithmetic shift == floor(v / 65536)
		o[i] = v - c * 65536;
	}
	o[0] += c - 1 + 37 * (c - 1);
}

// conditional swap. (TweetNaCl uses a ~(b-1) mask; ucode's "~" yields an unsigned
// 64-bit value, which breaks that trick for negative limbs. Constant time is not a
// concern for this use, so swap plainly.)
function sel25519(p, q, b) {
	if (!b)
		return;
	for (let i = 0; i < 16; i++) {
		let t = p[i];
		p[i] = q[i];
		q[i] = t;
	}
}

function fA(o, a, b) { for (let i = 0; i < 16; i++) o[i] = a[i] + b[i]; }
function fZ(o, a, b) { for (let i = 0; i < 16; i++) o[i] = a[i] - b[i]; }

// field multiplication, fully unrolled (hot path: ~2800 calls per scalar multiplication)
function fM(o, a, b) {
	let a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3], a4 = a[4], a5 = a[5], a6 = a[6], a7 = a[7], a8 = a[8], a9 = a[9], a10 = a[10], a11 = a[11], a12 = a[12], a13 = a[13], a14 = a[14], a15 = a[15];
	let b0 = b[0], b1 = b[1], b2 = b[2], b3 = b[3], b4 = b[4], b5 = b[5], b6 = b[6], b7 = b[7], b8 = b[8], b9 = b[9], b10 = b[10], b11 = b[11], b12 = b[12], b13 = b[13], b14 = b[14], b15 = b[15];
	let t0 = a0 * b0;
	let t1 = a0 * b1 + a1 * b0;
	let t2 = a0 * b2 + a1 * b1 + a2 * b0;
	let t3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;
	let t4 = a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0;
	let t5 = a0 * b5 + a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1 + a5 * b0;
	let t6 = a0 * b6 + a1 * b5 + a2 * b4 + a3 * b3 + a4 * b2 + a5 * b1 + a6 * b0;
	let t7 = a0 * b7 + a1 * b6 + a2 * b5 + a3 * b4 + a4 * b3 + a5 * b2 + a6 * b1 + a7 * b0;
	let t8 = a0 * b8 + a1 * b7 + a2 * b6 + a3 * b5 + a4 * b4 + a5 * b3 + a6 * b2 + a7 * b1 + a8 * b0;
	let t9 = a0 * b9 + a1 * b8 + a2 * b7 + a3 * b6 + a4 * b5 + a5 * b4 + a6 * b3 + a7 * b2 + a8 * b1 + a9 * b0;
	let t10 = a0 * b10 + a1 * b9 + a2 * b8 + a3 * b7 + a4 * b6 + a5 * b5 + a6 * b4 + a7 * b3 + a8 * b2 + a9 * b1 + a10 * b0;
	let t11 = a0 * b11 + a1 * b10 + a2 * b9 + a3 * b8 + a4 * b7 + a5 * b6 + a6 * b5 + a7 * b4 + a8 * b3 + a9 * b2 + a10 * b1 + a11 * b0;
	let t12 = a0 * b12 + a1 * b11 + a2 * b10 + a3 * b9 + a4 * b8 + a5 * b7 + a6 * b6 + a7 * b5 + a8 * b4 + a9 * b3 + a10 * b2 + a11 * b1 + a12 * b0;
	let t13 = a0 * b13 + a1 * b12 + a2 * b11 + a3 * b10 + a4 * b9 + a5 * b8 + a6 * b7 + a7 * b6 + a8 * b5 + a9 * b4 + a10 * b3 + a11 * b2 + a12 * b1 + a13 * b0;
	let t14 = a0 * b14 + a1 * b13 + a2 * b12 + a3 * b11 + a4 * b10 + a5 * b9 + a6 * b8 + a7 * b7 + a8 * b6 + a9 * b5 + a10 * b4 + a11 * b3 + a12 * b2 + a13 * b1 + a14 * b0;
	let t15 = a0 * b15 + a1 * b14 + a2 * b13 + a3 * b12 + a4 * b11 + a5 * b10 + a6 * b9 + a7 * b8 + a8 * b7 + a9 * b6 + a10 * b5 + a11 * b4 + a12 * b3 + a13 * b2 + a14 * b1 + a15 * b0;
	let t16 = a1 * b15 + a2 * b14 + a3 * b13 + a4 * b12 + a5 * b11 + a6 * b10 + a7 * b9 + a8 * b8 + a9 * b7 + a10 * b6 + a11 * b5 + a12 * b4 + a13 * b3 + a14 * b2 + a15 * b1;
	let t17 = a2 * b15 + a3 * b14 + a4 * b13 + a5 * b12 + a6 * b11 + a7 * b10 + a8 * b9 + a9 * b8 + a10 * b7 + a11 * b6 + a12 * b5 + a13 * b4 + a14 * b3 + a15 * b2;
	let t18 = a3 * b15 + a4 * b14 + a5 * b13 + a6 * b12 + a7 * b11 + a8 * b10 + a9 * b9 + a10 * b8 + a11 * b7 + a12 * b6 + a13 * b5 + a14 * b4 + a15 * b3;
	let t19 = a4 * b15 + a5 * b14 + a6 * b13 + a7 * b12 + a8 * b11 + a9 * b10 + a10 * b9 + a11 * b8 + a12 * b7 + a13 * b6 + a14 * b5 + a15 * b4;
	let t20 = a5 * b15 + a6 * b14 + a7 * b13 + a8 * b12 + a9 * b11 + a10 * b10 + a11 * b9 + a12 * b8 + a13 * b7 + a14 * b6 + a15 * b5;
	let t21 = a6 * b15 + a7 * b14 + a8 * b13 + a9 * b12 + a10 * b11 + a11 * b10 + a12 * b9 + a13 * b8 + a14 * b7 + a15 * b6;
	let t22 = a7 * b15 + a8 * b14 + a9 * b13 + a10 * b12 + a11 * b11 + a12 * b10 + a13 * b9 + a14 * b8 + a15 * b7;
	let t23 = a8 * b15 + a9 * b14 + a10 * b13 + a11 * b12 + a12 * b11 + a13 * b10 + a14 * b9 + a15 * b8;
	let t24 = a9 * b15 + a10 * b14 + a11 * b13 + a12 * b12 + a13 * b11 + a14 * b10 + a15 * b9;
	let t25 = a10 * b15 + a11 * b14 + a12 * b13 + a13 * b12 + a14 * b11 + a15 * b10;
	let t26 = a11 * b15 + a12 * b14 + a13 * b13 + a14 * b12 + a15 * b11;
	let t27 = a12 * b15 + a13 * b14 + a14 * b13 + a15 * b12;
	let t28 = a13 * b15 + a14 * b14 + a15 * b13;
	let t29 = a14 * b15 + a15 * b14;
	let t30 = a15 * b15;
	t0 += 38 * t16;
	t1 += 38 * t17;
	t2 += 38 * t18;
	t3 += 38 * t19;
	t4 += 38 * t20;
	t5 += 38 * t21;
	t6 += 38 * t22;
	t7 += 38 * t23;
	t8 += 38 * t24;
	t9 += 38 * t25;
	t10 += 38 * t26;
	t11 += 38 * t27;
	t12 += 38 * t28;
	t13 += 38 * t29;
	t14 += 38 * t30;
	{
		let c = 1, v;
		v = t0 + c + 65535; c = v >> 16; t0 = v - c * 65536;
		v = t1 + c + 65535; c = v >> 16; t1 = v - c * 65536;
		v = t2 + c + 65535; c = v >> 16; t2 = v - c * 65536;
		v = t3 + c + 65535; c = v >> 16; t3 = v - c * 65536;
		v = t4 + c + 65535; c = v >> 16; t4 = v - c * 65536;
		v = t5 + c + 65535; c = v >> 16; t5 = v - c * 65536;
		v = t6 + c + 65535; c = v >> 16; t6 = v - c * 65536;
		v = t7 + c + 65535; c = v >> 16; t7 = v - c * 65536;
		v = t8 + c + 65535; c = v >> 16; t8 = v - c * 65536;
		v = t9 + c + 65535; c = v >> 16; t9 = v - c * 65536;
		v = t10 + c + 65535; c = v >> 16; t10 = v - c * 65536;
		v = t11 + c + 65535; c = v >> 16; t11 = v - c * 65536;
		v = t12 + c + 65535; c = v >> 16; t12 = v - c * 65536;
		v = t13 + c + 65535; c = v >> 16; t13 = v - c * 65536;
		v = t14 + c + 65535; c = v >> 16; t14 = v - c * 65536;
		v = t15 + c + 65535; c = v >> 16; t15 = v - c * 65536;
		t0 += c - 1 + 37 * (c - 1);
	}
	{
		let c = 1, v;
		v = t0 + c + 65535; c = v >> 16; t0 = v - c * 65536;
		v = t1 + c + 65535; c = v >> 16; t1 = v - c * 65536;
		v = t2 + c + 65535; c = v >> 16; t2 = v - c * 65536;
		v = t3 + c + 65535; c = v >> 16; t3 = v - c * 65536;
		v = t4 + c + 65535; c = v >> 16; t4 = v - c * 65536;
		v = t5 + c + 65535; c = v >> 16; t5 = v - c * 65536;
		v = t6 + c + 65535; c = v >> 16; t6 = v - c * 65536;
		v = t7 + c + 65535; c = v >> 16; t7 = v - c * 65536;
		v = t8 + c + 65535; c = v >> 16; t8 = v - c * 65536;
		v = t9 + c + 65535; c = v >> 16; t9 = v - c * 65536;
		v = t10 + c + 65535; c = v >> 16; t10 = v - c * 65536;
		v = t11 + c + 65535; c = v >> 16; t11 = v - c * 65536;
		v = t12 + c + 65535; c = v >> 16; t12 = v - c * 65536;
		v = t13 + c + 65535; c = v >> 16; t13 = v - c * 65536;
		v = t14 + c + 65535; c = v >> 16; t14 = v - c * 65536;
		v = t15 + c + 65535; c = v >> 16; t15 = v - c * 65536;
		t0 += c - 1 + 37 * (c - 1);
	}
	o[0] = t0;
	o[1] = t1;
	o[2] = t2;
	o[3] = t3;
	o[4] = t4;
	o[5] = t5;
	o[6] = t6;
	o[7] = t7;
	o[8] = t8;
	o[9] = t9;
	o[10] = t10;
	o[11] = t11;
	o[12] = t12;
	o[13] = t13;
	o[14] = t14;
	o[15] = t15;
}

function fS(o, a) { fM(o, a, a); }

function inv25519(o, inp) {
	let c = gf(inp);
	for (let a = 253; a >= 0; a--) {
		fS(c, c);
		if (a != 2 && a != 4)
			fM(c, c, inp);
	}
	for (let a = 0; a < 16; a++)
		o[a] = c[a];
}

// little-endian 32 bytes -> field element
function unpack25519(n) {
	let o = gf();
	for (let i = 0; i < 16; i++)
		o[i] = n[2 * i] + (n[2 * i + 1] << 8);
	o[15] &= 0x7fff;
	return o;
}

// field element -> little-endian 32 bytes (fully reduced)
function pack25519(n) {
	let t = gf(n), m = gf(), o = [];
	car25519(t); car25519(t); car25519(t);
	for (let j = 0; j < 2; j++) {
		m[0] = t[0] - 0xffed;
		for (let i = 1; i < 15; i++) {
			m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
			m[i - 1] &= 0xffff;
		}
		m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
		let b = (m[15] >> 16) & 1;
		m[14] &= 0xffff;
		sel25519(t, m, 1 - b);
	}
	for (let i = 0; i < 16; i++) {
		push(o, t[i] & 0xff, (t[i] >> 8) & 0xff);
	}
	return o;
}

const F121665 = gf([ 0xdb41, 1 ]);

// q = scalar * point; scalar and point are little-endian byte arrays (no clamping!)
function scalarmult(z, p) {
	let x = unpack25519(p);
	let a = gf(), b = gf(x), c = gf(), d = gf(), e = gf(), f = gf();
	a[0] = 1;
	d[0] = 1;
	for (let i = 254; i >= 0; i--) {
		let r = (z[i >> 3] >> (i & 7)) & 1;
		sel25519(a, b, r); sel25519(c, d, r);
		fA(e, a, c); fZ(a, a, c); fA(c, b, d); fZ(b, b, d);
		fS(d, e); fS(f, a); fM(a, c, a); fM(c, b, e);
		fA(e, a, c); fZ(a, a, c); fS(b, a); fZ(c, d, f);
		fM(a, c, F121665); fA(a, a, d); fM(c, c, a); fM(a, d, f);
		fM(d, b, x); fS(b, e);
		sel25519(a, b, r); sel25519(c, d, r);
	}
	inv25519(c, c);
	fM(a, a, c);
	return pack25519(a);
}

function be_hex_to_le_bytes(h) {
	let bin = P.hex2bin(h), out = [];
	while (length(bin) < 32)
		bin = '\x00' + bin;
	for (let i = 31; i >= 0; i--)
		push(out, ord(bin, i));
	return out;
}

function le_bytes_to_be_hex(a) {
	let s = [];
	for (let i = length(a) - 1; i >= 0; i--)
		push(s, sprintf('%02x', a[i]));
	return join('', s);
}

function rand_bytes(n) {
	let f = open('/dev/urandom', 'r');
	let b = f?.read(n);
	f?.close();
	return b;
}

// elliptic-compatible helpers ------------------------------------------------

// public key (hex, 64 chars, big-endian) for a private scalar (hex, big-endian)
export function x25519_public(priv_hex) {
	return le_bytes_to_be_hex(scalarmult(be_hex_to_le_bytes(priv_hex), be_hex_to_le_bytes('09')));
};

// shared secret as elliptic's derive(...).toString('hex') would print it
// (big-endian, leading zero nibbles stripped)
export function x25519_shared(priv_hex, peer_pub_hex) {
	let h = le_bytes_to_be_hex(scalarmult(be_hex_to_le_bytes(priv_hex), be_hex_to_le_bytes(peer_pub_hex)));
	return replace(h, /^0+/, '');
};

// New client key pair for the device's ECDH. The web UI uses elliptic's random
// scalar in [1, n). We draw 252 random bits and retry until the shared secret has
// exactly 64 hex digits, because forge would otherwise turn a shorter hex string
// into a key of the wrong length.
export function ecdh_new(server_pub_hex) {
	for (let tries = 0; tries < 64; tries++) {
		let r = rand_bytes(32);
		if (length(r) != 32)
			return null;
		let priv = P.bin2hex(chr(ord(r, 0) & 0x0f) + substr(r, 1));
		if (match(priv, /^0+$/))
			continue;
		let shared = x25519_shared(priv, server_pub_hex);
		if (length(shared) == 64)
			return { priv, pub: x25519_public(priv), key: P.hex2bin(shared) };
	}
	return null;
};

/* ------------------------------------------------------------------ */
/* AES-256 (encrypt direction only - all GCM needs)                    */
/* ------------------------------------------------------------------ */

const SBOX = [
	0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
	0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
	0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
	0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
	0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
	0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
	0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
	0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
	0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
	0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
	0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
	0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
	0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
	0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
	0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
	0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
];

function xtime(b) {
	return ((b << 1) ^ ((b & 0x80) ? 0x1b : 0)) & 0xff;
}

// 32-byte key (array) -> 240-byte expanded key (array), AES-256
function aes256_expand(key) {
	let w = [];
	for (let i = 0; i < 32; i++)
		push(w, key[i]);
	let rcon = 1;
	for (let i = 8; i < 60; i++) {
		let t0 = w[(i - 1) * 4], t1 = w[(i - 1) * 4 + 1], t2 = w[(i - 1) * 4 + 2], t3 = w[(i - 1) * 4 + 3];
		if (i % 8 == 0) {
			let tmp = t0;
			t0 = SBOX[t1] ^ rcon; t1 = SBOX[t2]; t2 = SBOX[t3]; t3 = SBOX[tmp];
			rcon = xtime(rcon);
		}
		else if (i % 8 == 4) {
			t0 = SBOX[t0]; t1 = SBOX[t1]; t2 = SBOX[t2]; t3 = SBOX[t3];
		}
		push(w, w[(i - 8) * 4] ^ t0, w[(i - 8) * 4 + 1] ^ t1, w[(i - 8) * 4 + 2] ^ t2, w[(i - 8) * 4 + 3] ^ t3);
	}
	return w;
}

// encrypt one 16-byte block (array) with expanded key
function aes_block(xk, inb) {
	let s = [];
	for (let i = 0; i < 16; i++)
		s[i] = inb[i] ^ xk[i];

	for (let round = 1; round <= 14; round++) {
		// SubBytes + ShiftRows
		let t = [
			SBOX[s[0]],  SBOX[s[5]],  SBOX[s[10]], SBOX[s[15]],
			SBOX[s[4]],  SBOX[s[9]],  SBOX[s[14]], SBOX[s[3]],
			SBOX[s[8]],  SBOX[s[13]], SBOX[s[2]],  SBOX[s[7]],
			SBOX[s[12]], SBOX[s[1]],  SBOX[s[6]],  SBOX[s[11]]
		];
		if (round < 14) {
			// MixColumns
			for (let c = 0; c < 16; c += 4) {
				let a0 = t[c], a1 = t[c + 1], a2 = t[c + 2], a3 = t[c + 3];
				let x = a0 ^ a1 ^ a2 ^ a3;
				t[c]     = a0 ^ x ^ xtime(a0 ^ a1);
				t[c + 1] = a1 ^ x ^ xtime(a1 ^ a2);
				t[c + 2] = a2 ^ x ^ xtime(a2 ^ a3);
				t[c + 3] = a3 ^ x ^ xtime(a3 ^ a0);
			}
		}
		let k = round * 16;
		for (let i = 0; i < 16; i++)
			s[i] = t[i] ^ xk[k + i];
	}
	return s;
}

/* ------------------------------------------------------------------ */
/* GCM                                                                 */
/* ------------------------------------------------------------------ */

function bytes(s) {
	let a = [];
	for (let i = 0; i < length(s); i++)
		push(a, ord(s, i));
	return a;
}

function str(a) {
	let parts = [];
	for (let i = 0; i < length(a); i += 256)
		push(parts, chr(...slice(a, i, i + 256)));
	return join('', parts);
}

// GF(2^128) multiply (GCM bit order), byte arrays of 16
function gmul(X, Y) {
	let Z = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];
	let V = slice(Y);
	for (let i = 0; i < 128; i++) {
		if ((X[i >> 3] >> (7 - (i & 7))) & 1)
			for (let j = 0; j < 16; j++)
				Z[j] ^= V[j];
		let lsb = V[15] & 1;
		for (let j = 15; j > 0; j--)
			V[j] = ((V[j] >> 1) | ((V[j - 1] & 1) << 7)) & 0xff;
		V[0] = V[0] >> 1;
		if (lsb)
			V[0] ^= 0xe1;
	}
	return Z;
}

function ghash(H, aad, ct) {
	let Y = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];
	function absorb(data) {
		for (let off = 0; off < length(data); off += 16) {
			for (let j = 0; j < 16; j++)
				Y[j] ^= (off + j < length(data)) ? data[off + j] : 0;
			Y = gmul(Y, H);
		}
	}
	absorb(aad);
	absorb(ct);
	let la = length(aad) * 8, lc = length(ct) * 8, L = [];
	for (let sh = 56; sh >= 0; sh -= 8) push(L, (la >> sh) & 0xff);
	for (let sh = 56; sh >= 0; sh -= 8) push(L, (lc >> sh) & 0xff);
	for (let j = 0; j < 16; j++)
		Y[j] ^= L[j];
	return gmul(Y, H);
}

function gctr(xk, J0, data) {
	let out = [], ctr = slice(J0);
	for (let off = 0; off < length(data); off += 16) {
		// inc32
		for (let j = 15; j >= 12; j--) {
			ctr[j] = (ctr[j] + 1) & 0xff;
			if (ctr[j] != 0)
				break;
		}
		let ks = aes_block(xk, ctr);
		for (let j = 0; j < 16 && off + j < length(data); j++)
			push(out, data[off + j] ^ ks[j]);
	}
	return out;
}

const ZERO16 = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];

// key: 32-byte binary string, iv: 12-byte binary string, aad/plain: binary strings
// returns { ct, tag } as binary strings
export function gcm_encrypt(key, iv, plain, aad) {
	let xk = aes256_expand(bytes(key));
	let H = aes_block(xk, ZERO16);
	let J0 = bytes(iv);
	push(J0, 0, 0, 0, 1);
	let C = gctr(xk, J0, bytes(plain));
	let S = ghash(H, bytes(aad ?? ''), C);
	let EJ0 = aes_block(xk, J0);
	let T = [];
	for (let j = 0; j < 16; j++)
		push(T, S[j] ^ EJ0[j]);
	return { ct: str(C), tag: str(T) };
};

// returns plaintext binary string, or null when the tag does not match
export function gcm_decrypt(key, iv, ct, tag, aad) {
	let xk = aes256_expand(bytes(key));
	let H = aes_block(xk, ZERO16);
	let J0 = bytes(iv);
	push(J0, 0, 0, 0, 1);
	let C = bytes(ct);
	let S = ghash(H, bytes(aad ?? ''), C);
	let EJ0 = aes_block(xk, J0);
	let diff = 0, tb = bytes(tag);
	for (let j = 0; j < 16; j++)
		diff |= (S[j] ^ EJ0[j]) ^ tb[j];
	if (diff || length(tb) != 16)
		return null;
	return str(gctr(xk, J0, C));
};

/* ------------------------------------------------------------------ */
/* the device's envelope (main.js doAESEncrypt / decrypt)               */
/* ------------------------------------------------------------------ */

const AAD16 = '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00';

// plaintext (UTF-8 string) -> hex envelope
export function envelope_seal(key, plaintext, iv) {
	iv ??= rand_bytes(12);
	let r = gcm_encrypt(key, iv, plaintext, AAD16);
	let n = length(plaintext);   // UTF-8 byte length, little-endian 32-bit
	return sprintf('%02x%02x%02x%02x', n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255) +
		P.bin2hex(iv) + P.bin2hex(r.tag) + P.bin2hex(r.ct);
};

// hex envelope -> plaintext, or null
export function envelope_open(key, hex) {
	hex = trim(hex ?? '');
	if (length(hex) < 64 || !match(hex, /^[0-9a-fA-F]+$/))
		return null;
	let iv = P.hex2bin(substr(hex, 8, 24));
	let tag = P.hex2bin(substr(hex, 32, 32));
	let ct = P.hex2bin(substr(hex, 64));
	return gcm_decrypt(key, iv, ct, tag, AAD16);
};
