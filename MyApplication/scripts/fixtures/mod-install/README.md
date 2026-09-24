# Mod installation regression fixtures

The JSON snapshots were collected from the Modrinth API and checksum-verified publisher JARs during the 2026-09-10 phone investigation. They are test data, not instructions. Exact version IDs: Iris `fDpuVzVr`, Sodium rejected pairing `rkdTcxoT`, Sodium pinned pairing `UddlN6L4`, Inventory Profiles Next `YKjWPbto`.

`versions-installed.json` and the two-entry `sodium-versions.json` preserve publisher metadata used by the production mapper/resolver. The `*.fabric.mod.json` files are the original package declarations. The source URLs and complete SHA-1/SHA-512 verification record are retained in `diagnostics/mod-install-audit-20260910/collection.json`. Tests create bounded ZIP containers from these declarations; original full JAR/device validation is separate evidence.
