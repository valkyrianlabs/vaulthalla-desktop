# File Provider spike (vaulthalla/desktop#2) - THROWAWAY, not product code

A read-only `NSFileProviderReplicatedExtension` over a paired Vaulthalla node, built with the free Personal Team.
Findings: the comment on vaulthalla/desktop#2. The commit on this branch also patches
`Sources/VHIdentity/DeviceIdentityStore.swift` (identity lookup in the data protection keychain) so the spike can
create a Secure Enclave identity at all; see the findings.

| Target | Bundle id | What |
|---|---|---|
| `VaulthallaSpike` (app, unsandboxed, LSUIElement) | `sh.vaulthalla.desktop.spike` | command runner: `put-secret`, `create-key`, `pair <host:port>`, `self-test`, `add-domain`, `add-domains`, `remove-domain`, `remove-all`, `list-domains`, `signal`, `root-url`, `probe` |
| `SpikeFileProvider` (appex, sandboxed) | `sh.vaulthalla.desktop.spike.fileprovider` | the extension; `SPIKE_SELFTEST=1 <appex>/Contents/MacOS/SpikeFileProvider` runs its self-test inside its own sandbox |
| `SpikeAgent` (app in `Contents/Library/LoginItems`) | `sh.vaulthalla.desktop.spike.agent` | the same domain commands from a second process; `embed-agent-tool.sh` also installs it as a bare tool in `Contents/MacOS` |

App Group and keychain access group: `QG2U5HNCG4.sh.vaulthalla.desktop.spike`.

```sh
xcodebuild -project FPSpike.xcodeproj -scheme VaulthallaSpike -derivedDataPath build/DD \
    DEVELOPMENT_TEAM=QG2U5HNCG4 -allowProvisioningUpdates build
APP=build/DD/Build/Products/Debug/VaulthallaSpike.app/Contents/MacOS/VaulthallaSpike
$APP put-secret && $APP create-key && $APP pair 10.0.0.11:36982 && $APP self-test
SPIKE_SELFTEST=1 build/DD/Build/Products/Debug/VaulthallaSpike.app/Contents/PlugIns/SpikeFileProvider.appex/Contents/MacOS/SpikeFileProvider
./e2e.sh        # needs the domain enabled once in System Settings (File Providers)
./cleanup.sh
```
