import Foundation

enum MBTASecrets {
    static var apiKey: String {
        if let envValue = ProcessInfo.processInfo.environment["MBTA_API_KEY"], !envValue.isEmpty {
            return envValue
        }

        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "MBTA_API_KEY") as? String,
           !plistValue.isEmpty,
           plistValue != "$(MBTA_API_KEY)" {
            return plistValue
        }

        #if DEBUG
        print("[MBTA] Missing MBTA_API_KEY. Set a Scheme environment variable named MBTA_API_KEY or configure Info.plist MBTA_API_KEY.")
        #endif
        return ""
    }
}

let mbtaAPIKey = MBTASecrets.apiKey

func mbtaAPIQueryItems(_ items: [URLQueryItem], apiKey: String = mbtaAPIKey) -> [URLQueryItem] {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else { return items }
    return [URLQueryItem(name: "api_key", value: trimmedKey)] + items
}
