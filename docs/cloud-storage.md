# Vaulthalla Cloud managed storage in Desktop

Desktop's part of Vaulthalla Cloud managed storage in wave 1: the account and its recovery key on the Mac, mapping
nodes to the cloud's deployments, a top-level "Vaulthalla Cloud" section, the key manager as the default backup, and
the engineering under it. It says what the later Mac App Store app and wave 4 need the structure to allow, without
designing either. The cloud's routes and ceremonies are in vaulthalla-cloud `docs/design/`; the server's commands
are in `managed-remotes.md` and `attach-remote.md`, designed in parallel and named here generically. **Nothing is
built.**

## Decided and proposed

Decided (Cooper, 2026-11-12, plan revision 4 section 3): the product is ecosystem-centric and the customer's server is
the hub; Desktop stays a client of the account's servers over the pinned mutual-TLS connection it uses today, with no
Desktop-side encryption of server vaults; vaulthalla.cloud is the preferred key manager, with one recovery key per
account that only the customer's devices can unlock, and a linked Desktop may fetch all of the account's wrapped vault
keys; 1Password is the fallback for installs without an account, or a second copy; one account spans several
deployments, cleanly separated; billing happens in the browser; the Mac App Store app comes later as a simplified
second app sharing most of the code; Desktop-only is wave 4. Everything else is a proposal; choices are collected
under Open questions.

## Today

Read in this worktree (origin/main, Desktop 0.5.0). The plan's audit (section 2.3) holds, with these precisions:

- **One cloud link per macOS account, not per Mac.** `KeychainCloudLinkStore` keeps one generic-password item
  (service `sh.vaulthalla.app.cloud`, account `link`, `AfterFirstUnlockThisDeviceOnly`) in the user's data protection
  keychain: a JSON `CloudLink` whose `identity_key` is the raw Ed25519 private key in base64, beside the endpoint,
  state, installation id and the cloud's internal numeric `account_id`, which `account-model.md` never shows outside.
- **It sits in the shared keychain group and bypasses the lease.** No access group is passed, so the item lands in
  `$(AppIdentifierPrefix)sh.vaulthalla.app`, which the File Provider extension and `vaulthalla-mcp.app` are entitled
  to as well (`App/*.Team.entitlements`). `CloudSettingsModel` writes and deletes it directly, while `NodeStore` and
  `DeviceKeys` refuse every mutation without the `CredentialLease` (`docs/architecture.md` §3).
- **Link, unlink and restore delivery from a kit file only** (`CloudClient.deliver(_:kit:)`), in Settings ▸ Cloud,
  shown only with `defaults write sh.vaulthalla.app cloud.enabled -bool YES`; the endpoint is a free text field.
- **Untyped and shared transport.** Responses are `[String: Any]`; `URLSessionCloudTransport` uses `URLSession.shared`
  with its cookie store, cache and credential storage. No cloud contract is vendored, and the cloud repository has
  none to vendor yet; the VHC1 and restore-code vectors are copied into `Tests/VHCloudTests` by hand.
- **Nothing maps a node to the account.** `Node` has `serverNodeID` (`device.pair.status` `node_id`), no kind.
- **No vault uid.** The vendored contract is server 1.20.0 and has no `vault_uid`. Read from vaulthalla-server
  origin/main (1.22.2) for this design: the uid is in `VaultKeyStatus`, `VaultKeyExport` and the recovery models but
  not in `Vault`, which `storage.vault.list` and `storage.vault.accessible.list` return, so a contract bump alone
  gives it only to a user who may read key status.
- **Store blockers are partly inside shared packages.** Sparkle is linked by the app target (`Updates.swift`);
  `VHOnePassword` spawns the 1Password helper and `VHKeyBackup` depends on it; the `vh` shell-out (`LocalPairing`,
  `LocalNodeAutopair`) is in `VHNodes`, which every package uses; the MCP bridge is its own package and bundle.
- **No device step-up.** Nothing in Desktop answers a server's step-up; the 1.20.0 contract predates the device
  approval key (server #361) that lets a paired device answer `keys` with a Secure Enclave key.

## The account in Desktop

**Linking stays as it is** (`installation-linking.md`), started from the Vaulthalla Cloud section; Desktop keeps the
claim's `account_public_id` in place of the numeric id, and the identity key moves to an app-only group (below).

**What a linked Desktop reads, as an installation (VHC1), with no portal session:**

| Route | What Desktop uses it for |
| --- | --- |
| `GET /v1/installation` | its own installation, `account_public_id` |
| `GET /v1/deployments` | every server of the account, with `node_id`, name, last seen (mapping, below) |
| `GET /v1/vaults` | every vault, its replicas (`deployment_id`, `origin_vault_id`) and sealed label |
| `GET /v1/storage`, `/usage`, `/eject` | the whole account read-only: quota, usage per day, each vault's switch and bucket state (`waiting` with its reason … `ready`, `ejected`), ejection progress |
| `GET /v1/billing`, `/plans` | the status view (state, plan, quota and use, what still works, next date; never invoices or cards); polled after a handoff |
| `GET /v1/recovery/vaults` | coverage per vault, including `account_key` per key version |
| `GET /v1/keys/account` | the statement chain, checked against the seed held here; whether an offline copy is confirmed |
| `GET /v1/keys/account/unlocks`, `GET /v1/keys/holders` | how else the key can be unlocked (no ciphertext); devices holding it |
| `GET /v1/keys/vaults/{uid}/envelopes` | a vault's envelopes to the account key, for restores |
| `GET /v1/recovery/restores/deliverable`, `GET /v1/keys/transfers/pending` | what this Mac can deliver |

The cloud designs open each of these to a Desktop installation. **Changes** (creating, rotating or replacing the
key) go through the cloud's **key request**: `POST /v1/keys/requests`, Desktop shows the request code and opens the
portal, the account holder compares it and approves with the action's step-up there, and Desktop polls
`GET /v1/keys/requests/{id}` until it is applied (`key-manager.md`).

### The account recovery key on this Mac

The key is a recovery seed (`key-manager.md`). `VHRecovery` already has the seed (`RecoverySeed`: generation, text
form, the X25519 recipient and Ed25519 derivations), KEV1 suites 1 and 2 and the recovery kit, all against the
vendored golden vectors. The **recovery code is the seed itself** in that text form, so typing it needs nothing new.
It lacks: the **key statement** (seven lines, with the signed reason `initial`, `routine` or `compromise`), its
16-byte fingerprint and chain check; **KAK1** for both KEV1 suites, which carries the seed between devices; the
**transfer** and **key request** codes; and opening a **sealed vault label** (`vh.vault-label.v1`). Each goes into
`VHRecovery` with vectors from vl-keykit. Passkey wraps stay the browser's.

- **Creating it** (onboarding, when the account has none at Desktop's first link). Desktop generates the seed and
  shows it once: "This is your recovery key. With it, your files can be recovered even if you lose every device and
  Vaulthalla Cloud is unavailable. Nobody else has a copy." Then **Save to 1Password**, **Print** or **I wrote it
  down**, and typing back two of its groups. Desktop signs generation 1 (`initial`) and sends it with the offline-copy
  confirmation as a `create` key request; "Approve on vaulthalla.cloud" shows the request code until it is applied.
- **Receiving it.** A **transfer** (`POST /v1/keys/transfers`): Desktop shows the transfer code and a holder (another
  Desktop, or the portal unlocked by passkey or code) delivers KAK1. Or the **recovery code** typed into Desktop:
  no route at all; Desktop derives the keys and checks the fingerprint against `GET /v1/keys/account`.
- **Keeping it.** Never in the clear. Desktop registers as a holder (`POST /v1/keys/holders`) with a **Secure Enclave
  P-256 key**, which the cloud now allows, and keeps the seed as the KAK1 blob sealed to it, the form a rotation
  delivers; the plaintext lives only in a `SecretBytes` during one operation.
- **Who may touch it.** The item, the holder key and the cloud identity key go into a new app-only keychain group,
  `$(AppIdentifierPrefix)sh.vaulthalla.app.account`: the app and the agent (its own executable), not the extension or
  `vaulthalla-mcp.app`. Only the credential owner writes them (`AccountKeyStore` and the link store take the lease
  like `NodeStore`). Using the seed asks for Touch ID or the Mac's password each time (open question 1).
- **Delivering.** Restores open the envelopes with `seed.recipient()` instead of a kit's; transfers seal KAK1 to the
  temporary key. Nothing leaves the Mac before the person confirms the code on the other side, as today.
- **The fingerprint** is shown in the Recovery Key pane, computed from the seed this Mac holds, never taken from the
  cloud. On a server whose `cloud.link.status` shows no pin, Desktop offers "Use this account's recovery key on
  *nas*": `cloud.key.confirm {fingerprint}` over the pinned device connection, answered with the `keys` step-up by the
  device approval key (server `key-manager.md`; super admin, capability `cloud.account_key`). No digits are compared.
- **The offline copy.** `GET /v1/keys/account` says whether one is confirmed; managed storage can't start without
  it. Desktop is the exporter (a kit to 1Password, or printed); recording a copy made after creation needs a key
  request action the cloud doesn't list yet.
- **Rotation** (a `rotate` key request, from this Mac as a holder or from the portal): a new seed and recovery code,
  shown and confirmed like the first. Desktop checks every generation is signed by the one it holds; an unsigned
  replacement is a warning with the new fingerprint. A `routine` rotation leaves vault keys alone; `compromise` makes
  servers rotate them, and the pane says so.

## Mapping nodes to deployments

A node maps to a deployment when the deployment's `node_id` equals `Node.serverNodeID` **and** the node confirms it
over its own connection, since `account-model.md` calls the node id a hint: `cloud.link.status` gives installation id,
deployment id, account public id and the pinned fingerprint and generation. Until a node answers, it shows as likely.

| Case | What Desktop shows |
| --- | --- |
| Paired node, linked to this account | its vaults with storage and backup state; the switch works through the node |
| Deployment Desktop isn't paired with | the server's name and last contact; its vaults from the cloud (names once the key is unlocked); "Pair this Mac with *nas*" opens Add Node; storage changes open the browser |
| Paired node not linked | "Not connected to Vaulthalla Cloud" and how to link it (`vh cloud link`, or the server's own page) |
| Paired node linked to another account | "Connected to a different Vaulthalla Cloud account"; nothing else |
| Node without `cloud.storage.managed_remotes` | as a deployment Desktop isn't paired with, plus "Update Vaulthalla on *nas*" |

**Vault identity** is the account's `vault_uid`. A replica's `(deployment, origin_vault_id)` is, on a paired node,
Desktop's `(node id, vault id)`; both must agree with the `vault_uid` the node's `Vault` model now carries for any
user who can see the vault before Desktop offers a storage action. A mismatch is shown, not resolved.

## The "Vaulthalla Cloud" section

**Where.** A top-level sidebar section between Recovery Keys and Nodes, its panes as rows like a node's sections
(`Sidebar.swift`, `SidebarItem.cloud(CloudSection)`, routed by `DetailView`). Not a `NodeSection`: it spans every
server, unpaired ones too. Not a Settings tab: it holds live state and actions. Settings ▸ Cloud goes away.

| Pane | What a person sees and does |
| --- | --- |
| Account | linked as, plan state in words, the next date, one action (choose a plan, update payment, manage billing) |
| Storage | usage against the plan's quota, per vault, "updated daily" |
| Vaults | every vault on every server: name, servers, where it is stored, backup, the storage switch |
| Servers | every server of the account and every paired node, as the mapping table shows them |
| Recovery Key | whether this Mac holds it, the fingerprint, the offline copy ("Saved offline on *date*", or "No offline copy yet: Vaulthalla Cloud storage starts once you save one" with Save to 1Password and Print), how else it unlocks, devices holding it, servers using it, waiting transfers and restores |
| Leave managed storage | what stops and what stays, then the browser; progress from each vault's state in `GET /v1/storage` |

**Where each action goes.**

| Action | Goes to |
| --- | --- |
| The switch (`cloud.storage.switch`; off runs `vault.remote.detach`), accepting the offer for existing local vaults (`cloud.storage.offer.accept`) | the server, over its ws contract; no step-up; RBAC module `cloud` `storage` and the vault's Edit; progress from `vault.remote.status` `progress` |
| Adding a vault to the recovery key (`vault.keys.recipients.add {account_key: true}`), BYOS attach (`vault.remote.attach`, `.abort`) | the server, with its `keys` step-up answered by this Mac's device approval key |
| Delivering restores and transfers, registering as a holder | the cloud, signed by this Mac |
| Creating, rotating or replacing the key | a key request, approved in the portal |
| Choosing a plan, payment, invoices, step-ups (deleting a stored copy, leaving, removing a server, approving a link or a restore) | the browser: `POST /v1/billing/handoffs` for billing, the portal page for the rest; Desktop polls `GET /v1/billing`, `/v1/storage` or the item it waits on every few seconds for a few minutes, then offers Refresh |

Desktop opens only `https` URLs on the configured portal origin and refuses any other. Cloud step-ups exist only in
the portal: Desktop lists approvals waiting (links, restores) and opens them there (open question 2).

**Plain words** (the portal's rules, `portal.md`): "server", "plan", "recovery key", "stored in Vaulthalla Cloud",
"your own storage", "only on *nas*". The entitlement states read:

| State | Desktop says |
| --- | --- |
| `active` | "Your plan is active." |
| `past_due` | "Your payment didn't go through. Everything keeps working until *date*." Update payment |
| `restricted` | "Read-only: you can open and delete files, not add new ones." Update payment, or move to your own storage |
| `suspended` | "Paused. Your files are kept, but your servers can't reach them until payment is updated." |
| `ended` | "Your plan ended. Files stored in Vaulthalla Cloud are deleted on *date* unless you move them." |

Each vault's line, from the server's state (or the cloud's for a server Desktop isn't paired with): "Backed up";
"Uploading, 40 %, about 2 hours"; **"Not backed up yet"** with why: "waiting for its storage", "payment needed", "the
recovery key isn't confirmed on *nas*", "no recovery key copy saved offline", "Vaulthalla Cloud can't be reached from
*nas*", or "empty: backed up after its first file" (new vaults start local and attach once their storage exists, as
the server proposes); "Off"; "Read-only"; **"Moved to *nas-2*"** after a restore onto another server (the old server
keeps its local copy, without the stored copy); "Uses its own storage" for BYOS. Existing local vaults get one offer
listing them with sizes; nothing uploads until the person accepts. Turning the switch off says what it costs first:
"*nas* first downloads the files it doesn't have yet (about *size*) and needs that much free space. Then the copy in
Vaulthalla Cloud can be deleted." Deleting is a second step, in the browser. **What the simplified pane hides**,
compared with BYOS: credentials, buckets, endpoints, regions, storage tiers and cost. The per-node Credentials, Cost
and vault storage UI (`CredentialsView`, `CostView`, `VaultInspector`, `NewVaultSheet` with `AdoptBucketFields`) stay
for BYOS; a managed vault there shows "Stored in Vaulthalla Cloud" instead of its key and bucket, and its credential
is read-only from the contract (`APIKey.origin`, `editable`).

## Key manager as the default backup

Unchanged when no account is linked. When one is:

- **Recovery Keys** reads coverage from `GET /v1/recovery/vaults` beside each node's `vault.keys.status`. A vault
  whose every needed version has an envelope to the account key is "Protected by your recovery key"; "needs backup"
  notifications follow that, not 1Password. A vault outside it (BYOS or local, beyond the free allowance or not added)
  offers "Add to recovery key", a server operation.
- **1Password holds the offline copy**: an item with the account key as an ordinary recovery kit, which opens every
  covered vault from its bucket with no cloud and pins each vault's attestation keys. That needs one new helper
  operation and item layout in `Helpers/vaulthalla-1password`. Per-vault items (D6) become an optional second copy.

## Engineering

- **Cloud contract.** `contract/cloud/`: a versioned route and model description the cloud publishes (it has none
  today), its `SOURCE.json`, and `vectors.json` (VHC1, restore and transfer codes, key statement and fingerprint,
  KAK1, labels). A generator like `tools/gen-contract.py` emits `Codable` models into `VHCloud`; CI checks the
  vendored files, as it does `contract/`. Error codes `payment_required` and `rate_limited` map to typed errors.
- **Gating.** `cloud.enabled` stays the switch until launch, for the sidebar section and the Recovery Keys changes;
  the launch flips its default with the server's claims change. Per node: `cloud.account_key` and
  `cloud.storage.managed_remotes` from `meta.hello`, `cloud.storage.status` `available` at run time, and the
  attach-remote commands by presence in `commands`. A cloud without storage routes hides those panes.
- **Transport.** `URLSessionCloudTransport` gets its own `.ephemeral` session: no cookie store, cache or credential
  storage, cookies off, redirects refused, TLS 1.2 at least, system trust (the trust that matters is the VHC1
  signature and the key chain, checked here), responses capped at 1 MiB. The endpoint is fixed in release builds and
  overridable in debug builds and by a staging default. Bodies and ids are never logged (`Logger` `.private`). Only
  the app calls the cloud, while the section is visible or after a handoff; the extension and the agent make no cloud
  calls in wave 1, and no node session, Finder operation or sync waits on one.
- **Signing out.** "Keep me signed in" off: the seed is kept in memory only, never registered as a holder, and the
  link is revoked at quit with the nodes. **Sign Out** unlinks too. Unlink revokes the installation, drops the
  holder, and deletes this Mac's copy of the key only when an offline copy is confirmed or another holder or passkey
  exists; otherwise it stops and offers the 1Password copy first. Keys are never lost to a sign-out.
- **UI sweep and previews.** `CloudPreviewData` (two paired servers, one unpaired deployment, one unlinked node,
  managed, BYOS and local vaults) behind a fake `CloudTransport`, like `PreviewTransport`; `-VHDebugSelect
  cloud:<pane>` and `-VHDebugCloud <state>` (unlinked, waiting, no key, no offline copy, each entitlement state,
  over quota, a moved vault, leaving); `tools/ui/sweep.sh` adds those selectors.
- **Tests.** Vectors and contract samples in `VHCloudTests` and `VHRecoveryTests`; mapping and wording as pure
  tables; the handoff origin check; the transport configuration; the sign-out guard; keychain queries as pure tests;
  `tools/keychain-proof` extended to the app-only group and the sealed seed; a live suite against staging on dev.

## Structure for the later store app

New code goes into packages a sandboxed second target can link: the client, contract models, account key store,
transfers and mapping in `VHCloud` (on `VHCore` and `VHRecovery` only); formats in `VHRecovery`; server operations in
the generated `VHContract` behind `VHNodes`; views in `App/Vaulthalla/Features/Cloud` on the shared design system.
Nothing in them spawns a process, links Sparkle or assumes an unsandboxed path, and the browser handoff is a protocol
so the store app can put StoreKit there. The store-incompatible pieces move behind boundaries: `LocalPairing` and
`LocalNodeAutopair` out of `VHNodes` into `VHLocalNode`; `VHKeyBackup` reaching 1Password through a destination
protocol; Sparkle in an app-only folder; `VHMCP` as it is. D5 ("No Mac App Store build") and D8 (direct distribution)
in `docs/architecture.md` rule out a store build today; the store plan amends both (not this document), and D8's
amendment also settles the store app's bundle ids and its license terms beside AGPL-3.0, the LLC's decision.

## Wave 4 allowance

Not designed here. Wave 1 must not preclude vaults that have no server:

- **The section** keys vaults by `vault_uid`, never by node; "where" may be "this Mac" with no server row.
- **`Node`** stays a paired server. A serverless vault is not a fake node with an endpoint, and no `kind` is added
  now; `VaultDomainID` (`<node id>.<vault id>`, an `Int64` vault id) gets a second form then, so no wave 1 code may
  assume every domain parses to a node.
- **File Provider seams.** `ReplicaLink` is shaped by the ws contract (`send<R: WsRequest>`) and `VaultLanes`; wave 4
  puts an operation-level seam (list, fetch a range, conditional write, delete, thumbnails) under `VaultReplica`, with
  `NodeLink` as one implementation. Wave 1 adds no new ws-specific calls to `VaultReplica`.
- **Keys.** The app-only group can later be granted to the extension, or the agent can hand it vault keys.

## Work items, in landing order

1. Transport hygiene, fixed endpoint, public account id, link store under the lease in the app-only group (S).
2. `VHRecovery`: key statement with reason, chain check, KAK1 (both suites), transfer and request codes, labels (M).
3. Package boundaries for the store app: `VHLocalNode`, the backup destination protocol, Sparkle (S); any time.
4. Vendored cloud contract and typed `VHCloud` models, once the cloud publishes one (M).
5. Account key store, holder registration, key requests, onboarding with the offline copy, transfers, restores (M).
6. Contract bump to the server release with `vault_uid` on `Vault`, `cloud.*` and `vault.remote.*`; the device
   approval key answering `keys` step-ups (#361); `cloud.key.confirm` (M).
7. The section: shell, Account, Storage, Servers, Vaults read-only, mapping, preview data and sweep (M).
8. Server operations in Vaults, gated by capability, with progress (M); browser handoffs and polling (S).
9. Recovery Keys with coverage; the account-key kit in 1Password and print; per-vault items as a second copy (M).
10. Sign-out semantics; Settings ▸ Cloud removed (S). At launch: `cloud.enabled` on by default.

## Open questions

1. **Touch ID for every use of the seed.** *Recommendation: yes; uses are rare and attended.*
2. **Cloud approvals in Desktop** (links, restores). *Recommendation: list them and open the portal, as key requests
   do; host them only if the cloud ever gives installations a step-up.*
3. **The switch for a server Desktop isn't paired with** (the cloud's `managed-storage.md` question 9).
   *Recommendation: open the portal rather than flip `enabled` at the cloud, since turning off needs the server's
   detach to hydrate first.*
4. **The cloud identity key.** *Recommendation: ask the cloud for a P-256 VHC1 variant so it can live in the Secure
   Enclave; keep Ed25519 in the app-only group until then.*
5. **One account per macOS user.** *Recommendation: yes; a node linked to another account is shown, not managed.*

Settled in the cloud and server designs since the first draft: P-256 holder keys and KAK1 for both suites, Desktop's
reads, key requests, and `cloud.key.confirm`. The recovery code as the seed is the cloud's open question 1.
