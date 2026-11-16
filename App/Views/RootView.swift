import SwiftUI

enum ConfigurationUnavailableVPNPresentation {
    static func showsDisconnect(for state: MinimalVPNController.State) -> Bool {
        state != .disconnected
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @State private var section = 0
    @StateObject private var noticeAutoPresenter = HomeNoticeAutoPresentationCoordinator()
    var body: some View {
        Group {
            if model.config == nil {
                if model.configurationStatus.source == .unavailable {
                    ConfigurationUnavailableView()
                } else {
                    ConfigurationLoadingView()
                }
            } else if model.session != nil {
                VStack(spacing: 0) {
                    Group {
                        switch section {
                        case 1: NavigationStack { CommerceView() }
                        case 2: NavigationStack { ProfileView() }
                        default: NavigationStack {
                            HomeView()
                                .environmentObject(noticeAutoPresenter)
                        }
                        }
                    }
                    HStack(spacing: 5) {
                        navigationItem(0, L10nKey.mainSectionHome, "house.fill")
                        navigationItem(1, L10nKey.mainSectionPurchase, "bag.fill")
                        navigationItem(2, L10nKey.mainSectionProfile, "person.crop.circle")
                    }.padding(7).background(brand.theme.card).clipShape(RoundedRectangle(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).stroke(brand.theme.border, lineWidth: 1))
                        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4)
                // Match the macOS AppWindowAppearance width while allowing narrow iPhone and iPad windows.
                }.frame(maxWidth: 430).frame(maxWidth: .infinity).background(brand.theme.background)
            } else { NavigationStack { AuthView(mode: .login) } }
        }.foregroundStyle(brand.theme.text).tint(brand.theme.accent)
        .overlay(alignment: .top) {
            if model.busy && model.showsGlobalBusyIndicator {
                ProgressView()
                    .padding(10)
                    .background(brand.theme.card, in: Capsule())
                    .accessibilityLabel(Text("common.status.processing"))
                    .accessibilityIdentifier("root.globalBusy")
            }
        }
    }
    private func navigationItem(_ id: Int, _ title: String, _ icon: String) -> some View {
        Button { section = id } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 21)); Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold)) }
                .frame(maxWidth: .infinity).frame(height: 58)
                .foregroundStyle(section == id ? brand.theme.emphasis : brand.theme.secondary)
                .background(section == id ? brand.theme.tint : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("navigation.\(id)")
    }
}

private struct ConfigurationLoadingView: View {
    @EnvironmentObject private var brand: BrandProvider

    var body: some View {
        VStack(spacing: 18) {
            BrandLogo(size: 76, radius: 22)
            ProgressView()
                .tint(brand.theme.accent)
            Text(LocalizedStringKey(L10nKey.loginStatusLoadingConfiguration))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(brand.theme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(brand.theme.background)
        .accessibilityIdentifier("configuration.loading")
    }
}

private struct ConfigurationUnavailableView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var vpn: MinimalVPNController
    @State private var disconnectFailed = false

    var body: some View {
        VStack(spacing: 18) {
            BrandLogo(size: 76, radius: 22)
            VStack(spacing: 8) {
                Text(LocalizedStringKey(L10nKey.configurationUnavailableTitle))
                    .font(.system(size: 20, weight: .bold))
                Text(LocalizedStringKey(L10nKey.configurationUnavailableMessage))
                    .font(.system(size: 13))
                    .foregroundStyle(brand.theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(LocalizedStringKey(L10nKey.configurationUnavailableRetry)) {
                Task { await model.reloadConfiguration() }
            }
            .buttonStyle(BrandButtonStyle())
            .frame(maxWidth: 260)
            .accessibilityIdentifier("configuration.retry")
            if ConfigurationUnavailableVPNPresentation.showsDisconnect(for: vpn.state) {
                Button {
                    disconnectFailed = false
                    Task {
                        do {
                            try await vpn.disconnect()
                        } catch is CancellationError {
                            return
                        } catch {
                            disconnectFailed = true
                        }
                    }
                } label: {
                    Text(LocalizedStringKey(
                        vpn.operation == .disconnecting
                            ? "vpn.state.disconnecting"
                            : L10nKey.configurationUnavailableDisconnectVPN
                    ))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(brand.theme.emphasis)
                .background(brand.theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(brand.theme.border, lineWidth: 1))
                .frame(maxWidth: 260)
                .disabled(vpn.operation == .disconnecting)
                .accessibilityIdentifier("configuration.disconnectVPN")
            }
            if disconnectFailed {
                Text(LocalizedStringKey(L10nKey.configurationUnavailableDisconnectFailed))
                    .font(.system(size: 12))
                    .foregroundStyle(brand.theme.error)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(brand.theme.background)
    }
}

struct AccountRequiredView: View {
    @EnvironmentObject var brand: BrandProvider
    var body: some View {
        VStack(spacing: 14) {
            Text("请先登录").font(.headline)
            Text("登录后可查看账户、订阅节点和订单。").font(.system(size: 13)).foregroundStyle(brand.theme.secondary)
        }.padding(22).surfaceCard().padding(12)
    }
}
struct BrandHeader: View {
    @EnvironmentObject var brand: BrandProvider
    var body: some View {
        VStack(spacing: 0) {
            BrandLogo(size: 72, radius: 22)
            Text(verbatim: brand.snapshot.name).font(.system(size: 30, weight: .bold)).padding(.top, 16).accessibilityIdentifier("brand.name")
            if let loginTitle = brand.snapshot.visibleLoginTitle {
                Text(verbatim: loginTitle).font(.system(size: 13)).foregroundStyle(brand.theme.secondary).padding(.top, 7)
                    .accessibilityIdentifier("brand.loginTitle")
            }
        }.frame(maxWidth: .infinity)
    }
}
