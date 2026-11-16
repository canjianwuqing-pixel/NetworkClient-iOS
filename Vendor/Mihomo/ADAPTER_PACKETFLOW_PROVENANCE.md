# PacketFlowBridge source provenance

`NetworkPacketTunnel/Bridge/PacketFlowBridge.swift` is the Swift 6 compatible
packet bridge copied from the isolated Mihomo PoC at commit
`dbc0cec0b374ba427749d02402b32b2f7b0f853f`.

- Pinned ProjectClash Adapter base commit: `821b6e40f13b423f6e5d3017611851ef6955ca94`.
- Copied bridge SHA-256: `37ff8b14e12f1f10837fe4c4de6c6f7951f2c911ba05d936d3e65bcd09bccb7d`.
- SDK: ProjectClash/Clash `v1.19.33-clash.2`, source commit
  `34d0a954c50a9233bc216e3cb73a016397fdad5b`, Mihomo Core `1.19.33`.
- License text: `Vendor/Mihomo/ADAPTER_LICENSE.txt` and
  `Vendor/Mihomo/LICENSE-GPL-3.0.txt`.

The independent PoC retains the pinned source tree, original patches, and
build manifests. No symlink or writable shared source is used by this Xcode
project. A public release still requires a complete corresponding-source
snapshot and third-party license review.
