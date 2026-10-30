import SwiftUI

// roko on iPhone's to-dos and shopping lists, each as a page of its own
// (roko://todos, roko://shopping), opened from ⌘T ("to-dos", "shopping") and
// kept the same as the iPhone's through roko's server (RokoSpace).

/// The column the lists are read in.
private let column: CGFloat = 600

// MARK: - To-dos

struct TodosPage: View {
    @ObservedObject var space = RokoSpace.shared
    @State private var typed = ""

    private var today: String { SpaceDay.string(0) }
    private var tomorrow: String { SpaceDay.string(1) }

    private var sections: [(String, [SpaceThing])] {
        let open = space.todos.filter { !$0.bool("done") }.sorted(by: Self.byTime)
        let today = today, tomorrow = tomorrow
        func day(_ todo: SpaceThing) -> String? { todo.string("day") }
        return [
            ("Overdue", open.filter { day($0).map { $0 < today } ?? false }),
            ("Today", open.filter { day($0) == today && !$0.bool("week") }),
            ("Tomorrow", open.filter { day($0) == tomorrow && !$0.bool("week") }),
            ("This week", open.filter { $0.bool("week") && (day($0).map { $0 >= today } ?? false) }),
            ("Later", open.filter { (day($0).map { $0 > tomorrow } ?? false) && !$0.bool("week") }),
            ("Someday", open.filter { day($0) == nil }),
            ("Done today", space.todos.filter { $0.bool("done") && SpaceDay.string(of: $0.number("doneAt")) == today }),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        ListPage(title: "To-dos", space: space) {
            VStack(alignment: .leading, spacing: 28) {
                field
                if space.loaded, sections.isEmpty {
                    Text("Nothing to do. Type above to add a to-do.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(sections, id: \.0) { title, todos in
                    VStack(alignment: .leading, spacing: 2) {
                        Heading(title)
                        ForEach(todos) { todo in TodoRow(todo: todo, today: today, space: space) }
                    }
                }
            }
        }
    }

    private var field: some View {
        AddField(prompt: "Add a to-do: call the dentist tomorrow at 15", text: $typed, hint: hint) {
            guard let data = TodoWords.parse(typed) else { return }
            space.put("todo", id: RokoSpace.newID(), data: data)
            typed = ""
        }
    }

    /// When the typed one is for, before it is added.
    private var hint: String? {
        guard let data = TodoWords.parse(typed) else { return nil }
        let day = (data["day"] as? String).map { $0 == today ? "Today" : $0 == tomorrow ? "Tomorrow" : SpaceDay.short($0) } ?? "Someday"
        return [day, data["time"] as? String].compactMap { $0 }.joined(separator: " at ")
    }

    static func byTime(_ a: SpaceThing, _ b: SpaceThing) -> Bool {
        let at = a.string("time") ?? "99", bt = b.string("time") ?? "99"
        if at != bt { return at < bt }
        if a.number("order") != b.number("order") { return (a.number("order") ?? 0) < (b.number("order") ?? 0) }
        return (a.number("created") ?? 0) < (b.number("created") ?? 0)
    }
}

private struct TodoRow: View {
    let todo: SpaceThing
    let today: String
    @ObservedObject var space: RokoSpace

    private var done: Bool { todo.bool("done") }

    var body: some View {
        Row(done: done, title: todo.string("title") ?? "", detail: detail, toggle: toggle,
            delete: { space.remove("todo", id: todo.id) })
        .contextMenu {
            Button("Today") { move(SpaceDay.string(0)) }
            Button("Tomorrow") { move(SpaceDay.string(1)) }
            Button("Someday") { move(nil) }
            Divider()
            Button("Delete", role: .destructive) { space.remove("todo", id: todo.id) }
        }
    }

    /// Its time, and the day it was for when that has gone by.
    private var detail: String? {
        guard !done else { return nil }
        var parts: [String] = []
        if let day = todo.string("day"), day < today { parts.append(SpaceDay.short(day)) }
        if let time = todo.string("time") { parts.append(time) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private func toggle() {
        var data = todo.data
        data["done"] = !done
        data["doneAt"] = done ? NSNull() : RokoSpace.now
        space.put("todo", id: todo.id, data: data)
    }

    private func move(_ day: String?) {
        var data = todo.data
        data["day"] = day ?? NSNull()
        data["week"] = false
        if day == nil { data["time"] = NSNull() }
        space.put("todo", id: todo.id, data: data)
    }
}

// MARK: - Shopping

struct ShoppingPage: View {
    @ObservedObject var space = RokoSpace.shared
    @State private var typed = ""
    @State private var shop = "grocery"

    private var onList: [SpaceThing] { space.shopping.filter { ShoppingWords.shop(of: $0) == shop } }

    /// The open things, aisle by aisle in the order a shop is walked; the
    /// ones not yet given an aisle (added here, sorted on the iPhone) last.
    private var aisles: [(String, [SpaceThing])] {
        let open = onList.filter { !$0.bool("done") }
            .sorted { ($0.number("order") ?? $0.number("created") ?? 0) < ($1.number("order") ?? $1.number("created") ?? 0) }
        var groups = ShoppingWords.aisles.compactMap { aisle -> (String, [SpaceThing])? in
            let items = open.filter { $0.string("aisle") == aisle.id }
            return items.isEmpty ? nil : (aisle.name, items)
        }
        let known = Set(ShoppingWords.aisles.map(\.id))
        let unsorted = open.filter { !known.contains($0.string("aisle") ?? "") }
        if !unsorted.isEmpty { groups.append((ShoppingWords.aisleName(nil), unsorted)) }
        return groups
    }

    private var basket: [SpaceThing] { onList.filter { $0.bool("done") } }

    var body: some View {
        ListPage(title: "Shopping", space: space) {
            VStack(alignment: .leading, spacing: 28) {
                shops
                AddField(prompt: "Add: milk, eggs and bread", text: $typed, hint: nil, submit: add)
                if space.loaded, aisles.isEmpty, basket.isEmpty {
                    Text("Nothing on this list.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(aisles, id: \.0) { name, items in
                    VStack(alignment: .leading, spacing: 2) {
                        Heading(name)
                        ForEach(items) { item in ItemRow(item: item, space: space) }
                    }
                }
                if !basket.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Heading("In the basket")
                            Spacer()
                            Button {
                                for item in basket { space.remove("shopping", id: item.id) }
                            } label: {
                                Text("Clear")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.secondaryInk)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(RowButtonStyle())
                            .help("Take what's in the basket off the list")
                        }
                        ForEach(basket) { item in ItemRow(item: item, space: space) }
                    }
                }
            }
        }
    }

    /// The three lists, as words: the one showing in ink, the others quieter,
    /// each with how much is still to buy on it.
    private var shops: some View {
        HStack(spacing: 22) {
            ForEach(ShoppingWords.shops, id: \.id) { entry in
                let count = space.shopping.filter { ShoppingWords.shop(of: $0) == entry.id && !$0.bool("done") }.count
                Button { shop = entry.id } label: {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 14, weight: shop == entry.id ? .semibold : .regular))
                            .foregroundStyle(shop == entry.id ? Theme.ink : Theme.secondaryInk)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.faintInk)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Things typed, onto this list; ones already on it are left.
    private func add() {
        var open = Set(space.shopping.filter { !$0.bool("done") }.map { ShoppingWords.key($0.string("title") ?? "") })
        var fresh: [(id: String, data: [String: Any])] = []
        for title in ShoppingWords.split(typed) {
            let key = ShoppingWords.key(title)
            guard !key.isEmpty, !open.contains(key) else { continue }
            open.insert(key)
            // Groceries: left for the iPhone to put where its aisle is bought.
            fresh.append((RokoSpace.newID(), ["title": title, "pinned": shop == "grocery" ? "" : shop, "created": RokoSpace.now]))
        }
        space.put("shopping", fresh)
        typed = ""
    }
}

private struct ItemRow: View {
    let item: SpaceThing
    @ObservedObject var space: RokoSpace

    var body: some View {
        Row(done: item.bool("done"), title: item.string("title") ?? "", detail: nil, toggle: toggle,
            delete: { space.remove("shopping", id: item.id) })
        .contextMenu {
            ForEach(ShoppingWords.shops, id: \.id) { entry in
                Button("Move to \(entry.name)") {
                    var data = item.data
                    data["pinned"] = entry.id
                    space.put("shopping", id: item.id, data: data)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { space.remove("shopping", id: item.id) }
        }
    }

    private func toggle() {
        var data = item.data
        let done = item.bool("done")
        data["done"] = !done
        data["doneAt"] = done ? NSNull() : RokoSpace.now
        space.put("shopping", id: item.id, data: data)
    }
}

// MARK: - Shared

/// A list's page: its title, then either the list or how to connect it.
private struct ListPage<Content: View>: View {
    let title: String
    @ObservedObject var space: RokoSpace
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if space.connected, let problem = space.problem {
                        Text(problem)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                }
                let _ = space.keyRevision
                if space.connected { content() } else { SyncSetup(space: space) }
            }
            .frame(maxWidth: column, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .onAppear { space.watch() }
        .onDisappear { space.unwatch() }
    }
}

// MARK: - Read Later

/// roko://later: the pages put aside (ReadLater), unread first. A click
/// opens one in a tab of its own and marks it read.
struct ReadLaterPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var later = ReadLater.shared
    @ObservedObject var space = RokoSpace.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Read Later")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if space.connected, let problem = space.problem {
                        Text(problem)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                }
                if later.pages.isEmpty {
                    Text("Nothing put aside. ⇧⌘L saves the page you're on for later.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryInk)
                }
                section("Unread", later.pages.filter { !$0.isRead })
                section("Read", later.pages.filter(\.isRead))
                let _ = space.keyRevision
                if !space.connected {
                    VStack(alignment: .leading, spacing: 4) {
                        Heading("On your iPhone too")
                        SyncSetup(space: space)
                    }
                }
            }
            .frame(maxWidth: column, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 48)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .onAppear { space.watch() }
        .onDisappear { space.unwatch() }
    }

    @ViewBuilder private func section(_ title: String, _ pages: [LaterPage]) -> some View {
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Heading(title)
                ForEach(pages) { page in
                    LaterRow(page: page, open: { browser.open(page.url, foreground: true) },
                             remove: { later.remove(page.id) })
                }
            }
        }
    }
}

private struct LaterRow: View {
    let page: LaterPage
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            picture
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.system(size: 14, weight: page.isRead ? .regular : .medium))
                    .foregroundStyle(page.isRead ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(2)
                Text("\(page.site)  ·  \(page.savedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faintInk)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from Read Later")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.edge : .clear))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .help(page.url.absoluteString)
        .contextMenu {
            Button("Open") { open() }
            Button(page.isRead ? "Mark as Unread" : "Mark as Read") { ReadLater.shared.markRead(page.id, !page.isRead) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CleanLink.clean(page.url).absoluteString, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) { remove() }
        }
    }

    /// The page's share picture; without one, the site's own icon, bare,
    /// in the same place so the titles line up.
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack {
            if let image = page.image {
                AsyncImage(url: image) { phase in
                    if let picture = phase.image {
                        picture.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        icon
                    }
                }
                .clipShape(shape)
                .opacity(page.isRead ? 0.6 : 1)
            } else {
                icon
            }
        }
        .frame(width: 72, height: 48)
    }

    @ViewBuilder private var icon: some View {
        if let favicon = Favicons.shared.cached(for: page.url) {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Text(String(page.site.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.faintInk)
        }
    }
}

/// Before there is a key: what this is, and where the iPhone's key is.
struct SyncSetup: View {
    @ObservedObject var space: RokoSpace
    @State private var key = ""
    @State private var joining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your to-dos, shopping lists and Read Later from roko on iPhone, kept the same here. On your iPhone, open roko › Settings › Mac sync and tap Copy Key, then paste it here.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.bodyInk)
                .fixedSize(horizontal: false, vertical: true)
            AddField(prompt: "Paste the key from your iPhone", text: $key, hint: nil, secure: true) { connect() }
            if let problem = space.problem {
                Text(problem)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if joining {
                Text("Connecting…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func connect() {
        guard !joining else { return }
        joining = true
        Task {
            if await space.join(key) { key = "" }
            joining = false
        }
    }
}

/// The field a list is added to from: Return adds.
private struct AddField: View {
    let prompt: String
    @Binding var text: String
    let hint: String?
    var secure = false
    let submit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: secure ? "key" : "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faintInk))
                } else {
                    TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faintInk))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink)
            .onSubmit(submit)
            if let hint, !text.isEmpty {
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.raised, in: shape)
        .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
    }
}

/// A section's word, above its rows.
private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondaryInk)
            .padding(.bottom, 4)
    }
}

/// One thing on a list: its circle, its words, what else it says, and on
/// hover a way to delete it.
private struct Row: View {
    let done: Bool
    let title: String
    let detail: String?
    let toggle: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(done ? Theme.faintInk : Theme.secondaryInk)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done ? "Not done" : "Done")
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(done ? Theme.faintInk : Theme.ink)
                .strikethrough(done, color: Theme.faintInk)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
            Button(action: delete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faintInk)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.edge : .clear))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
