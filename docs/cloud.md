# Vaulthalla Cloud in Desktop

Optional, and hidden until vaulthalla.cloud opens: `defaults write sh.vaulthalla.app cloud.enabled -bool YES` shows
the **Vaulthalla Cloud** section in the sidebar (a Mac already linked shows it too). Nothing else in Desktop needs it.
The design is [`cloud-storage.md`](cloud-storage.md); the protocols are valkyrianlabs/vaulthalla-cloud
`docs/design/installation-linking.md`, `installation-requests.md`, `key-manager.md`, `billing.md` and
`recovery-restore.md`.

Code: `Sources/VHCloud` (the client, models, transport, the link and account-key stores, holder keys, the account
key's flows, node mapping, portal links and wording, Desktop-only vault access), `Sources/VHKeykit` (vl-keykit's C API; every key format),
`Sources/VHNodes/DeviceApproval.swift` (the approval key answering a server's `keys` step-up),
`App/Vaulthalla/Features/Cloud` (the section). Release builds talk to `https://api.vaulthalla.cloud` and open
`https://app.vaulthalla.cloud` only; debug builds read `cloud.endpoint` and `cloud.portal` from the defaults.

## The section

- **Account**: link this Mac (a code and its key fingerprint, approved in the browser under Approvals), the plan in
  plain words with one billing action (a hand-off opened in the browser, then polled), restores waiting for this Mac.
- **Servers**: every server of the account and every paired node, mapped by the node's own `cloud.link.status`
  (the cloud's `node_id` is only a hint). On a node waiting for the account key that this Mac holds: "Use This
  Account's Recovery Key", `cloud.key.confirm` answered with this Mac's approval key (Touch ID, no digits compared);
  "Set Up Approvals" registers that key once, approved in the node's web console.
- **Vaults**: every vault by its uid, where it is, and whether the account key covers it; names open with the key.
- **Recovery Key**: create the account's key (shown once, two groups typed back, then approved in the browser), get it
  from another device (a transfer whose code both screens show) or by typing the recovery code, the fingerprint
  computed here, the offline copy (print, or record one), rotation, devices asking for the key.

- **Storage**: per paired server with `cloud.storage.managed_remotes`: usage against the plan's quota (the account's
  daily figure) and what the server holds, the default for new vaults, the one-time offer for vaults that existed
  before, each vault's switch with its state and reason in words (`ManagedStorageWording`), an ended plan's notice
  with "Make Them Local Now", and "Leave Managed Storage", which opens the portal address the server returns. Every
  change is a `cloud.storage.*` command to that server; turning a vault off asks first. Above them, **Vaults kept by
  a Mac** (Desktop-only vaults, from the cloud's `GET /v1/storage`): who holds each vault (this Mac, another Mac by
  name, a server, or nobody yet), its storage's state, and the holding Mac's key with its expiry and renewal in words
  (`DeviceAccessWording`, why a key went from the cloud's `revoked_reason`), and what this Mac lost from the cloud's
  `released` (stopped holding it, taken off by the account holder, given to another Mac by name, moved to a server). The only action is **Stop Holding** on
  this Mac's own vault (it narrows access; nothing local is deleted). The pane says that this version doesn't sync
  these vaults and asks for no storage key.

## Desktop-only vaults (wave 4, client side)

A vault with no server, kept in managed storage by one Mac. The cloud's contract is vaulthalla-cloud
`docs/design/account-model.md` ("As built" 16 to 21) and `managed-storage.md` ("As built" 25 and 26); the client
follows the daemon's code (`src/accounts/Deployments.cpp`, `src/storage/`). Built in `Sources/VHCloud`, short of the
sync engine:

- **Routes** (`DeviceAccessClient.swift`): `GET /v1/storage` (`CloudStorage`, with `desktop`, the caller's own
  `credential` and `moved_to`), `GET /v1/vaults/{uid}` (`CloudVault.desktop`), registering a vault with no deployment
  (`POST /v1/vaults`, idempotent for the Mac that holds it), the writer's storage switch
  (`PUT /v1/storage/vaults/{uid}`), the credential request and its acknowledgement, and the release
  (`DELETE /v1/vaults/{uid}/replica`). The error envelope's `reason` is kept (`CloudError.declined`) and mapped to
  `DeviceAccessError`, one case per reason the daemon gives (managed-storage.md "As built" 27's table: `held_by_server`
  and `held_by_desktop` with the holder's name from the envelope's `details`, `unplaced`, `no_such_vault`,
  `no_such_key`, `key_<state>`, `bucket_not_ready`, `bucket_off`, `bucket_deleting`, `ejecting`, `ejected`,
  `account_key_unconfirmed`, `payment_required` with its `details.cause`, `step_up_required`, `switch_only`,
  `installation_only`/`portal_only`, the 400 `invalid_*`, `provider_unavailable`, `provider_key_id_invalid`), 429 (with
  `Retry-After`) and 401, each with plain words. A 404 without a reason is a route the daemon doesn't serve.
- **The exchange** (`DeviceAccess`): a fresh one-time X25519 key per request (vl-keykit's `vl_keykit_credential_key`
  through `VHKeykit.CredentialKey`), the `sealed_secret` opened bound to this Mac's installation id, the vault uid and
  the `key_id`, then acknowledged; a box that doesn't open, a Mac key without `expires_at`/`renew_after`, or a key id
  outside the URL-unreserved set (which the daemon also enforces) is never used or acknowledged.
- **Renewal**: at `renew_after` (12 hours before the 24-hour `expires_at`, the cloud's defaults); the cloud's view is
  read every 30 minutes; `state` `expired` or `superseded` (a restricted plan, over quota) drops the key and renews at
  once; failures back off from 30 seconds, doubling to 30 minutes (longer when a 429 says so), never past the key's
  expiry, where the key is forgotten even offline. `storage_access` `none` (suspended, ended) pauses with no key; the
  waiting reasons (bucket, offline copy, ejection) are checked every 15 minutes. A key gone while this Mac still holds
  the vault follows its `revoked_reason`: `account_holder` (and `other`, or a reason this version doesn't know) stops
  the loop, kept stopped across launches by a tombstone, until the person asks for a new key; the plan's reasons
  (`suspended`, `ended`, `no_plan`, `restricted`, `over_quota`) renew by themselves once `storage_access` allows a key
  again, as do the key's own lifecycle (`replaced`, `not_acknowledged`, `not_delivered`, `access_changed`) and an old
  hold's reasons after the vault is placed here again; `installation_revoked` stops as unlinked, `ejection` waits.
  Losing the vault follows `released`: taken off by the account holder (`hold_removed`) or given to another Mac
  (`hold_reassigned`) stops until the account holder places it here again, which the next view shows and which
  restarts it; `released` (this Mac) and `moved` (`moved_to`, a server) stop the same way; an unlinked Mac stays
  stopped. Every stop keeps local files.
- **The secret** lives in memory (`SecretBytes`) and in the keychain group shared with the File Provider extension (`BucketKeyStore`:
  `storage-key.<uid>` says what the key is, `storage-key.<uid>.<key id>` holds the secret's bytes, written only by the
  credential owner), never in UserDefaults, a file, a log or an error; it is deleted when the key is replaced,
  superseded, expires or is revoked, and on unlink. `DeviceAccess.withCredentials` lends it to a signer for one call.
- **The sync engine** (2026-11-15, [`desktop-vaults.md`](desktop-vaults.md)): behind `cloud.desktopVaults.enabled`
  (off by default), the app starts one `DeviceAccess` per vault this Mac holds through its `DesktopVaultSession`, signs
  S3 requests with `withCredentials` (SigV4 in Swift), reports a 401/403 through `providerRefusedKey()`, and offers
  "New Vault in Managed Storage". With the switch off, nothing changed: the app reads the cloud's view only.

## Keys

- The link's Ed25519 identity key and the account key live in the app-only keychain group
  `<TEAM>.sh.vaulthalla.app.account` (not the File Provider extension's or `vaulthalla-mcp.app`'s), this device only,
  written only by the credential owner. Unsigned builds use the file keychain.
- The account key is kept only as KAK1 sealed to a Secure Enclave P-256 holder key (software P-256 where there is no
  enclave); a signed build asks for Touch ID or the password at each use. It is unwrapped inside vl-keykit for one
  operation at a time.
- A transfer's temporary key is the new holder key itself, so the delivered KAK1 is kept as it is.
- A Desktop-only vault's bucket key (short-lived) and its vault keys live in the group the app shares with the File
  Provider extension, `<TEAM>.sh.vaulthalla.app.vault`, which holds nothing else ([`desktop-vaults.md`](desktop-vaults.md), "Keys").
