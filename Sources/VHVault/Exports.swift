// The engine, its S3 store and the Finder replica moved to VHVaultEngine (which the File Provider extension links
// without the cloud client); VHVault's clients keep seeing them through it.
@_exported import VHVaultEngine
