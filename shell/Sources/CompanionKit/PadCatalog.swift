import Foundation
import Combine

public enum PadSortDirection: String, Codable, Sendable {
    case chronological, reverseChronological
    public var reversed: Self { self == .chronological ? .reverseChronological : .chronological }
}

public struct PadEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var folderPaths: [String]
    public var applicationBundleIDs: [String]
    public var isScratch: Bool
}

/// Experimental local navigation metadata. It is deliberately separate from
/// encrypted note content. Names and paths in this catalog are NOT encrypted.
@MainActor
public final class PadCatalog: ObservableObject {
    public static let scratchID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let storageKey = "experimentalPadCatalogV1"
    @Published public var isEnabled: Bool { didSet {
        if loadFailure != nil && isEnabled { isEnabled = false }
        changed()
    } }
    @Published public var appAssociationsEnabled: Bool { didSet { changed() } }
    @Published public var showFullPaths: Bool { didSet { changed() } }
    @Published public private(set) var entries: [PadEntry]
    @Published public private(set) var activeID: UUID
    public private(set) var loadFailure: String?
    public var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private var tabOwners: [String: UUID]
    private var fileOwners: [String: UUID]
    private var lastUsed: [UUID: Double]
    private var daySort: [UUID: PadSortDirection]
    private var checkpointSort: [String: PadSortDirection]
    private var rememberedTabs: [UUID: String]

    private struct State: Codable {
        var version: Int = 1
        var enabled: Bool
        var appAssociationsEnabled: Bool
        var showFullPaths: Bool
        var entries: [PadEntry]
        var activeID: UUID
        var tabOwners: [String: UUID]
        var fileOwners: [String: UUID]
        var lastUsed: [UUID: Double]
        var daySort: [UUID: PadSortDirection]
        var checkpointSort: [String: PadSortDirection]
        var rememberedTabs: [UUID: String]
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let raw = defaults.data(forKey: Self.storageKey)
        let state = raw.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let valid = state.map { candidate in
            candidate.version == 1 && candidate.entries.first?.id == Self.scratchID
                && candidate.entries.first?.isScratch == true
                && Set(candidate.entries.map(\.id)).count == candidate.entries.count
                && candidate.entries.contains { $0.id == candidate.activeID }
                && candidate.entries.filter(\.isScratch).count == 1
                && candidate.entries.first?.folderPaths.isEmpty == true
                && candidate.entries.flatMap(\.folderPaths).allSatisfy { $0.hasPrefix("/") && Self.normalizedPath($0) == $0 }
                && (Array(candidate.tabOwners.values) + Array(candidate.fileOwners.values)).allSatisfy { owner in candidate.entries.contains { $0.id == owner } }
                && Set(candidate.entries.flatMap(\.folderPaths)).count
                    == candidate.entries.flatMap(\.folderPaths).count
        } ?? false
        let loaded = valid ? state : nil
        isEnabled = loaded?.enabled ?? false
        appAssociationsEnabled = loaded?.appAssociationsEnabled ?? false
        showFullPaths = loaded?.showFullPaths ?? false
        entries = loaded?.entries ?? [PadEntry(id: Self.scratchID, name: "Scratch",
            folderPaths: [], applicationBundleIDs: [], isScratch: true)]
        activeID = loaded?.activeID ?? Self.scratchID
        tabOwners = loaded?.tabOwners ?? [:]
        fileOwners = loaded?.fileOwners ?? [:]
        lastUsed = loaded?.lastUsed ?? [:]
        daySort = loaded?.daySort ?? [:]
        checkpointSort = loaded?.checkpointSort ?? [:]
        rememberedTabs = loaded?.rememberedTabs ?? [:]
        if raw != nil && !valid {
            loadFailure = "Pad metadata could not be read. The saved catalog has been preserved."
        }
    }

    public var activePad: PadEntry { entries.first { $0.id == activeID } ?? entries[0] }
    private func changed() {
        // A corrupt or newer catalog is never replaced by an empty one.
        if loadFailure == nil {
            let state = State(enabled: isEnabled, appAssociationsEnabled: appAssociationsEnabled,
                showFullPaths: showFullPaths, entries: entries, activeID: activeID,
                tabOwners: tabOwners, fileOwners: fileOwners, lastUsed: lastUsed,
                daySort: daySort, checkpointSort: checkpointSort, rememberedTabs: rememberedTabs)
            if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.storageKey) }
        }
        onChange?()
    }

    @discardableResult
    public func create(named name: String) -> UUID? {
        guard loadFailure == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUIDv7.generate()
        entries.append(PadEntry(id: id, name: String(trimmed.prefix(80)), folderPaths: [],
            applicationBundleIDs: [], isScratch: false))
        activate(id)
        return id
    }
    public func activate(_ id: UUID, recordRecency: Bool = true) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        activeID = id
        if recordRecency { lastUsed[id] = Date().timeIntervalSince1970 }
        changed()
    }
    public func owner(ofTabUUID uuid: String?) -> UUID {
        uuid.flatMap { tabOwners[$0] }.flatMap { owner in
            entries.contains { $0.id == owner } ? owner : nil
        } ?? Self.scratchID
    }
    public func assign(tabUUID: String, to id: UUID) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        tabOwners[tabUUID] = id
        changed()
    }
    public func remember(tabUUID: String?, for id: UUID) {
        guard loadFailure == nil else { return }
        rememberedTabs[id] = tabUUID
        changed()
    }
    public func rememberedTab(for id: UUID) -> String? { rememberedTabs[id] }
    public func owner(ofFile path: String) -> UUID {
        fileOwners[Self.normalizedPath(path)].flatMap { owner in
            entries.contains { $0.id == owner } ? owner : nil
        } ?? Self.scratchID
    }
    public func assign(filePath: String, to id: UUID) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        fileOwners[Self.normalizedPath(filePath)] = id
        changed()
    }
    func transferFiles(_ changes: [(String, String)]) {
        guard loadFailure == nil, !changes.isEmpty else { return }
        let moves = changes.map { (Self.normalizedPath($0.0), Self.normalizedPath($0.1), owner(ofFile: $0.0)) }
        for move in moves { fileOwners.removeValue(forKey: move.0) }
        for move in moves { fileOwners[move.1] = move.2 }
        changed()
    }
    @discardableResult
    public func addFolder(_ path: String, to id: UUID) -> Bool {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isScratch else { return false }
        let path = Self.normalizedPath(path)
        guard path.hasPrefix("/"), !entries.contains(where: { $0.folderPaths.contains(path) }) else { return false }
        entries[index].folderPaths.append(path)
        changed()
        return true
    }
    public func removeFolder(_ path: String, from id: UUID) {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].folderPaths.removeAll { $0 == path }
        changed()
    }
    /// Uses only the URL supplied by an explicit operation, without filesystem
    /// inspection. The longest component-boundary match wins nested roots.
    public func pad(forPath path: String) -> UUID? {
        let path = Self.normalizedPath(path)
        var match: UUID?
        var longest = -1
        for entry in entries {
            for root in entry.folderPaths {
                let prefix = root == "/" ? "/" : root + "/"
                if (path == root || path.hasPrefix(prefix)) && root.count > longest {
                    match = entry.id
                    longest = root.count
                }
            }
        }
        return match
    }
    public static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    public func addApplication(_ bundleID: String, to id: UUID) {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }), !bundleID.isEmpty,
            !entries[index].applicationBundleIDs.contains(bundleID) else { return }
        entries[index].applicationBundleIDs.append(bundleID)
        changed()
    }
    public func removeApplication(_ bundleID: String, from id: UUID) {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].applicationBundleIDs.removeAll { $0 == bundleID }
        changed()
    }
    public func pad(forApplication bundleID: String) -> UUID? {
        guard isEnabled, appAssociationsEnabled else { return nil }
        let recent = Set(lastUsed.sorted { $0.value > $1.value }.prefix(9).map(\.key))
        return entries.enumerated().filter {
            (recent.contains($0.element.id) || $0.element.id == activeID)
                && $0.element.applicationBundleIDs.contains(bundleID)
        }
            .max { lhs, rhs in
                let a = lastUsed[lhs.element.id] ?? 0, b = lastUsed[rhs.element.id] ?? 0
                return a == b ? lhs.offset > rhs.offset : a < b
            }?.element.id
    }
    public func daySortDirection(for id: UUID) -> PadSortDirection { daySort[id] ?? .reverseChronological }
    public func checkpointSortDirection(for id: UUID, onDate date: String) -> PadSortDirection {
        checkpointSort[id.uuidString + "/" + date] ?? .chronological
    }
    public func toggleDaySort(for id: UUID) {
        guard loadFailure == nil else { return }
        daySort[id] = daySortDirection(for: id).reversed
        changed()
    }
    public func toggleCheckpointSort(for id: UUID, onDate date: String) {
        guard loadFailure == nil else { return }
        checkpointSort[id.uuidString + "/" + date] = checkpointSortDirection(for: id, onDate: date).reversed
        changed()
    }
}
