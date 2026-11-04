import Foundation

struct SideTabPreferences: Codable, Equatable {
    var enabled = false
    var displayID: String?
    var edge: SideTabEdge = .right
    var position = 0.5

    static let defaultsKey = "ambientSideTab"

    var normalizedPosition: Double {
        position.isFinite ? min(1, max(0, position)) : 0.5
    }

    var normalized: Self {
        var value = self
        value.position = normalizedPosition
        return value
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
