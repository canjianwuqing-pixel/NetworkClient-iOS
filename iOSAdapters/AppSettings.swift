import SwiftUI
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var language: String { didSet { defaults.set(language, forKey: "ios.language") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "ios.appearance") } }
    @Published var mode: ProxyMode { didSet { defaults.set(mode.rawValue, forKey: "ios.mode") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: "ios.language") ?? "zh-Hans"
        appearance = defaults.string(forKey: "ios.appearance") ?? "system"
        mode = ProxyMode(rawValue: defaults.string(forKey: "ios.mode") ?? "") ?? .rule
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
}
