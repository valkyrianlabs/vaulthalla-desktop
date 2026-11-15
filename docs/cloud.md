# Vaulthalla Cloud in Desktop

Optional, and hidden until vaulthalla.cloud opens: `defaults write sh.vaulthalla.app cloud.enabled -bool YES` shows
the **Vaulthalla Cloud** section in the sidebar (a Mac already linked shows it too). Nothing else in Desktop needs it.
The design is [`cloud-storage.md`](cloud-storage.md); the protocols are valkyrianlabs/vaulthalla-cloud
`docs/design/installation-linking.md`, `installation-requests.md`, `key-manager.md`, `billing.md` and
`recovery-restore.md`.

Code: `Sources/VHCloud` (the client, models, transport, the link and account-key stores, holder keys, the account
key's flows, node mapping, portal links and wording), `Sources/VHKeykit` (vl-keykit's C API; every key format),
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

Storage usage, the per-vault storage switch and leaving managed storage wait for the server's `cloud.storage.*`
commands and are not shown.

## Keys

- The link's Ed25519 identity key and the account key live in the app-only keychain group
  `<TEAM>.sh.vaulthalla.app.account` (not the File Provider extension's or `vaulthalla-mcp.app`'s), this device only,
  written only by the credential owner. Unsigned builds use the file keychain.
- The account key is kept only as KAK1 sealed to a Secure Enclave P-256 holder key (software P-256 where there is no
  enclave); a signed build asks for Touch ID or the password at each use. It is unwrapped inside vl-keykit for one
  operation at a time.
- A transfer's temporary key is the new holder key itself, so the delivered KAK1 is kept as it is.
