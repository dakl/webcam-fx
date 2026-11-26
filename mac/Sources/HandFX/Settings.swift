import Foundation

/// What HandFX keeps between launches, in its UserDefaults.
enum Settings {
    private static var defaults: UserDefaults { .standard }  // thread-safe, per Apple

    /// The chosen effect, by name, so a new effect in the list does not change it.
    static var effect: String? {
        get { defaults.string(forKey: "effect") }
        set { defaults.set(newValue, forKey: "effect") }
    }

    static var palette: String? {
        get { defaults.string(forKey: "palette") }
        set { defaults.set(newValue, forKey: "palette") }
    }

    static var blocksAcross: Int {
        get { defaults.integer(forKey: "blocksAcross") }
        set { defaults.set(newValue, forKey: "blocksAcross") }
    }

    static var asciiCharacters: String? {
        get { defaults.string(forKey: "asciiCharacters") }
        set { defaults.set(newValue, forKey: "asciiCharacters") }
    }

    static var asciiColour: String? {
        get { defaults.string(forKey: "asciiColour") }
        set { defaults.set(newValue, forKey: "asciiColour") }
    }

    static var asciiColumns: Int {
        get { defaults.integer(forKey: "asciiColumns") }
        set { defaults.set(newValue, forKey: "asciiColumns") }
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
