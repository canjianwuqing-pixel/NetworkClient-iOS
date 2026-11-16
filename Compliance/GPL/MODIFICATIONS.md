# Modifications to ProjectClash/Clash

Base source: `ProjectClash/Clash` tag `v1.19.33-clash.2`, commit
`34d0a954c50a9233bc216e3cb73a016397fdad5b`.

The patches must be applied in the following order. Dates are the dates the
patches first entered this repository; the patch files are the complete
machine-readable changes.

## 0002 — iOS application profile and private cache

- File: `0002-ios-app-profile-private-cache.patch`
- SHA-256: `acd607660049ebae6a49e9d368fc4f58886d89e68d9c95d614fdacf2f8c1fc1b`
- Local commit/date: `d08e4e9`, 2026-10-24
- Purpose: make application profile/cache handling safe for the iOS extension
  environment and cover private-cache behavior.
- Affected areas: `bind/clash/runtime_profile*` and
  `component/profile/cachefile/*`.

## 0003 — fail-closed physical path

- File: `0003-fail-closed-physical-path.patch`
- SHA-256: `dce110330e486161ac42e634eeb8ef7b6ed66322dd140d2cb73b8bcbd160dd36`
- Local commit/date: `39ac928`, 2026-10-27
- Purpose: fail closed when the requested physical network path cannot be
  established.
- Affected files: `bind/clash/hook.go`, `bind/clash/hook_test.go`.

## 0004 — route-validation hook evidence

- File: `0004-route-validation-hook-evidence.patch`
- SHA-256: `6370956898224052cd1741341f654512cc45656dc87b7a79e01afbdb57c90862`
- Local commit/date: `39ac928`, 2026-10-27
- Purpose: add internal-only route-validation diagnostics while keeping those
  exports absent from the production SDK.
- Affected areas: `bind/clash/hook*` and the guarded diagnostic implementation.

## 0005 — control socket path

- File: `0005-control-socket-path.patch`
- SHA-256: `6e78674a188988d9f6790ae22d0a3ea0f36377967b8f81a8e368b6d939330ddf`
- Local commit/date: `855dd14`, 2026-11-07
- Purpose: allow an explicitly supplied initial Clash control-socket path while
  preserving the upstream default when the setting is empty.
- Affected files: `bind/clash/setup.go`, `bind/clash/clash_api_test.go`.

## PacketFlowBridge adaptation

- Local file: `NetworkPacketTunnel/Bridge/PacketFlowBridge.swift`
- Local integration/freeze dates: 2026-10-24 and 2026-11-07
- Adapter source commit: `821b6e40f13b423f6e5d3017611851ef6955ca94`
- Copied bridge provenance commit: `dbc0cec0b374ba427749d02402b32b2f7b0f853f`
- Purpose: Swift 6-compatible packet-flow adaptation for the Network Extension.
- License/provenance: `Vendor/Mihomo/ADAPTER_LICENSE.txt` and
  `Vendor/Mihomo/ADAPTER_PACKETFLOW_PROVENANCE.md`.
