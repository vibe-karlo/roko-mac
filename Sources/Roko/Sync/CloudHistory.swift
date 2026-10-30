import Foundation
import SwiftData

// History shared with roko on iPhone through iCloud: the same records in the
// same container (iCloud.com.growthstudio.roko), a SwiftData store mirrored
// to the private database of the person signed in, as the iPhone keeps its
// own (Models/Store.swift and Records.swift there). The Mac's history stays
// what it is (History.swift, its own file); this keeps the two in step:
// a visit here is written to the shared store, and what comes in from the
// iPhone is taken into the Mac's history, counted as it was counted there.
//
// Only in a build signed with the iCloud entitlements (ICLOUD_SYNC, set by
// build.sh when roko.icloud.provisionprofile is beside it): without them
// CloudKit traps rather than failing politely, so there is no sync at all.

/// One address and its visits, exactly as roko on iPhone keeps it: same
/// name, same fields, same defaults, so the records in iCloud are the same
/// records on both.
@Model
final class HistoryEntry {
    #Index<HistoryEntry>([\.url], [\.visitedAt])
    var url: String = ""
    var title: String = ""
    var visitedAt: Date = Date.now
    var visitCount: Int = 1

    init(url: URL, title: String) {
        self.url = url.absoluteString
        self.title = title
    }
}

@MainActor
final class CloudHistory {
    static let shared = CloudHistory()
    static let container = "iCloud.com.growthstudio.roko"

    /// Whether this build may sync at all (see the top of this file).
    static var syncs: Bool {
        #if ICLOUD_SYNC
        !Store.testing
        #else
        false
        #endif
    }

    private var store: ModelContainer?
    private weak var history: History?
    /// When the shared store was last read into the Mac's history.
    private var mergedUpTo: Date {
        get { Store.settings.object(forKey: "cloud.history.merged") as? Date ?? .distantPast }
        set { Store.settings.set(newValue, forKey: "cloud.history.merged") }
    }
    private var observer: NSObjectProtocol?

    private init() {}

    /// At launch, with the window's history: opens the shared store and
    /// takes in what the iPhone has written, then again whenever iCloud
    /// brings more.
    func start(with history: History) {
        guard Self.syncs, store == nil else { return }
        self.history = history
        let folder = Store.folder
        let configuration = ModelConfiguration("Synced", schema: Schema([HistoryEntry.self]),
                                               url: folder.appending(path: "synced.store"),
                                               cloudKitDatabase: .private(Self.container))
        do {
            store = try ModelContainer(for: HistoryEntry.self, configurations: configuration)
        } catch {
            NSLog("roko: iCloud history unavailable: \(error)")
            return
        }
        // CloudKit's imports land in the store from outside: told so, the
        // newer entries are taken in.
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeIn() }
        }
        takeIn()
    }

    /// A visit here, into the shared store: the address's entry counted up,
    /// or a new one.
    func recorded(_ url: URL, title: String) {
        guard let context = store?.mainContext else { return }
        let address = url.absoluteString
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.url == address })
        descriptor.fetchLimit = 1
        if let entry = try? context.fetch(descriptor).first {
            entry.visitCount += 1
            entry.visitedAt = .now
            if !title.isEmpty { entry.title = title }
        } else {
            context.insert(HistoryEntry(url: url, title: title))
        }
        try? context.save()
    }

    /// What the iPhone wrote since the last look, into the Mac's history.
    private func takeIn() {
        guard let context = store?.mainContext, let history else { return }
        // A little before the last look as well: iCloud brings records in
        // the order it likes, so one written earlier can land after a later
        // one was taken. Taking an entry twice is harmless (History.take
        // keeps the larger count).
        let since = mergedUpTo.addingTimeInterval(-2 * 24 * 3600)
        let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.visitedAt > since },
                                                       sortBy: [SortDescriptor(\.visitedAt)])
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return }
        for entry in entries {
            guard let url = URL(string: entry.url) else { continue }
            history.take(url, title: entry.title, count: entry.visitCount, last: entry.visitedAt)
        }
        history.settle()
        if let latest = entries.last?.visitedAt, latest > mergedUpTo { mergedUpTo = latest }
    }

    /// Clear History: from iCloud too, so the iPhone forgets it as well.
    func forget() {
        guard let context = store?.mainContext else { return }
        try? context.delete(model: HistoryEntry.self)
        try? context.save()
    }
}
