// SPDX-License-Identifier: MIT
// h173/client.uc - asynchronous HiLink-style client for the H173-386 (uloop + uclient)
//
//  let c = client.session({ host: '192.168.8.1', username: 'vodafone', password: '...' });
//  c.get('/api/device/signal', (err, val) => { ... });
//  c.post('/api/dialup/mobile-dataswitch', { dataswitch: 1 }, (err, val) => { ... });
//
// All requests are serialised through one queue (POST tokens are single-use).
// Login (Huawei-flavoured SCRAM) happens lazily on the first "no rights"/session
// error and is retried once per request. Wrong-password errors back off.

'use strict';

import * as uloop from 'uloop';
import * as P from 'h173.proto';
import * as X from 'h173.crypto';

// Two HTTP transports, both optional at load time so a missing module never
// stops the daemon starting:
//  - socket  (ucode-mod-socket): we speak HTTP ourselves with a Content-Length
//    body, exactly like the browser. Preferred.
//  - uclient (ucode-mod-uclient): libuclient wrapper; always sends POST bodies
//    chunked, which the H173 happens to accept. Fallback.
// At least one must be present; install.sh makes sure of that.
let socket = null, uclient = null;
try { socket = require('socket'); } catch (e) { socket = null; }
try { uclient = require('uclient'); } catch (e) { uclient = null; }

export function transports() {
	return { socket: socket != null, uclient: uclient != null };
};

const CT_FORM = 'application/x-www-form-urlencoded; charset=UTF-8';

// one HTTP exchange via uclient; done(err, { status, headers, body })
function http_uclient(method, url, opts, done) {
	opts ??= {};
	let timeout = opts.timeout ?? 10000;
	let chunks = [], hdrs = {}, status = 0, finished = false, uc = null, guard = null;

	function finish(err) {
		if (finished)
			return;
		finished = true;
		guard?.cancel();
		let res = { status, headers: hdrs, body: join('', chunks) };
		let handle = uc;
		uc = null;
		// free outside of the uclient callback stack
		uloop.timer(1, () => { handle?.disconnect(); handle?.free(); });
		done(err, res);
	}

	uc = uclient.new(url, null, {
		header_done: () => {
			hdrs = uc?.get_headers() ?? {};
			status = uc?.status()?.status ?? 0;
		},
		data_read: () => {
			let d;
			while (uc && length(d = uc.read()) > 0)
				push(chunks, d);
		},
		data_eof: () => finish(null),
		error: (cb, code) => finish('http error ' + code)
	});

	if (!uc)
		return done('invalid url ' + url, null);

	uc.set_timeout(timeout);
	guard = uloop.timer(timeout + 2000, () => finish('timeout'));

	if (!uc.connect())
		return finish('connect failed (' + url + ')');

	let req = { headers: opts.headers ?? {} };
	if (opts.body != null)
		req.post_data = opts.body;

	if (!uc.request(method, req))
		return finish('request failed');
};


function dechunk(b) {
	let out = [], pos = 0;
	while (pos < length(b)) {
		let nl = index(substr(b, pos), '\r\n');
		if (nl < 0)
			break;
		let sz = hex(split(substr(b, pos, nl), ';')[0]);
		if (type(sz) != 'int' || sz <= 0)
			break;
		push(out, substr(b, pos + nl + 2, sz));
		pos += nl + 2 + sz + 2;
	}
	return join('', out);
}

// one HTTP/1.1 exchange over a plain TCP socket (Connection: close)
function http_socket(method, url, opts, done) {
	let m = match(url, /^http:\/\/([^\/:]+)(:([0-9]+))?(\/.*)?$/);
	if (!m)
		return done('invalid url ' + url, null);

	let host = m[1], port = m[3] ?? '80', path = m[4] ?? '/';
	let timeout = opts.timeout ?? 10000;
	let sock = socket.connect(host, port, { socktype: socket.SOCK_STREAM }, opts.connect_timeout ?? 2500);
	if (!sock)
		return done('connect failed (' + host + ':' + port + '): ' + (socket.error() ?? ''), null);

	let body = opts.body;
	let req = [ `${method} ${path} HTTP/1.1`, `Host: ${host}${port != '80' ? ':' + port : ''}`, 'Connection: close' ];
	for (let k, v in (opts.headers ?? {}))
		push(req, `${k}: ${v}`);
	if (body != null)
		push(req, `Content-Length: ${length(body)}`);
	let raw = join('\r\n', req) + '\r\n\r\n' + (body ?? '');

	let sent = 0;
	while (sent < length(raw)) {
		let n = sock.send(substr(raw, sent));
		if (n == null || n <= 0) {
			sock.close();
			return done('send failed: ' + (socket.error() ?? ''), null);
		}
		sent += n;
	}

	let chunks = [], finished = false, handle = null, guard = null;

	function finish(err) {
		if (finished)
			return;
		finished = true;
		guard?.cancel();
		handle?.delete();
		sock.close();

		let data = join('', chunks);
		let sep = index(data, '\r\n\r\n');
		if (err == null && sep < 0)
			err = 'malformed HTTP response';
		if (err)
			return done(err, null);

		let head = split(substr(data, 0, sep), '\r\n');
		let st = match(head[0], /^HTTP\/[0-9.]+ ([0-9]+)/);
		let hdrs = {};
		for (let i = 1; i < length(head); i++) {
			let c = index(head[i], ':');
			if (c > 0)
				hdrs[lc(trim(substr(head[i], 0, c)))] = trim(substr(head[i], c + 1));
		}
		let b = substr(data, sep + 4);
		if (lc(hdrs['transfer-encoding'] ?? '') == 'chunked')
			b = dechunk(b);
		else if (hdrs['content-length'] != null)
			b = substr(b, 0, +hdrs['content-length']);

		done(null, { status: st ? +st[1] : 0, headers: hdrs, body: b });
	}

	// Bazı modem web sunucuları 'Connection: close' istemimize rağmen bağlantıyı
	// açık tutar (keep-alive); o zaman EOF hiç gelmez ve istek boşuna zaman aşımına
	// düşer (yanıt tam gelmiş olsa bile atılırdı). Yanıtı Content-Length / chunked
	// sonuyla erkenden tamamlayıp bağlantı kapanmasını beklemiyoruz.
	function complete() {
		let data = join('', chunks);
		let sep = index(data, '\r\n\r\n');
		if (sep < 0)
			return false;
		let hd = substr(data, 0, sep);
		let bodylen = length(data) - (sep + 4);
		let cl = match(hd, /(^|\r\n)content-length:[ \t]*([0-9]+)/i);
		if (cl)
			return bodylen >= +cl[2];
		if (match(hd, /(^|\r\n)transfer-encoding:[^\r\n]*chunked/i))
			return index(substr(data, sep + 4), '0\r\n\r\n') >= 0;
		return false;   // uzunluk bilinmiyor → EOF'a / zaman aşımına bırak
	}

	handle = uloop.handle(sock, (events) => {
		let d = sock.recv(16384);
		if (d == null)
			return finish('recv failed: ' + (socket.error() ?? ''));
		if (d == '')
			return finish(null);
		push(chunks, d);
		if (complete())
			return finish(null);
	}, uloop.ULOOP_READ);

	guard = uloop.timer(timeout, () => finish('timeout'));
}

// opts.transport: 'auto' (socket if available) | 'socket' | 'uclient'
export function http(method, url, opts, done) {
	opts ??= {};
	let t = opts.transport ?? 'auto';
	// honour an explicit choice when that module is present, else use whatever we have
	if (t == 'socket' && socket)
		return http_socket(method, url, opts, done);
	if (t == 'uclient' && uclient)
		return http_uclient(method, url, opts, done);
	if (socket)
		return http_socket(method, url, opts, done);
	if (uclient)
		return http_uclient(method, url, opts, done);
	return done('no HTTP transport: install ucode-mod-socket or ucode-mod-uclient', null);
};

export function session(cfg) {
	let host = cfg.host ?? '192.168.8.1';
	let base = 'http://' + host;
	let self = {
		cookie: null,
		tokens: [],
		logged_in: false,
		dev_session: false,
		last_login: 0,
		last_error: null,
		login_block_until: 0,
		seen: {},
		sig_ok: null,
		requests: 0,
		errors: 0,
		ecc_pub: null,      // device ECC public key (hex)
		kp: null,           // our ECDH key pair { pub, key, server }
		ecc_error: null
	};
	let queue = [], busy = false;

	/* ---- job queue: one exchange chain at a time ---- */
	function pump() {
		if (busy || !length(queue))
			return;
		busy = true;
		let job = shift(queue);
		let released = false;
		job(() => {
			if (released) return;
			released = true;
			busy = false;
			uloop.timer(1, pump);
		});
	}

	function enqueue(fn) {
		push(queue, fn);
		pump();
	}

	/* ---- low level ---- */
	function absorb(res) {
		let h = res?.headers ?? {};
		let sc = h['set-cookie'];
		if (sc) {
			let m = match(sc, /(SessionID=[^;]+)/);
			self.cookie = m ? m[1] : split(sc, ';')[0];
		}
		for (let name in [ '__requestverificationtokenone', '__requestverificationtokentwo', '__requestverificationtoken' ]) {
			if (h[name])
				for (let t in split(h[name], '#'))
					if (length(t) && !self.seen[t]) {
						if (length(self.seen) > 512)
							self.seen = {};
						// single-use; after login the same token arrives in several headers
						self.seen[t] = true;
						push(self.tokens, t);
					}
		}
		// keep the queue short; stale tokens are useless
		while (length(self.tokens) > 8)
			shift(self.tokens);
	}

	function headers(extra) {
		let h = {
			'X-Requested-With': 'XMLHttpRequest',
			'_ResponseSource': 'Broswer',
			'Accept': '*/*'
		};
		if (self.cookie)
			h['Cookie'] = self.cookie;
		for (let k, v in (extra ?? {}))
			h[k] = v;
		return h;
	}

	// normalise a response into (err, value)
	//  err: null | { code, text } | "transport message"
	function parse(err, res, cb) {
		self.requests++;
		if (err) {
			self.errors++;
			return cb(err, null);
		}
		absorb(res);
		let x = P.xml_parse(res.body);
		if (!x) {
			if (res.status >= 400) {
				self.errors++;
				return cb({ code: 'http' + res.status, text: 'HTTP ' + res.status }, null);
			}
			// some config endpoints return non-XML; hand back raw
			return cb(null, res.body);
		}
		if (x.name == 'error') {
			self.errors++;
			let code = '' + (x.value?.code ?? '?');
			let e = { code, text: P.error_text(code) };
			for (let k in [ 'count', 'remaincount', 'waittime' ])
				if (x.value?.[k] != null && x.value[k] !== '')
					e[k] = +x.value[k];
			return cb(e, null);
		}
		cb(null, x.value);
	}

	function raw(method, path, body, extra, timeout, cb) {
		http(method, base + path, { headers: headers(extra), body, timeout, transport: cfg.transport }, (e, r) => parse(e, r, cb));
	}

	function token(cb) {
		if (length(self.tokens))
			return cb(null, shift(self.tokens));
		raw('GET', '/api/webserver/token', null, {}, null, (e, v) => {
			if (e)
				return cb(e, null);
			let t = (type(v) == 'object') ? v.token : null;
			if (!t)
				return cb('no token in /api/webserver/token', null);
			cb(null, length(t) > 32 ? substr(t, 32) : t);
		});
	}

	function do_get(path, opts, cb) {
		raw('GET', path, null, opts?.headers ?? {}, opts?.timeout, cb);
	}

	function do_post(path, body, opts, cb) {
		token((e, tok) => {
			if (e)
				return cb(e, null);
			let data = (type(body) == 'string') ? body : P.request_body(body);
			let extra = { '__RequestVerificationToken': tok, 'Content-Type': CT_FORM };
			for (let k, v in (opts?.headers ?? {}))
				extra[k] = v;
			raw('POST', path, data, extra, opts?.timeout, cb);
		});
	}

	/* ---- encrypted transport (device "ECC" mode, used for SMS) ----
	 * enc-type 1: reply encrypted, 2: request body encrypted, 3: both.
	 * URL gets ?ecc-client-pubkey=<our pub>&enc-type=N, exactly like the web UI. */
	function ecc_key(cb) {
		if (self.kp && self.ecc_pub && self.kp.server == self.ecc_pub)
			return cb(null, self.kp);

		function derive() {
			let done = (e, kp) => {
				if (e || !kp) {
					self.ecc_error = e ?? 'ecdh failed';
					return cb({ code: 'ecdh', text: '' + self.ecc_error }, null);
				}
				kp.server = self.ecc_pub;
				self.kp = kp;
				self.ecc_error = null;
				cb(null, kp);
			};
			if (cfg.ecdh)
				cfg.ecdh(self.ecc_pub, done);
			else
				done(null, X.ecdh_new(self.ecc_pub));
		}

		if (self.ecc_pub)
			return derive();

		raw('GET', '/api/webserver/publickey', null, {}, null, (e, v) => {
			if (e)
				return cb(e, null);
			if (type(v) == 'object' && length(v.ecc_server_pubkey ?? '')) {
				self.ecc_pub = lc(v.ecc_server_pubkey);
				return derive();
			}
			if (type(v) == 'object' && length(v.encpubkeyn ?? ''))
				return cb({ code: 'rsa', text: 'device uses the RSA transport, which is not supported yet' }, null);
			cb({ code: 'nokey', text: 'device returned no ECC public key' }, null);
		});
	}

	function do_post_enc(path, body, enctype, opts, cb) {
		ecc_key((e, kp) => {
			if (e)
				return cb(e, null);
			token((e2, tok) => {
				if (e2)
					return cb(e2, null);
				let xmlb = (type(body) == 'string') ? body : P.request_body(body);
				let data = (enctype == 2 || enctype == 3) ? X.envelope_seal(kp.key, xmlb) : xmlb;
				let url = base + path + '?ecc-client-pubkey=' + kp.pub + '&enc-type=' + enctype;
				let hdr = headers({ '__RequestVerificationToken': tok, 'Content-Type': CT_FORM });
				http('POST', url, { headers: hdr, body: data, timeout: opts?.timeout ?? 15000, transport: cfg.transport }, (he, res) => {
					if (!he && res && (enctype == 1 || enctype == 3)) {
						let b = trim(res.body ?? '');
						if (length(b) && substr(b, 0, 1) != '<') {
							let plain = X.envelope_open(kp.key, b);
							if (plain == null) {
								self.kp = null;          // stale key: derive again after re-login
								self.ecc_pub = null;
								res.body = '<error><code>decrypt</code></error>';
							}
							else {
								let at = index(plain, '<response>');
								res.body = (at >= 0) ? substr(plain, at) : plain;
							}
						}
					}
					parse(he, res, cb);
				});
			});
		});
	}

	/* ---- login ---- */
	function login_failed(e, cb) {
		self.last_error = e;
		let code = (type(e) == 'object') ? e.code : '';
		// wrong username/password: every attempt counts towards the modem's lockout (which also
		// locks the owner out of the web page), so stop until the settings change or a manual
		// "login" action. Lockout: wait as long as the modem says (or login_backoff).
		if (code in [ '108001', '108002', '108006' ]) {
			self.login_block_until = 2147483647;
			self.fail_streak = 0;
			if (type(e) == 'object')
				e.text = (e.text ?? 'wrong username or password') + ' - automatic login stopped; correct it in Settings';
		}
		else if (code == '108007') {
			self.login_block_until = time() + max(+(e?.waittime ?? 0) * ((+(e?.waittime ?? 0) > 1000) ? 0.001 : 1), cfg.login_backoff ?? 300) + 5;
			self.fail_streak = 0;
		}
		// anything else (protokol/HTTP hatası, cihaz meşgul, oturum başka yerde açık):
		// tek-oturumlu modemde bu çoğu zaman GEÇİCİdir (web arayüzü/AI Life oturumu
		// almıştır), diğer taraf kapanınca hemen düzelir. Bu yüzden kısa, hızlı
		// toparlayan bir bekleme: 6s,12s,24s,48s,90s (eski 15s..5dk yerine).
		else {
			self.fail_streak = (self.fail_streak ?? 0) + 1;
			self.login_block_until = time() + min(90, 6 * (1 << min(self.fail_streak - 1, 4)));
		}
		cb(e, null);
	}

	// dev=true logs in through the modem's "developermode" route (loginflag=2),
	// which grants the extra endpoints (band/freq locking, /api/developer/*).
	function do_login(cb, dev) {
		if (!length(cfg.password ?? ''))
			return cb({ code: 'nopass', text: 'no modem password configured' });
		if (time() < self.login_block_until)
			return cb({ code: 'backoff', text: (self.login_block_until == 2147483647)
				? 'login stopped after a wrong username/password - fix it in Settings'
				: sprintf('login paused for %ds after a failed attempt', self.login_block_until - time()) });

		self.logged_in = false;
		self.dev_session = false;
		self.cookie = null;
		self.tokens = [];
		self.seen = {};
		let lf = dev ? '2' : null;

		// fetch "/" first so the device hands out a SessionID cookie
		http('GET', base + '/', { headers: headers({}), timeout: 8000, transport: cfg.transport }, (e0, r0) => {
			if (!e0)
				absorb(r0);

			let firstnonce = P.random_hex(32);
			let chal = { username: cfg.username ?? 'vodafone', firstnonce, mode: 1 };
			if (lf) chal.loginflag = lf;
			do_post('/api/user/challenge_login', chal, null, (e, v) => {
				if (e)
					return login_failed(e, cb);
				if (type(v) != 'object' || !v.salt || !v.servernonce)
					return login_failed({ code: 'proto', text: 'unexpected challenge_login reply' }, cb);

				let s = P.scram(cfg.password, v.salt, +(v.iterations ?? 100), firstnonce, v.servernonce);
				let req = { clientproof: s.clientproof, finalnonce: v.servernonce };
				if (lf) req.loginflag = lf;
				if (v.newType == '1' && v.newSalt)
					for (let k, val in P.scram_newtype(cfg.password, v.newSalt, +(v.newIterations ?? 100), s.clientproof))
						req[k] = val;

				do_post('/api/user/authentication_login', req, null, (e2, v2) => {
					if (e2)
						return login_failed(e2, cb);
					self.sig_ok = (type(v2) == 'object' && v2.serversignature != null)
						? (v2.serversignature == s.serversignature) : null;
					if (type(v2) == 'object' && length(v2.ecc_server_pubkey ?? ''))
						self.ecc_pub = lc(v2.ecc_server_pubkey);
					self.logged_in = true;
					self.dev_session = !!dev;
					self.last_login = time();
					self.last_error = null;
					self.fail_streak = 0;
					cb(null, { sig_ok: self.sig_ok });
				});
			});
		});
	}


	/* ---- request with one automatic re-login ---- */
	function with_login(run, cb) {
		enqueue((release) => {
			run((e, v) => {
				let code = (type(e) == 'object') ? e.code : null;
				if (code && P.RELOGIN_CODES[code]) {
					do_login((le) => {
						if (le) {
							release();
							return cb(le, null);
						}
						run((e2, v2) => { release(); cb(e2, v2); });
					});
					return;
				}
				release();
				cb(e, v);
			});
		});
	}

	// Run a sequence of requests inside a temporary developer-mode session.
	// run(api, done): api.get(path, cb) / api.post(path, body, cb); call done(err, val)
	// when finished. The normal session is dropped afterwards so the poller
	// re-logs in normally on its next cycle. Serialised through the queue.
	function dev_op(run, cb) {
		enqueue((release) => {
			let finish = (e, v) => {
				// drop whatever session we hold; next poll re-logs in as normal user
				self.logged_in = false; self.dev_session = false;
				self.cookie = null; self.tokens = []; self.seen = {};
				release();
				cb(e, v);
			};
			do_login((le) => {
				if (le)
					return finish(le, null);
				let api = {
					get: (path, k) => do_get(path, null, k),
					post: (path, body, k) => do_post(path, body, null, k)
				};
				run(api, finish);
			}, true);   // dev = true
		});
	}

	return {
		state: () => ({
			host,
			dev_session: self.dev_session,
			transport: ((cfg.transport ?? 'auto') == 'socket' && socket) ? 'socket'
				: ((cfg.transport ?? 'auto') == 'uclient' && uclient) ? 'uclient'
				: socket ? 'socket' : uclient ? 'uclient' : 'none',
			logged_in: self.logged_in,
			last_login: self.last_login,
			last_error: self.last_error,
			login_blocked_for: (self.login_block_until == 2147483647) ? -1 : max(0, self.login_block_until - time()),
			server_signature_ok: self.sig_ok,
			requests: self.requests,
			errors: self.errors,
			queued: length(queue),
			ecc: { server_key: self.ecc_pub != null, ready: self.kp != null, error: self.ecc_error }
		}),
		get: (path, cb, opts) => with_login((k) => do_get(path, opts, k), cb),
		post: (path, body, cb, opts) => with_login((k) => do_post(path, body, opts, k), cb),
		post_enc: (path, body, enctype, cb, opts) => with_login((k) => do_post_enc(path, body, enctype, opts, k), cb),
		login: (cb) => enqueue((release) => {
			self.login_block_until = 0;
			do_login((e, v) => { release(); cb(e, v); });
		}),
		dev_op,
		reset: () => { self.logged_in = false; self.cookie = null; self.tokens = []; self.login_block_until = 0; self.kp = null; self.ecc_pub = null; }
	};
};
