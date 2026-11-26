import Foundation

/// What HandFX keeps between launches, in its UserDefaults.
enum Settings {
    private static let defaults = UserDefaults.standard

    /// The chosen effect, by name, so a new effect in the list does not change it.
    static var effect: String? {
        get { defaults.string(forKey: "effect") }
        set { defaults.set(newValue, forKey: "effect") }
    }

    static func bool(_ key: String, or fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    static func set(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }

    /// The drawn frame as fractions of the picture's width and height (xmin, ymin, xmax, ymax), so it
    /// fits a camera with another resolution too.
    static var frame: SIMD4<Float>? {
        get {
            guard let v = defaults.array(forKey: "frame") as? [Double], v.count == 4 else { return nil }
            return SIMD4(Float(v[0]), Float(v[1]), Float(v[2]), Float(v[3]))
        }
        set {
            guard let f = newValue else { return defaults.removeObject(forKey: "frame") }
            defaults.set([f.x, f.y, f.z, f.w].map(Double.init), forKey: "frame")
        }
    }
}
