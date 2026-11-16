import SwiftUI

enum HomeAppearance {
    static let pageHorizontalPadding: CGFloat = 12
    static let pageTopPadding: CGFloat = 12
    static let pageBottomPadding: CGFloat = 8

    static let announcementHeight: CGFloat = 64
    static let announcementHorizontalPadding: CGFloat = 12
    static let announcementIconSize: CGFloat = 40
    static let announcementSymbolSize: CGFloat = 15
    static let announcementIconColumnWidth: CGFloat = 50
    static let announcementChevronWidth: CGFloat = 22
    static let announcementTitleDateSpacing: CGFloat = 4
    static let announcementBadgeCornerRadius: CGFloat = 8

    static let announcementPanelCornerRadius: CGFloat = 18
    static let announcementPanelContentCornerRadius: CGFloat = 14
    static let announcementPanelContentPadding: CGFloat = 14
    static let announcementPanelContentMaxHeight: CGFloat = 330
    static let announcementPanelShadowRadius: CGFloat = 30
    static let announcementPanelShadowY: CGFloat = 8
    static let announcementPanelOverlayOpacity = 0.47

    static let trafficCardHeight: CGFloat = 244
    static let trafficCardTopSpacing: CGFloat = 10
    static let trafficCardHorizontalPadding: CGFloat = 20
    static let trafficCardTopPadding: CGFloat = 18
    static let trafficCardBottomPadding: CGFloat = 16
    static let trafficUpperHeight: CGFloat = 158
    static let trafficLeftColumnWidth: CGFloat = 166
    static let trafficColumnSpacing: CGFloat = 20
    static let trafficRingSize: CGFloat = 138
    static let trafficRingTrackSize: CGFloat = 128
    static let trafficRingStrokeWidth: CGFloat = 8
    static let trafficMetricTopSpacing: CGFloat = 11

    static let connectionCardHeight: CGFloat = 152
    static let connectionCardTopSpacing: CGFloat = 12
    static let powerButtonSize: CGFloat = 82
    static let powerButtonInnerSize: CGFloat = 68
    static let powerButtonSymbolSize: CGFloat = 34
    static let connectionLabelTopSpacing: CGFloat = 10
    static let connectionButtonHoverOpacity = 0.92
    static let connectionButtonPressedOpacity = 0.78

    static let actionCardHeight: CGFloat = 54
    static let nodeCardTopSpacing: CGFloat = 10
    static let proxyCardTopSpacing: CGFloat = 8
    static let actionHorizontalPadding: CGFloat = 18
    static let actionIconSize: CGFloat = 21
    static let actionChevronSize: CGFloat = 16

    static let bottomNavigationRowHeight: CGFloat = 78
    static let bottomNavigationHorizontalMargin: CGFloat = 12
    static let bottomNavigationPadding: CGFloat = 7
    static let bottomNavigationCornerRadius: CGFloat = 26
    static let bottomNavigationItemHeight: CGFloat = 58
    static let bottomNavigationItemCornerRadius: CGFloat = 18
    static let bottomNavigationIconSize: CGFloat = 21
    static let bottomNavigationLabelSpacing: CGFloat = 4
}

import SwiftUI

enum LoginAppearance {
    // Overall login content
    static let contentMaxWidth = 430.0
    static let contentHorizontalPadding: CGFloat = 30
    static let contentTopPadding: CGFloat = 18
    static let contentBottomPadding: CGFloat = 18

    // Authentication card
    static let cardWidth: CGFloat = 354
    static let cardPadding: CGFloat = 34

    // Brand logo and heading
    static let logoSize: CGFloat = 72
    static let logoCornerRadius: CGFloat = 22
    static let logoToAppNameSpacing: CGFloat = 16
    static let appNameToLoginTitleSpacing: CGFloat = 7
    static let loginTitleToFieldsSpacing: CGFloat = 28

    // Brand loading skeleton
    static let brandSkeletonSpacing: CGFloat = 9
    static let appNameSkeletonWidth: CGFloat = 132
    static let appNameSkeletonHeight: CGFloat = 24
    static let appNameSkeletonCornerRadius: CGFloat = 5
    static let loginTitleSkeletonWidth: CGFloat = 184
    static let loginTitleSkeletonHeight: CGFloat = 13
    static let loginTitleSkeletonCornerRadius: CGFloat = 4

    // Input fields
    static let fieldContainerHeight: CGFloat = 56
    static let fieldHeight: CGFloat = 50
    static let fieldTopInset: CGFloat = 6
    static let fieldCornerRadius: CGFloat = 14
    static let fieldIconColumnWidth: CGFloat = 44
    static let fieldIconSize: CGFloat = 18
    static let fieldTrailingColumnWidth: CGFloat = 44
    static let fieldTextTrailingPadding: CGFloat = 14
    static let floatingLabelLeading: CGFloat = 38
    static let floatingLabelHorizontalPadding: CGFloat = 4
    static let fieldBorderWidth: CGFloat = 1

    // Password and account helpers
    static let forgotPasswordTopSpacing: CGFloat = 12
    static let forgotPasswordBottomSpacing: CGFloat = 8
    static let linkButtonMinHeight: CGFloat = 24
    static let passwordVisibilityIconSize: CGFloat = 18
    static let passwordVisibilityButtonSize: CGFloat = 34
    static let rememberRowSpacing: CGFloat = 8
    static let rememberRowTopSpacing: CGFloat = 14
    static let checkboxSize: CGFloat = 14
    static let checkboxCornerRadius: CGFloat = 4
    static let checkboxIconSize: CGFloat = 9

    // Login button
    static let loginButtonTopSpacing: CGFloat = 24
    static let loginButtonContentSpacing: CGFloat = 8

    // Status and error presentation
    static let statusTopSpacing: CGFloat = 14
    static let errorTopSpacing: CGFloat = 14
    static let retryTopSpacing: CGFloat = 10
}

struct SurfaceCard: ViewModifier {
    @EnvironmentObject var brand: BrandProvider
    func body(content: Content) -> some View {
        content.background(brand.theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(brand.theme.border, lineWidth: 1))
            .shadow(color: brand.theme.shadow, radius: 18, y: 4)
    }
}
extension View {
    func surfaceCard() -> some View { modifier(SurfaceCard()) }
}
struct BrandButtonStyle: ButtonStyle {
    @EnvironmentObject var brand: BrandProvider
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
            .foregroundStyle(enabled ? brand.theme.onAccent : brand.theme.secondary)
            .background(enabled ? brand.theme.accent : brand.theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 14)).opacity(configuration.isPressed ? 0.74 : 1)
    }
}
struct BrandLogo: View {
    @EnvironmentObject var brand: BrandProvider
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Image(uiImage: brand.snapshot.logo).resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .accessibilityLabel(
                brand.snapshot.name.isEmpty
                    ? Text(LocalizedStringKey("brand.logo.accessibility"))
                    : Text(verbatim: brand.snapshot.name)
            )
            .accessibilityIdentifier("brand.logo").accessibilityValue(brand.logoFingerprint)
    }
}
struct BrandTopBar: View {
    @EnvironmentObject var brand: BrandProvider
    var body: some View {
        HStack(spacing: 12) {
            BrandLogo(size: 25, radius: 7)
            if !brand.snapshot.name.isEmpty {
                Text(verbatim: brand.snapshot.name).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("brand.name")
            }
            Spacer()
            if let config = brand.snapshot.config {
                if let url = config.homePageURL { Link(destination: url) { Image(systemName: "globe").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("官方网站").accessibilityIdentifier("shortcut.website") }
                CustomerServiceNavigationLink(config: config) { Image(systemName: "headphones").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("在线客服").accessibilityIdentifier("shortcut.support")
            }
        }.foregroundStyle(brand.theme.emphasis).padding(.horizontal, 18).frame(minHeight: 44)
            // Leave room for iPad window controls when the system navigation bar is hidden.
            .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 28 : 0)
    }
}
struct BrandScreen<Content: View>: View {
    @EnvironmentObject var brand: BrandProvider
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { BrandTopBar(); content }
            .background(brand.theme.background).foregroundStyle(brand.theme.text)
            .toolbar(.hidden, for: .navigationBar)
    }
}

enum RefreshToolbarAppearance {
    static let symbolSize: CGFloat = 17
    static let minimumTapSize: CGFloat = 44
}

enum RetainedContentLoadingPresentation {
    static func showsInitialLoading(isLoading: Bool, hasContent: Bool) -> Bool {
        isLoading && !hasContent
    }

    static func showsRefreshIndicator(isLoading: Bool, hasContent: Bool) -> Bool {
        isLoading && hasContent
    }
}

struct RefreshToolbarButton: View {
    @EnvironmentObject private var brand: BrandProvider

    let isRefreshing: Bool
    let isDisabled: Bool
    let labelKey: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(brand.theme.emphasis)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: RefreshToolbarAppearance.symbolSize, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(
                width: RefreshToolbarAppearance.minimumTapSize,
                height: RefreshToolbarAppearance.minimumTapSize
            )
            .contentShape(Rectangle())
        }
        .frame(
            width: RefreshToolbarAppearance.minimumTapSize,
            height: RefreshToolbarAppearance.minimumTapSize
        )
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(isDisabled || isRefreshing)
        .accessibilityLabel(Text(LocalizedStringKey(
            isRefreshing ? "common.status.refreshing" : labelKey
        )))
        .accessibilityIdentifier(identifier)
    }
}

struct LocalizedMessageText: View {
    let message: LocalizedMessage

    var body: some View {
        switch message {
        case let .localized(key): Text(LocalizedStringKey(key))
        case let .verbatim(value): Text(verbatim: value)
        }
    }
}
