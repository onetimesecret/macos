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
    /// Experimental app hints consider nine manually visited pads, independently
    /// of the nine numbered named-pad shortcuts. The policy remains provisional.
    static let recentPadLimit = 9
    @Published public var isEnabled: Bool { didSet {
        if loadFailure != nil && isEnabled { isEnabled = false }
        if oldValue != isEnabled { changed() }
    } }
    @Published public var appAssociationsEnabled: Bool { didSet { if oldValue != appAssociationsEnabled { changed() } } }
    @Published public var showFullPaths: Bool { didSet { if oldValue != showFullPaths { changed() } } }
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
    private var rememberedFiles: [UUID: String]

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
        var rememberedFiles: [UUID: String]? = nil
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
        rememberedFiles = loaded?.rememberedFiles ?? [:]
        if raw != nil && !valid {
            loadFailure = CompanionL10n.string("pad.catalog.unreadable")
        }
    }

    public var activePad: PadEntry { entries.first { $0.id == activeID } ?? entries[0] }
    private func changed() {
        // A corrupt or newer catalog is never replaced by an empty one.
        if loadFailure == nil {
            let state = State(enabled: isEnabled, appAssociationsEnabled: appAssociationsEnabled,
                showFullPaths: showFullPaths, entries: entries, activeID: activeID,
                tabOwners: tabOwners, fileOwners: fileOwners, lastUsed: lastUsed,
                daySort: daySort, checkpointSort: checkpointSort, rememberedTabs: rememberedTabs, rememberedFiles: rememberedFiles)
            if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.storageKey) }
        }
        onChange?()
    }

    @discardableResult
    public func create(named name: String) -> UUID? {
        guard loadFailure == nil else { return nil }
        guard let trimmed = Self.validatedName(name) else { return nil }
        let id = UUIDv7.generate()
        entries.append(PadEntry(id: id, name: trimmed, folderPaths: [],
            applicationBundleIDs: [], isScratch: false))
        activate(id)
        return id
    }
    public func activate(_ id: UUID, recordRecency: Bool = true) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        let ordered = orderedRecency
        let recordsVisit = recordRecency && ordered.first?.key != id
        // A true re-selection of the manual MRU is a no-op. A manual visit to
        // an automatically selected older pad must still promote its recency.
        guard activeID != id || recordsVisit else { return }
        activeID = id
        if recordsVisit {
            let recent = [id] + ordered.map(\.key).filter { $0 != id }.prefix(Self.recentPadLimit - 1)
            // Logical ranks avoid clock rollback and floating-point counter
            // overflow. Existing timestamp values retain their relative order
            // on read and are normalized at the next recorded manual visit.
            lastUsed = Dictionary(uniqueKeysWithValues: recent.enumerated().map {
                ($0.element, Double(recent.count - $0.offset))
            })
        }
        changed()
    }
    public func owner(ofTabUUID uuid: String?) -> UUID {
        uuid.flatMap { tabOwners[$0] }.flatMap { owner in
            entries.contains { $0.id == owner } ? owner : nil
        } ?? Self.scratchID
    }
    public func assign(tabUUID: String, to id: UUID) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        let owner: UUID? = id == Self.scratchID ? nil : id
        guard tabOwners[tabUUID] != owner else { return }
        tabOwners[tabUUID] = owner
        changed()
    }
    public func remember(tabUUID: String?, for id: UUID) {
        rememberSelection(tabUUID: tabUUID, filePath: nil, for: id)
    }
    public func rememberSelection(tabUUID: String?, filePath: String?, for id: UUID) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        let path = filePath.map(Self.normalizedPath)
        guard rememberedTabs[id] != tabUUID || rememberedFiles[id] != path else { return }
        rememberedTabs[id] = tabUUID
        rememberedFiles[id] = path
        changed()
    }
    public func rememberedFile(for id: UUID) -> String? { rememberedFiles[id] }
    public func rememberedTab(for id: UUID) -> String? { rememberedTabs[id] }
    public func owner(ofFile path: String) -> UUID {
        fileOwners[Self.normalizedPath(path)].flatMap { owner in
            entries.contains { $0.id == owner } ? owner : nil
        } ?? Self.scratchID
    }
    public func assign(filePath: String, to id: UUID) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        let path = Self.normalizedPath(filePath)
        let owner: UUID? = id == Self.scratchID ? nil : id
        guard fileOwners[path] != owner else { return }
        fileOwners[path] = owner
        changed()
    }
    func transferFiles(_ changes: [(String, String)]) {
        guard loadFailure == nil, !changes.isEmpty else { return }
        let moves = changes.map { (Self.normalizedPath($0.0), Self.normalizedPath($0.1)) }.filter { $0.0 != $0.1 }
        let before = fileOwners
        let oldRemembered = rememberedFiles
        let owners = moves.compactMap { old, new in fileOwners[old].map { (new, $0) } }
        for (old, _) in moves { fileOwners.removeValue(forKey: old) }
        for (new, owner) in owners { fileOwners[new] = owner }
        for (pad, path) in rememberedFiles {
            if let move = moves.first(where: { $0.0 == path }) { rememberedFiles[pad] = move.1 }
        }
        if before != fileOwners || oldRemembered != rememberedFiles { changed() }
    }
    @discardableResult
    public func addFolder(_ path: String, to id: UUID) -> Bool {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isScratch else { return false }
        let path = Self.normalizedPath(path)
        guard path.hasPrefix("/"), !entries.contains(where: { $0.folderPaths.contains { Self.sameDirectory($0, path) } }) else { return false }
        entries[index].folderPaths.append(path)
        changed()
        return true
    }
    public func removeFolder(_ path: String, from id: UUID) {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].folderPaths.contains(path) else { return }
        entries[index].folderPaths.removeAll { $0 == path }
        changed()
    }
    /// Resolves only explicitly supplied paths and stored roots. No directory
    /// enumeration occurs. The longest component-boundary match wins nested roots.
    public func pad(forPath path: String) -> UUID? {
        let path = Self.matchingPath(path)
        var match: UUID?
        var longest = -1
        var ambiguous = false
        for entry in entries {
            for storedRoot in entry.folderPaths {
                let root = Self.matchingPath(storedRoot)
                let prefix = root == "/" ? "/" : root + "/"
                if path == root || path.hasPrefix(prefix) {
                    if root.count > longest {
                        match = entry.id; longest = root.count; ambiguous = false
                    } else if root.count == longest && match != entry.id {
                        // Older catalogs may contain two physical aliases. Keep
                        // their metadata, but do not arbitrarily route between pads.
                        ambiguous = true
                    }
                }
            }
        }
        return ambiguous ? nil : match
    }
    public static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
    /// Physical identity catches symlink and case aliases without treating
    /// distinct directories on case-sensitive volumes as equal. Unavailable
    /// paths retain lexical comparison rather than guessing their identity.
    private static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        if matchingPath(lhs) == matchingPath(rhs) { return true }
        func identity(_ path: String) -> [NSNumber]? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
                let volume = attributes[.systemNumber] as? NSNumber,
                let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return [volume, inode]
        }
        guard let left = identity(lhs), let right = identity(rhs) else { return false }
        return left == right
    }
    private static func matchingPath(_ path: String) -> String {
        // Foundation may leave the whole URL unresolved when its final component
        // does not exist. Resolve the nearest existing prefix, then reattach only
        // the supplied missing components; this never enumerates a directory.
        let supplied = URL(fileURLWithPath: normalizedPath(path))
        var prefix = supplied
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: prefix.path) {
            let parent = prefix.deletingLastPathComponent()
            guard parent.path != prefix.path else { break }
            missing.append(prefix.lastPathComponent)
            prefix = parent
        }
        var url = prefix.resolvingSymlinksInPath()
        for component in missing.reversed() { url.appendPathComponent(component) }
        var ancestor = url
        while true {
            if let sensitivity = try? ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames {
                return sensitivity == false ? url.path.lowercased() : url.path
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { return url.path }
            ancestor = parent
        }
    }
    public func addApplication(_ bundleID: String, to id: UUID) {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }), !bundleID.isEmpty,
            !entries[index].applicationBundleIDs.contains(bundleID) else { return }
        entries[index].applicationBundleIDs.append(bundleID)
        changed()
    }
    public func removeApplication(_ bundleID: String, from id: UUID) {
        guard loadFailure == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].applicationBundleIDs.contains(bundleID) else { return }
        entries[index].applicationBundleIDs.removeAll { $0 == bundleID }
        changed()
    }
    private var orderedRecency: [(key: UUID, value: Double)] {
        let order = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        return lastUsed.filter { order[$0.key] != nil }.sorted {
            $0.value == $1.value ? order[$0.key]! < order[$1.key]! : $0.value > $1.value
        }
    }
    public func pad(forApplication bundleID: String) -> UUID? {
        guard isEnabled, appAssociationsEnabled else { return nil }
        let recent = Set(orderedRecency.prefix(Self.recentPadLimit).map(\.key))
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
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        daySort[id] = daySortDirection(for: id).reversed
        changed()
    }
    public func toggleCheckpointSort(for id: UUID, onDate date: String) {
        guard loadFailure == nil, entries.contains(where: { $0.id == id }) else { return }
        checkpointSort[id.uuidString + "/" + date] = checkpointSortDirection(for: id, onDate: date).reversed
        changed()
    }
    public static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80 ? trimmed : nil
    }
    @discardableResult
    public func rename(_ id: UUID, to name: String) -> Bool {
        guard loadFailure == nil, let name = Self.validatedName(name),
            let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isScratch else { return false }
        if entries[index].name != name { entries[index].name = name; changed() }
        return true
    }
    /// Removes navigation metadata only. Existing content becomes implicit Scratch.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        guard loadFailure == nil, id != Self.scratchID, entries.contains(where: { $0.id == id }) else { return false }
        entries.removeAll { $0.id == id }
        tabOwners = tabOwners.filter { $0.value != id }
        fileOwners = fileOwners.filter { $0.value != id }
        rememberedTabs[id] = nil
        rememberedFiles[id] = nil
        lastUsed[id] = nil
        daySort[id] = nil
        checkpointSort = checkpointSort.filter { !$0.key.hasPrefix(id.uuidString + "/") }
        if activeID == id { activeID = Self.scratchID }
        changed()
        return true
    }
    /// Reconciles against complete live rosters, never the active pad projection.
    /// Empty surviving tabs retain ownership; expired-page date preferences do not.
    func reconcileTabs(_ live: Set<String>, checkpointKeys: Set<String>) {
        guard loadFailure == nil else { return }
        let owners = tabOwners.filter { live.contains($0.key) && $0.value != Self.scratchID }
        let remembered = rememberedTabs.filter { live.contains($0.value) && owner(ofTabUUID: $0.value) == $0.key }
        let sort = checkpointSort.filter { checkpointKeys.contains($0.key) }
        let recency = Dictionary(uniqueKeysWithValues: orderedRecency.prefix(Self.recentPadLimit).map { ($0.key, $0.value) })
        let validPads = Set(entries.map(\.id))
        let days = daySort.filter { validPads.contains($0.key) }
        guard owners != tabOwners || remembered != rememberedTabs || sort != checkpointSort || recency != lastUsed || days != daySort else { return }
        tabOwners = owners; rememberedTabs = remembered; checkpointSort = sort
        lastUsed = recency; daySort = days
        changed()
    }
    func reconcileFiles(_ livePaths: Set<String>) {
        guard loadFailure == nil else { return }
        let live = Set(livePaths.map(Self.normalizedPath))
        let owners = fileOwners.filter { live.contains($0.key) && $0.value != Self.scratchID }
        let remembered = rememberedFiles.filter { live.contains($0.value) && owner(ofFile: $0.value) == $0.key }
        guard owners != fileOwners || remembered != rememberedFiles else { return }
        fileOwners = owners; rememberedFiles = remembered
        changed()
    }

}
