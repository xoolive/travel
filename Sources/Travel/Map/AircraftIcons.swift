import AppKit

/// The tangram aircraft icon set: one silhouette per family of aircraft,
/// chosen from the ICAO type code. The atlas and its index are copied from
/// tangram (`aircraft-atlas.png`, `aircraft-icons.json`) into the app bundle.
@MainActor
enum AircraftIcons {
    private struct Index: Decodable {
        struct Atlas: Decodable {
            let spriteSize: Int
            let gutter: Int
            let columns: Int
        }

        let atlas: Atlas
        let symbols: [String]
        /// Type code prefix, symbol name; the first match wins.
        let aliases: [[String]]
    }

    private static let fallbackSymbol = "A320"
    private static let vehicleSymbol = "GRND"
    /// Each symbol is drawn in several styles; the first is the plain one.
    private static let stylesPerSymbol = 2

    private static let loaded: (sprites: [CGImage], aliases: [(String, Int)], fallback: Int, vehicle: Int)? = {
        guard let indexURL = Bundle.main.url(forResource: "aircraft-icons", withExtension: "json"),
              let atlasURL = Bundle.main.url(forResource: "aircraft-atlas", withExtension: "png"),
              let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              let source = CGImageSourceCreateWithURL(atlasURL as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let cell = index.atlas.spriteSize + 2 * index.atlas.gutter
        var sprites: [CGImage] = []
        for symbol in index.symbols.indices {
            let slot = symbol * stylesPerSymbol
            let rect = CGRect(
                x: (slot % index.atlas.columns) * cell + index.atlas.gutter,
                y: (slot / index.atlas.columns) * cell + index.atlas.gutter,
                width: index.atlas.spriteSize,
                height: index.atlas.spriteSize
            )
            guard let sprite = atlas.cropping(to: rect) else { return nil }
            sprites.append(sprite)
        }
        let positions = Dictionary(uniqueKeysWithValues: index.symbols.enumerated().map { ($1, $0) })
        let aliases = index.aliases.compactMap { pair -> (String, Int)? in
            guard pair.count == 2, let symbol = positions[pair[1]] else { return nil }
            return (pair[0], symbol)
        }
        return (sprites, aliases, positions[fallbackSymbol] ?? 0, positions[vehicleSymbol] ?? 0)
    }()

    /// Symbol for airport surface vehicles.
    static var vehicle: Int { loaded?.vehicle ?? 0 }

    private static var resolved: [String: Int] = [:]

    /// At most this many symbols exist; used to pack icon cache keys.
    static let capacity = 64

    /// Symbol for a type code such as `B789`; the default silhouette when unknown.
    static func symbol(for typecode: String?) -> Int {
        guard let loaded else { return 0 }
        guard let typecode, !typecode.isEmpty else { return loaded.fallback }
        if let known = resolved[typecode] { return known }
        let symbol = loaded.aliases.first { typecode.hasPrefix($0.0) }?.1 ?? loaded.fallback
        resolved[typecode] = symbol
        return symbol
    }

    /// The silhouette, nose up; nil when the atlas is not available.
    static func sprite(_ symbol: Int) -> CGImage? {
        guard let loaded, loaded.sprites.indices.contains(symbol) else { return nil }
        return loaded.sprites[symbol]
    }
}
