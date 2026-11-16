import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter

    var body: some View {
        Form {
            Section {
                settingsRow(
                    title: "语言",
                    value: SettingsSelectionPresentation.languageTitleKey(
                        for: settings.language
                    ),
                    identifier: "settings.language"
                ) {
                    presentLanguageSelection()
                }
                settingsRow(
                    title: "外观",
                    value: SettingsSelectionPresentation.appearanceTitleKey(
                        for: settings.appearance
                    ),
                    identifier: "settings.appearance"
                ) {
                    presentAppearanceSelection()
                }
            }
            #if DEBUG
            if model.offline && ProcessInfo.processInfo.arguments.contains("--brand-switch-tests") {
                Section(LocalizedStringKey("settings.section.brand_test")) {
                    HStack {
                        BrandLogo(size: 32, radius: 8)
                        Text(verbatim: brand.snapshot.name)
                            .accessibilityIdentifier("settings.brand.name")
                    }
                    Button(LocalizedStringKey("debug.brand.load_sample_a")) {
                        try? brand.selectTestProfile(0)
                    }
                    .accessibilityIdentifier("brand.switch.0")
                    Button(LocalizedStringKey("debug.brand.load_sample_b")) {
                        try? brand.selectTestProfile(1)
                    }
                    .accessibilityIdentifier("brand.switch.1")
                    Text(verbatim: brand.theme.colors["accent"]!.first!)
                        .accessibilityIdentifier("settings.brand.accent")
                    Text(verbatim: brand.snapshot.config?.telegramGroup ?? "--")
                        .accessibilityIdentifier("settings.brand.community")
                    if let config = brand.snapshot.config,
                       case let .url(url, _) = CustomerServiceResolver.resolve(config) {
                        Text(verbatim: url.absoluteString)
                            .accessibilityIdentifier("settings.brand.support")
                    }
                }
            }
            #endif
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .background(brand.theme.background)
        .navigationTitle(LocalizedStringKey(ProfileMenuItem.settings.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: SettingsAppearance.titleSpacing) {
                    Image(systemName: ProfileMenuItem.settings.icon)
                        .font(.system(
                            size: SettingsAppearance.titleIconSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(brand.theme.color(ProfileMenuItem.settings.tint))
                        .accessibilityIdentifier("settings.title.icon")
                    Text(LocalizedStringKey(ProfileMenuItem.settings.titleKey))
                        .font(.headline)
                }
            }
        }
    }

    private func settingsRow(
        title: String,
        value: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(LocalizedStringKey(title))
                    .foregroundStyle(brand.theme.text)
                Spacer(minLength: 12)
                Text(LocalizedStringKey(value))
                    .foregroundStyle(brand.theme.emphasis)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(brand.theme.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func presentLanguageSelection() {
        let request = SettingsSelectionPresentation.languageRequest(
            currentLanguage: settings.language
        )
        Task {
            let choice = await modalPresenter.present(request)
            guard let language = SettingsSelectionPresentation.language(for: choice),
                  language != settings.language else { return }
            settings.language = language
        }
    }

    private func presentAppearanceSelection() {
        let request = SettingsSelectionPresentation.appearanceRequest(
            currentAppearance: settings.appearance
        )
        Task {
            let choice = await modalPresenter.present(request)
            guard let appearance = SettingsSelectionPresentation.appearance(for: choice),
                  appearance != settings.appearance else { return }
            settings.appearance = appearance
        }
    }
}

enum SettingsAppearance {
    static let titleIconSize: CGFloat = 14.25
    static let titleSpacing: CGFloat = 7
}

enum SettingsSelectionPresentation {
    private static let supportedLanguages = ["zh-Hans", "en"]
    private static let supportedAppearances = ["system", "light", "dark"]

    static func languageRequest(currentLanguage: String) -> GlobalModalRequest {
        .immediateSelection(
            title: .localized("语言"),
            options: supportedLanguages.map {
                GlobalModalSelectionOption(
                    id: $0,
                    title: .localized(languageTitleKey(for: $0))
                )
            },
            initialSelectionID: supportedLanguages.contains(currentLanguage)
                ? currentLanguage : "zh-Hans",
            allowsBackdropDismiss: true
        )
    }

    static func appearanceRequest(currentAppearance: String) -> GlobalModalRequest {
        .immediateSelection(
            title: .localized("外观"),
            options: supportedAppearances.map {
                GlobalModalSelectionOption(
                    id: $0,
                    title: .localized(appearanceTitleKey(for: $0))
                )
            },
            initialSelectionID: supportedAppearances.contains(currentAppearance)
                ? currentAppearance : "system",
            allowsBackdropDismiss: true
        )
    }

    static func language(for choice: GlobalModalChoice) -> String? {
        guard case let .selection(value) = choice,
              supportedLanguages.contains(value) else { return nil }
        return value
    }

    static func appearance(for choice: GlobalModalChoice) -> String? {
        guard case let .selection(value) = choice,
              supportedAppearances.contains(value) else { return nil }
        return value
    }

    static func languageTitleKey(for value: String) -> String {
        value == "en" ? "English" : "简体中文"
    }

    static func appearanceTitleKey(for value: String) -> String {
        switch value {
        case "light": "浅色"
        case "dark": "深色"
        default: "跟随系统"
        }
    }
}

enum AboutSupportItem: String, CaseIterable, Identifiable {
    case privacyPolicy, terms, website, diagnostics, telegram
    var id: String { rawValue }

    static func visibleItems(
        config _: AppConfig? = nil,
        registration _: V2BoardRegistrationConfig? = nil
    ) -> [AboutSupportItem] {
        allCases
    }

    var titleKey: String {
        switch self {
        case .privacyPolicy: "about.privacy_policy"
        case .terms: "about.terms"
        case .website: "profile.menu.website"
        case .diagnostics: "diagnostics.title"
        case .telegram: "profile.menu.telegram"
        }
    }

    var systemImage: String {
        switch self {
        case .privacyPolicy: "hand.raised"
        case .terms: "doc.text"
        case .website: "globe"
        case .diagnostics: "doc.text.magnifyingglass"
        case .telegram: "paperplane"
        }
    }

    var tint: String {
        switch self {
        case .privacyPolicy: "success"
        case .terms, .telegram: "support"
        case .website: "website"
        case .diagnostics: "emphasis"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .privacyPolicy: "about.privacy"
        case .terms: "about.terms"
        case .website: "about.website"
        case .diagnostics: "about.diagnostics"
        case .telegram: "about.telegram"
        }
    }

    var unavailableMessageKey: String? {
        switch self {
        case .privacyPolicy: "about.privacy_policy.unavailable"
        case .terms: "about.terms.unavailable"
        case .website: "about.website.unavailable"
        case .telegram: "about.telegram.unavailable"
        case .diagnostics: nil
        }
    }
}

enum AboutSupportPresentation {
    static func configuredURL(
        for item: AboutSupportItem,
        config: AppConfig,
        registration: V2BoardRegistrationConfig? = nil
    ) -> URL? {
        switch item {
        case .privacyPolicy:
            SettingsLinks.externalURL(config.privacyPolicyURL)
        case .terms:
            registration?.termsOfServiceURL
        case .website:
            SettingsLinks.externalURL(config.homePage)
        case .telegram:
            SettingsLinks.communityURL(config.telegramGroup)
        case .diagnostics:
            nil
        }
    }

    static func unavailableRequest(for item: AboutSupportItem) -> GlobalModalRequest? {
        guard let messageKey = item.unavailableMessageKey else { return nil }
        return .information(
            title: .localized(item.titleKey),
            message: .localized(messageKey)
        )
    }
}

struct AboutSupportView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @State private var linkActionTask: Task<Void, Never>?

    private var items: [AboutSupportItem] {
        AboutSupportItem.visibleItems()
    }

    var body: some View {
        ScrollView {
            ProfileMenuCard {
                ForEach(
                    Array(items.enumerated()),
                    id: \.element.id
                ) { index, item in
                    aboutRow(item)
                    if index < items.count - 1 {
                        ProfileMenuSeparator()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(brand.theme.background)
        .navigationTitle(LocalizedStringKey("profile.menu.about_support"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(ProfileMenuItem.aboutSupport.icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15.75, height: 15.75)
                        .foregroundStyle(brand.theme.emphasis)
                        .accessibilityIdentifier("about.title.icon")
                    Text(LocalizedStringKey(ProfileMenuItem.aboutSupport.titleKey))
                        .font(.headline)
                        .foregroundStyle(brand.theme.text)
                }
            }
        }
        .onDisappear {
            linkActionTask?.cancel()
            linkActionTask = nil
        }
    }

    @ViewBuilder
    private func aboutRow(_ item: AboutSupportItem) -> some View {
        if item == .diagnostics {
            NavigationLink { DiagnosticsLogView() } label: {
                aboutLabel(item)
            }
            .accessibilityIdentifier("about.diagnostics")
        } else {
            Button {
                startLinkAction(for: item)
            } label: {
                aboutLabel(item)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item.accessibilityIdentifier)
        }
    }

    private func aboutLabel(_ item: AboutSupportItem) -> some View {
        ProfileMenuRow(
            icon: item.systemImage,
            titleKey: item.titleKey,
            tint: item.tint
        )
    }

    private func startLinkAction(for item: AboutSupportItem) {
        guard item != .diagnostics, linkActionTask == nil else { return }
        linkActionTask = Task { @MainActor in
            defer { linkActionTask = nil }
            do {
                let url: URL?
                if item == .terms {
                    url = try await model.aboutSupportTermsURL()
                } else {
                    url = brand.snapshot.config.flatMap {
                        AboutSupportPresentation.configuredURL(
                            for: item,
                            config: $0,
                            registration: model.registration
                        )
                    }
                }
                try Task.checkCancellation()
                guard let url, await UIApplication.shared.open(url) else {
                    await presentUnavailable(item)
                    return
                }
            } catch is CancellationError {
                // Leaving About or cancelling an in-flight guest-config lookup is silent.
            } catch {
                guard !Task.isCancelled else { return }
                await presentUnavailable(item)
            }
        }
    }

    private func presentUnavailable(_ item: AboutSupportItem) async {
        guard let request = AboutSupportPresentation.unavailableRequest(for: item) else { return }
        _ = await modalPresenter.present(request)
    }
}

enum DiagnosticsLogClearPresentation {
    static func request() -> GlobalModalRequest {
        GlobalModalRequest.destructive(
            title: .localized("diagnostics.clear.confirm.title"),
            message: .localized("diagnostics.clear.confirm.message"),
            primaryTitle: .localized("diagnostics.clear")
        )
    }

    static func shouldClear(for choice: GlobalModalChoice) -> Bool {
        choice == .primary
    }

    static func failureRequest() -> GlobalModalRequest {
        GlobalModalRequest.information(
            title: .localized("diagnostics.title"),
            message: .localized("diagnostics.clear.failed")
        )
    }
}

struct DiagnosticsLogSection: Identifiable, Equatable {
    let day: Date
    let entries: [UserLogEntry]

    var id: Date { day }
}

enum DiagnosticsLogPresentation {
    static let titleIconSize: CGFloat = 15.75
    static let titleSpacing: CGFloat = 7
    static let rowContentSpacing: CGFloat = 3.2
    static let rowVerticalPadding: CGFloat = 1.6
    static let rowVerticalInset: CGFloat = 8.8
    static let rowHorizontalInset: CGFloat = 20
    static let levelHorizontalPadding: CGFloat = 6
    static let levelVerticalPadding: CGFloat = 1.6

    static func sections(
        from entries: [UserLogEntry],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [DiagnosticsLogSection] {
        Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }
        .map { day, values in
            DiagnosticsLogSection(
                day: day,
                entries: values.sorted { $0.timestamp > $1.timestamp }
            )
        }
        .sorted { $0.day > $1.day }
    }

    #if DEBUG
    static let longListLaunchArgument = "--ui-diagnostics-long-list"

    static func usesLongListFixture(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("--offline")
            && arguments.contains("--ui-sample")
            && arguments.contains(longListLaunchArgument)
    }

    static func longListFixture(
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UserLogEntry] {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 11
        components.day = 12
        components.hour = 21
        components.minute = 24
        components.second = 56
        guard let baseDate = calendar.date(from: components) else { return [] }

        let levels: [UserLogLevel] = [.info, .success, .warning, .error]
        let modules: [UserLogModule] = [.app, .auth, .recovery, .traffic]
        return (0..<40).compactMap { index in
            guard let day = calendar.date(
                byAdding: .day,
                value: -(index / 10),
                to: baseDate
            ), let timestamp = calendar.date(
                byAdding: .minute,
                value: -(index % 10) * 17,
                to: day
            ), let id = UUID(
                uuidString: String(
                    format: "00000000-0000-4000-8000-%012d",
                    index + 1
                )
            ) else { return nil }
            let detail = index.isMultiple(of: 9)
                ? "A deliberately long diagnostic fixture message that verifies wrapping without truncating important troubleshooting details."
                : "Diagnostic fixture entry \(index + 1)"
            return UserLogEntry(
                id: id,
                timestamp: timestamp,
                level: levels[index % levels.count],
                module: modules[index % modules.count],
                message: detail
            )
        }
    }
    #endif
}

struct DiagnosticsScrollBounceConfigurator: UIViewRepresentable {
    func makeCoordinator() -> DiagnosticsScrollBounceCoordinator {
        DiagnosticsScrollBounceCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let marker = UIView(frame: .zero)
        marker.backgroundColor = .clear
        marker.isUserInteractionEnabled = false
        context.coordinator.scheduleConfiguration(from: marker)
        return marker
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.scheduleConfiguration(from: uiView)
    }

    static func dismantleUIView(
        _ uiView: UIView,
        coordinator: DiagnosticsScrollBounceCoordinator
    ) {
        coordinator.restore()
    }
}

@MainActor
final class DiagnosticsScrollBounceCoordinator {
    private(set) weak var configuredScrollView: UIScrollView?
    private var originalBounces: Bool?
    private var isActive = true

    func scheduleConfiguration(from marker: UIView, attempt: Int = 0) {
        Task { @MainActor [weak self, weak marker] in
            await Task.yield()
            guard let self, let marker, self.isActive else { return }
            if let scrollView = self.findScrollView(for: marker) {
                self.configure(scrollView)
            } else if attempt < 8 {
                self.scheduleConfiguration(from: marker, attempt: attempt + 1)
            }
        }
    }

    func configure(_ scrollView: UIScrollView) {
        guard isActive else { return }
        if configuredScrollView !== scrollView {
            restoreCurrentScrollView()
            configuredScrollView = scrollView
            originalBounces = scrollView.bounces
        }
        scrollView.bounces = false
    }

    func restore() {
        isActive = false
        restoreCurrentScrollView()
    }

    private func restoreCurrentScrollView() {
        if let scrollView = configuredScrollView, let originalBounces {
            scrollView.bounces = originalBounces
        }
        configuredScrollView = nil
        originalBounces = nil
    }

    private func findScrollView(for marker: UIView) -> UIScrollView? {
        var ancestor = marker.superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }

        guard let window = marker.window else { return nil }
        let markerPoint = marker.convert(
            CGPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: window
        )
        return visibleScrollViews(in: window)
            .filter { scrollView in
                scrollView.convert(scrollView.bounds, to: window).contains(markerPoint)
            }
            .min { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
    }

    private func visibleScrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let scrollView = view as? UIScrollView,
           !scrollView.isHidden,
           scrollView.alpha > 0 {
            result.append(scrollView)
        }
        for child in view.subviews {
            result.append(contentsOf: visibleScrollViews(in: child))
        }
        return result
    }
}

struct DiagnosticsLogView: View {
    @EnvironmentObject private var brand: BrandProvider
    @EnvironmentObject private var modalPresenter: GlobalModalPresenter
    @State private var entries: [UserLogEntry] = []
    @State private var exportText = ""

    private var sections: [DiagnosticsLogSection] {
        DiagnosticsLogPresentation.sections(from: entries)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    LocalizedStringKey("diagnostics.empty"),
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                logRow(entry)
                                    .listRowInsets(EdgeInsets(
                                        top: DiagnosticsLogPresentation.rowVerticalInset,
                                        leading: DiagnosticsLogPresentation.rowHorizontalInset,
                                        bottom: DiagnosticsLogPresentation.rowVerticalInset,
                                        trailing: DiagnosticsLogPresentation.rowHorizontalInset
                                    ))
                            }
                        } header: {
                            Text(section.day, format: .dateTime.month(.wide).day())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(brand.theme.secondary)
                                .textCase(nil)
                                .accessibilityIdentifier(
                                    "diagnostics.section.\(Int(section.day.timeIntervalSince1970))"
                                )
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(DiagnosticsScrollBounceConfigurator())
                .accessibilityIdentifier("diagnostics.list")
            }
        }
        .scrollContentBackground(.hidden)
        .background(brand.theme.background)
        .navigationTitle(LocalizedStringKey("diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: DiagnosticsLogPresentation.titleSpacing) {
                    Image(systemName: AboutSupportItem.diagnostics.systemImage)
                        .font(.system(
                            size: DiagnosticsLogPresentation.titleIconSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(brand.theme.emphasis)
                        .accessibilityIdentifier("diagnostics.title.icon")
                    Text(LocalizedStringKey("diagnostics.title"))
                        .font(.headline)
                        .foregroundStyle(brand.theme.text)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(exportText.isEmpty)
                .accessibilityLabel(LocalizedStringKey("diagnostics.export"))
                .accessibilityIdentifier("diagnostics.export")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    Task {
                        let choice = await modalPresenter.present(
                            DiagnosticsLogClearPresentation.request()
                        )
                        guard DiagnosticsLogClearPresentation.shouldClear(for: choice) else {
                            return
                        }
                        do {
                            try await UserSystemLogger.shared.clear()
                        } catch {
                            _ = await modalPresenter.present(
                                DiagnosticsLogClearPresentation.failureRequest()
                            )
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(entries.isEmpty)
                .accessibilityLabel(LocalizedStringKey("diagnostics.clear"))
                .accessibilityIdentifier("diagnostics.clear")
            }
        }
        .task {
            #if DEBUG
            if DiagnosticsLogPresentation.usesLongListFixture() {
                let fixture = DiagnosticsLogPresentation.longListFixture()
                entries = fixture
                exportText = fixture.map(\.message).joined(separator: "\n")
                return
            }
            #endif
            let stream = await UserSystemLogger.shared.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                entries = snapshot
                exportText = await UserSystemLogger.shared.exportText()
            }
        }
    }

    private func logRow(_ entry: UserLogEntry) -> some View {
        VStack(
            alignment: .leading,
            spacing: DiagnosticsLogPresentation.rowContentSpacing
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    timeLabel(entry)
                    moduleLabel(entry)
                    Spacer(minLength: 8)
                    levelLabel(entry.level)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        timeLabel(entry)
                        Spacer(minLength: 8)
                        levelLabel(entry.level)
                    }
                    moduleLabel(entry)
                }
                VStack(alignment: .leading, spacing: 3) {
                    timeLabel(entry)
                    moduleLabel(entry)
                    levelLabel(entry.level)
                }
            }

            Text(verbatim: entry.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("diagnostics.row.\(entry.id.uuidString).message")
        }
        .padding(.vertical, DiagnosticsLogPresentation.rowVerticalPadding)
    }

    private func timeLabel(_ entry: UserLogEntry) -> some View {
        Text(entry.timestamp, format: .dateTime.hour().minute().second())
            .font(.caption)
            .foregroundStyle(brand.theme.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func moduleLabel(_ entry: UserLogEntry) -> some View {
        Text(LocalizedStringKey(entry.module.userTitleKey))
            .font(.caption.weight(.semibold))
            .foregroundStyle(brand.theme.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func levelLabel(_ level: UserLogLevel) -> some View {
        let color = levelColor(level)
        return Text(LocalizedStringKey(level.userTitleKey))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, DiagnosticsLogPresentation.levelHorizontalPadding)
            .padding(.vertical, DiagnosticsLogPresentation.levelVerticalPadding)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("diagnostics.level.\(level.rawValue)")
    }

    private func levelColor(_ level: UserLogLevel) -> Color {
        switch level {
        case .error: brand.theme.error
        case .warning: brand.theme.warning
        case .success: brand.theme.color("success")
        case .info: brand.theme.secondary
        }
    }
}

extension UserLogLevel {
    var userTitleKey: String { "diagnostics.level.\(rawValue)" }
}

extension UserLogModule {
    var userTitleKey: String { "diagnostics.module.\(rawValue.lowercased())" }
}

enum SettingsLinks {
    static func externalURL(_ value: String?) -> URL? {
        AboutSupportExternalLinkValidator.httpsURL(value)
    }

    static func communityURL(_ value: String?) -> URL? {
        externalURL(value)
    }
}
