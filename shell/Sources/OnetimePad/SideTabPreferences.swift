import Foundation

struct SideTabPreferences: Codable, Equatable {
    var enabled = false
    var displayID: String?
    var edge: SideTabEdge = .right
    var position = 0.5

    static let defaultsKey = "ambientSideTab"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
