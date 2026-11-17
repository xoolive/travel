import Foundation

/// Country and flag of an aircraft from its ICAO 24-bit address, with the
/// address ranges and registration patterns of rs1090 (`patterns.json`,
/// copied from jet1090 into the app bundle).
@MainActor
enum Countries {
    private struct Document: Decodable {
        struct Register: Decodable {
            struct Category: Decodable {
                let pattern: String
                let country: String?
                let flag: String?
            }

            let start: String?
            let end: String?
            let country: String
            let flag: String
            let categories: [Category]?
        }

        let registers: [Register]
    }

    private struct Range {
        let start: UInt32
        let end: UInt32
        let country: String
        let flag: String
        /// Registration patterns that override the country, such as B-H for Hong Kong.
        let overrides: [(NSRegularExpression, String, String)]
    }

    private static let ranges: [Range] = {
        guard let url = Bundle.main.url(forResource: "patterns", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        func address(_ text: String?) -> UInt32? {
            guard let text, text.hasPrefix("0x") else { return nil }
            return UInt32(text.dropFirst(2), radix: 16)
        }
        return document.registers.compactMap { register in
            guard let start = address(register.start), let end = address(register.end) else { return nil }
            let overrides = (register.categories ?? []).compactMap { category -> (NSRegularExpression, String, String)? in
                guard let country = category.country, let flag = category.flag,
                      let expression = try? NSRegularExpression(pattern: category.pattern)
                else { return nil }
                return (expression, country, flag)
            }
            return Range(start: start, end: end, country: register.country, flag: register.flag, overrides: overrides)
        }
    }()

    static func lookup(icao24: String, registration: String?) -> (country: String, flag: String)? {
        guard let address = UInt32(icao24, radix: 16),
              let range = ranges.first(where: { address >= $0.start && address <= $0.end })
        else { return nil }
        if let registration {
            let whole = NSRange(registration.startIndex..., in: registration)
            for (expression, country, flag) in range.overrides
            where expression.firstMatch(in: registration, range: whole) != nil {
                return (country, flag)
            }
        }
        return (range.country, range.flag)
    }
}
