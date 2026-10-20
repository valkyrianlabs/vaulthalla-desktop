# Device pairing protocol

**Draft: depends on decisions D1–D3 in architecture.md** (approved 2026-10-20; this spec is frozen when S1 lands).
Audience: the Swift implementation (`Sources/VHIdentity`, D2) and the daemon's device listener (S1). "MUST", "SHOULD"
and "MAY" are normative. All hashes are SHA-256.

## 1. Identities and encodings

- **SPKI hash** `spki_sha256(cert)` = SHA-256 of the DER `SubjectPublicKeyInfo` exactly as encoded in the certificate
  (OpenSSL: `i2d_X509_PUBKEY(X509_get_X509_PUBKEY(x))`). For P-256 that DER is the 26-byte prefix
  `3059301306072a8648ce3d020106082a8648ce3d030107034200` followed by the 65-byte uncompressed point `04 ‖ X ‖ Y`.
- **Device id** = lowercase hex of the device certificate's SPKI hash (64 chars). It is `devices.spki_sha256`.
- **Wire encodings** inside the ws envelope `{command, payload, requestId}` / `{status, data, error}`: 32-byte values
  (hashes, nonces, commitments) are lowercase hex; DER blobs (certificates, signatures) are standard base64 with
  padding; times are integer Unix seconds; codes are six ASCII digits.
- Byte strings below are concatenated with `‖`. Every field has a fixed length, so there are no length prefixes.
  Domain strings are ASCII without a terminator.

## 2. Transport and certificate profile

**Listener.** `device_server` on port 36971: loopback only by default, all interfaces after
`vh device remote enable` (D1). TLS 1.3 only (`SSL_CTX_set_min/max_proto_version(TLS1_3_VERSION)`), signature
algorithm `ecdsa_secp256r1_sha256` MUST be offered (Secure Enclave keys sign nothing else).

**Device certificate** (Desktop emits; `DeviceCertificate.make`): X.509 v3, self-signed, ECDSA P-256 key,
`ecdsa-with-SHA256`, 20-byte random serial, subject = issuer = `CN=Vaulthalla Desktop <device name>`, validity
now − 1 h … now + 2 years, extensions: basicConstraints CA:false (critical), keyUsage digitalSignature (critical),
extendedKeyUsage clientAuth. The private key lives in the Secure Enclave (`.privateKeyUsage`, no user presence, so
handshakes never prompt) and never leaves it.

**Server certificate** (daemon emits): self-signed ECDSA P-256, key sealed through `KeyProvider`, serverAuth EKU,
long validity (≥ 10 years; the pin, not the dates, carries trust).

**Daemon verify callback** (OpenSSL, `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`):
1. Return 1 for chain errors (`X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT`, expiry, EKU). Do not build chains; dates,
   EKU and the self-signature are not checked. TLS 1.3's CertificateVerify already proves key possession.
2. After the handshake take the leaf (`SSL_get0_peer_certificate`). Reject the connection unless its key is EC on
   `prime256v1`. Compute its SPKI hash.
3. Authorize **per connection, at handshake time**: a hash equal to a live `devices.spki_sha256` (or to
   `previous_spki_sha256`, §4) gives a Device session as that row's user; anything else (unknown, revoked) gets a
   *pairing-only* connection that accepts only `device.pair.*` and `meta.contract.get`. Every other command there
   fails with error code `device_unknown` (the same code for unknown and revoked: no oracle).

**Desktop verify block** (Network.framework `sec_protocol_options_set_verify_block`): TLS 1.3 only, present the
device `SecIdentity`, and accept the server iff its leaf's SPKI hash equals the node's pin (or the announced next
pin, §5). The system trust store is never consulted. While pairing (no pin yet) accept any P-256 leaf and record its
hash as `server_spki_sha256`; it must stay the same across reconnects until pairing ends, else abort.

## 3. Pairing

```
Owner (web/CLI)                 Daemon                                   Desktop
device.pairing.open  ───────▶  window (10 min, owner = user)
                                                ◀── TLS 1.3 (device cert) ──
                                                ◀── device.pair.request {name, platform, app_version, commitment}
                               nonce_server ───────────────────────────▶ {request_id, nonce_server, expires_at}
                                                ◀── device.pair.confirm {request_id, nonce_device}
                               check commitment; SAS; show request       SAS → "Approve on <node>: 482 913"
device.pairing.pending ◀────── {name, platform, ip, device_id, ...}
device.pairing.approve {request_id, code} ──▶ create devices row
                                                ◀── device.pair.status {request_id}
                               ───────────────────────────────────────▶ {state: approved, node_id, node_name}
                                                Desktop pins server SPKI, reconnects as a Device session
```

**Commit, then reveal.** The device commits to its nonce before the server reveals its own:

```
commitment = SHA-256("vh-pair-commit-v1" ‖ device_spki_sha256 ‖ nonce_device)
SAS digest = SHA-256("vh-pair-v1" ‖ server_spki_sha256 ‖ device_spki_sha256 ‖ nonce_device ‖ nonce_server)
code       = UInt64(big-endian digest[0..8]) mod 1 000 000, zero-padded to 6 digits, shown as "ddd ddd"
```

`nonce_device` and `nonce_server` are 32 bytes from a CSPRNG. Each side uses *its own view* of both SPKIs: the
daemon uses its certificate and the presented client certificate; Desktop uses the certificate the server presented
and its own. A man in the middle holds a different key on each leg, so the two codes are independent. *Why the
commitment* (a change from architecture.md §4, which sent the nonce in the request): if the device revealed
`nonce_device` first, a MITM could pick its own `nonce_server` on the device leg after seeing the honest server's
code and grind about 10⁶ candidates until the codes match, which takes milliseconds. With the commitment each party's
nonce is fixed before it sees the other's, so a MITM gets one 10⁻⁶ guess per attempt, and every attempt leaves a
visible request in the owner's list.

**Messages.**

| Command (session) | Payload → data | Daemon rules |
|---|---|---|
| `device.pair.request` (pairing-only) | `{name ≤ 64 chars, platform: "macOS", app_version, commitment}` → `{request_id, nonce_server, expires_at}` | Refused (`no_pairing_window`) unless a window is open. One live request per client SPKI (a new one replaces it). ≤ 5 live requests per window, ≤ 10 requests/min per source IP (`rate_limited`). An SPKI that is already a live device gets `conflict`. |
| `device.pair.confirm` (pairing-only) | `{request_id, nonce_device}` → `{state: "pending", expires_at}` | The connection's SPKI must equal the request's. Constant-time check of the commitment; on mismatch the request is deleted (`invalid`). Only now is the request visible to the owner, with its SAS. The daemon never sends the code to the device. |
| `device.pair.status` (pairing-only) | `{request_id}` → `{state: pending\|approved\|denied\|expired, node_id?, node_name?, device_id?}` | Same SPKI rule. The daemon MAY hold the reply up to 20 s until the state changes (long poll); after an immediate `pending` Desktop waits 2 s before asking again. |
| `device.pairing.open/close/pending/approve/deny` (owner's Human session) | `approve {request_id, code}` | `pending` lists requests with name, platform, app version, source IP, device id and `code_choices`: three six-digit codes in random order, one of them the SAS, the other two fresh random decoys (fixed per request). The real code is never returned on its own. **Number matching:** the web dialog shows the three choices and the owner clicks the one the Mac shows (one click, but it can't be done without comparing); `vh device approve <id>` prompts for the code (`--code 482913` when non-interactive). `approve` MUST carry the chosen code, compared in constant time; any wrong code denies the request. |

**Timeouts.** A window lasts 10 minutes or until closed; closing it expires its requests. A request expires 5 minutes
after `confirm`, or when its window does. Expired and denied requests are deleted; Desktop shows "Pairing timed out"
or "Pairing was declined" and starts over with fresh nonces (the device key is kept). Approved: the daemon writes the
`devices` row (`user_id` = window owner, `spki_sha256` = request SPKI, `approved_by`, name, platform, app_version).
Desktop records `server_spki_sha256` as the pin, closes the pairing connection and reconnects; the new connection is a
Device session because authorization happens at handshake time.

## 4. Device key rotation

Desktop rotates every 90 days, or on demand, on an authenticated Device session:

```
message   = "vh-device-rotate-v1" ‖ new_spki_sha256 ‖ server_spki_sha256 ‖ UInt64BE(timestamp)    (91 bytes)
signature = ECDSA-P256-SHA256(old device key, message), DER Ecdsa-Sig-Value
device.identity.rotate {certificate: base64 DER of the new certificate, timestamp, signature} → {device_id}
```

The new certificate has the §2 profile and is self-signed by the new key; the old key's endorsement is the separate
`signature` (architecture.md §4 says "signed by the old key": this is how). Binding `server_spki_sha256` stops a proof
minted for one node being replayed to another. The daemon MUST check, in order: the session's SPKI is the row's
current `spki_sha256`; the certificate parses with a P-256 key; `new_spki_sha256` is not any device's current or
previous SPKI; `|now − timestamp| ≤ 300`; the signature verifies under the connection's peer key
(`EVP_DigestVerify`, SHA-256). Then `previous_spki_sha256 = spki_sha256`, `spki_sha256 = new`, audit entry. The
previous SPKI keeps authenticating until the first handshake with the new one, which clears it. A retry from a
connection authenticated by `previous_spki_sha256` naming the same new SPKI succeeds idempotently; naming a different
one is `conflict`.

Desktop (`DeviceIdentityStore.rotate`) keeps the new identity in a pending slot, sends the proof, and on success calls
`completeRotation` and reconnects. If the reply is lost, on the next connect it tries the pending identity first;
if that is refused it falls back to the current one and re-sends `rotate` (a fresh proof over the same new key).

## 5. Server key rotation

On a Device session, `device.server.identity {}` → `{spki_sha256, next_spki_sha256?, switch_after?}`. Desktop calls
it after every connect and stores `next_spki_sha256` as a second accepted pin; after the daemon switches (no earlier
than `switch_after`, which is ≥ 30 days after the announcement), Desktop promotes the next pin and drops the old one.
A Desktop that was offline across the whole window sees an unknown SPKI, which is a pin failure: it never re-trusts on
first use, it re-pairs. If the server key is compromised, an announcement made with it proves nothing: generate a new
key without announcing it and revoke every device; each Desktop then pairs again with a fresh key and a fresh pin.

## 6. Revocation

`device.revoke {device_id}` is allowed for the device's user, super admins (D3), and the device itself ("Unpair this
Mac" in Desktop). It also happens when the user is deleted (`ON DELETE CASCADE`) and `revokeSessions` closes live
device sessions. The daemon sets `revoked_at`, closes the device's live sessions immediately, and from then on that
SPKI gets pairing-only connections. Desktop maps `device_unknown` on a previously paired node to "This Mac was unpaired
from <node>", deletes the identity (`deleteIdentity`), and offers to pair again with a fresh key. A revoked SPKI can
never be re-approved: pairing again always uses a new key.

## 7. Threat model

- **What the SAS protects:** first contact against an active network attacker (spoofed DNS or Bonjour, rogue Wi-Fi,
  TLS interception). After pairing, both pins make the channel mutually authenticated with no secrets to steal from
  traffic or logs, and nothing is bound to IP.
- **What it doesn't:** a compromised endpoint. An owner who doesn't compare can only guess among three choices,
  and a wrong guess denies the request, so a MITM wins at most one in three careless approvals and is never silent. The window owner is trusted: they could sign in as themselves anyway (D3).
- **Stolen or compromised Mac:** the Secure Enclave key can't be copied, so the thief acts as the user only while
  holding the unlocked machine. Revoke it from the web console or CLI; that is final. Software-backed keys
  (non-extractable, `ThisDeviceOnly`) resist copying by ordinary processes but not by root.
- **Replay:** pairing messages are bound to the TLS connection's SPKI and fresh nonces; rotation proofs to the node,
  a ±300 s window and a never-used new SPKI.
- **Denial of service:** requests need an open window, are rate limited and capped per window.

## 8. Test vectors

Inputs: `server_spki_sha256 = 00 01 … 1f`, `device_spki_sha256 = 20 21 … 3f`, `nonce_device = 40 41 … 5f`,
`nonce_server = 60 61 … 7f` (each 32 bytes counting up).

| Vector | Value |
|---|---|
| commitment | `eed843e2020fa269fbad8e1f326b441a7800a93bd5d985e1ee85920e7b853d32` |
| SAS digest | `3ac2baf6c86830f39f539abce1130191e6a25b766f5ac20510f27a6b7a238fc1` |
| SAS code | `680179`, displayed `680 179` |
| SAS with `nonce_server[31] = 0x04` | digest `7daab695a6774e806a8f4efc05043896c83fb49c93ea9587596bd98412068267`, code `022592` (leading zero kept) |
| SPKI hash of the P-256 generator G (private scalar 1) | `5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3` |

The generator's SPKI is the §1 prefix followed by
`046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5`.

Rotation: old key public point
`04cb6cf2c3631fb1cd0931b5f154f8f255592fbcb76c96ec1a68f80dd0f1510393b0ff71f18a3c3dd81af6ff0311d2ef98b664b8437b5ebf80aa4beb29649bb58a`
(private scalar = SHA-256("vh-rotation-test-key") mod n, test only), `new_spki_sha256 =
c5a4bd12f47b9e4a810de5de3dc0b906e20e710dfcfd344e8f934b47b6df4fe1`, `server_spki_sha256 = 00 01 … 1f`,
`timestamp = 1790000000`.

```
message   76682d6465766963652d726f746174652d7631                               "vh-device-rotate-v1"
          c5a4bd12f47b9e4a810de5de3dc0b906e20e710dfcfd344e8f934b47b6df4fe1     new_spki_sha256
          000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f     server_spki_sha256
          000000006ab13b80                                                     timestamp
signature 30440220768b64330311652f611615e15e6260f1bd4bc913557e19aaa5a45a4f16fde190
          02201daae21d09e5a1f87521471195900aa3be36b3fba00e654966453018ccf80205
```

ECDSA signatures are randomized: implementations MUST verify this signature and produce their own, never compare
signature bytes. The values were computed with Python's `hashlib` and `cryptography`; `Tests/VHIdentityTests` asserts
all of them, and the daemon's unit tests should too.
