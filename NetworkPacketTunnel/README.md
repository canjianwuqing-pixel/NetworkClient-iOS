# Packet Tunnel 预留

NetworkPacketTunnelProvider.swift 当前未加入任何 Target，且受 NETWORK_PACKET_TUNNEL 编译条件保护；当前共享 Scheme 不构建、不嵌入 Extension。

下一阶段创建独立 app-extension Target 后，再配置该编译条件、principal class、bundle identifier、签名、Network Extensions 和 App Groups。现有 provider 故意返回“未集成”错误，不能拿来报告 VPN 已连接。

Info.plist.template 和 Entitlements.plist.template 仅为结构参考，标识符需要在实际开发者团队注册。不得将模板文件当成授权已经生效。

未来Target/产品名采用 `NetworkPacketTunnel`，Bundle ID 使用 `$(NETWORK_PACKET_TUNNEL_BUNDLE_ID)`，App Group 使用 `$(NETWORK_APP_GROUP_ID)`，均在安装构建配置定义；目前未创建、签名或嵌入此Target。
