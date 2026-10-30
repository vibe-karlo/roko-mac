import Foundation

/// The version and build this copy of roko is, from its Info.plist: for
/// Settings › About and the feedback mail.
enum AppVersion {
    nonisolated static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    nonisolated static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }
}
