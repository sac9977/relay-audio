import SwiftUI

/// Shared UI text sizing for Relay + Relay Satellite.
///
/// Every font in both apps is created through `AppFont.size(_:)` so a single
/// user-facing setting (compact / comfortable / large) rescales the whole UI.
/// Base values are the "comfortable" sizes; compact is 1.5 pt tighter and
/// large is 2.5 pt bigger.
///
/// The active scale is plain mutable state. Views re-render when their owning
/// @MainActor facade publishes a scale change, and every `body` rebuild reads
/// the current value — no view needs to observe this type directly.
public enum AppFont {
    public enum Scale: String, CaseIterable {
        case compact
        case comfortable
        case large

        public var offset: CGFloat {
            switch self {
            case .compact: return -1.5
            case .comfortable: return 0
            case .large: return 2.5
            }
        }

        public var label: String {
            switch self {
            case .compact: return "Compact"
            case .comfortable: return "Comfortable"
            case .large: return "Large"
            }
        }
    }

    /// Not thread-isolated by design: UI facades set this on the main actor
    /// before any view reads it.
    public nonisolated(unsafe) static var scale: Scale = .comfortable

    /// Builds a Font at the active scale. `base` is the comfortable size.
    public static func size(_ base: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: max(9, base + scale.offset), weight: weight, design: design)
    }

    /// Loads a persisted scale (per-app defaults) and activates it.
    public static func activate(defaultsKey: String) {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
        scale = Scale(rawValue: raw ?? "") ?? .comfortable
    }

    public static func persist(_ newScale: Scale, defaultsKey: String) {
        scale = newScale
        UserDefaults.standard.set(newScale.rawValue, forKey: defaultsKey)
    }
}
