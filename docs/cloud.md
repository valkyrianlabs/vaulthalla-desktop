# Vaulthalla Cloud in Desktop

Optional, and hidden until vaulthalla.cloud opens: `defaults write sh.vaulthalla.app cloud.enabled -bool YES` shows
**Settings ▸ Cloud**. Nothing else in Desktop needs it. Protocols: valkyrianlabs/vaulthalla-cloud
`docs/design/installation-linking.md`, `installation-requests.md` and `recovery-restore.md`. Code: `Sources/VHCloud`
(client, signing, the keychain link store), `Sources/VHRecovery` (KEV1, seed, kit), the view
`App/Vaulthalla/Features/Settings/CloudSettingsView.swift`.

## Linking this Mac

**Link This Mac** creates an Ed25519 identity key, keeps it in the data protection keychain (this device only:
Ed25519 can't live in the Secure Enclave), and shows a code and the key's fingerprint. On vaulthalla.cloud the account
holder enters the code, checks the fingerprint, and approves with a fresh second factor; Desktop then signs every
request with the key (VHC1-Ed25519). **Unlink** revokes it in the cloud and deletes the key.

## Delivering a restore

When a server restores a vault through the cloud (`vh vault recover --from-cloud`), it shows a **restore code**. After
the owner approves the restore on vaulthalla.cloud, it appears under **Restores waiting for this Mac** with the code
Desktop computes itself from the server's temporary key.

1. **Deliver from Recovery Kit…** asks for the vault's recovery kit (a `vh.recovery-kit` JSON file; from 1Password
   once #50 lands).
2. Desktop asks whether the server shows the same code. Only on yes does anything leave the Mac.
3. It opens the vault's stored envelopes with the kit's recipient and re-wraps each key version to the temporary key;
   vaulthalla.cloud relays them but can't open them. A cloud whose code doesn't match the key, or a restore whose key
   changed since it was listed, is refused before anything is sent.
