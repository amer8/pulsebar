import Foundation

struct AppcastVerifier {
    static func verify(_ data: Data, version: String, buildNumber: String? = nil, archiveSize: UInt64? = nil) throws {
        let parser = XMLParser(data: data)
        let reader = AppcastReader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ToolError("Appcast is not valid XML") }

        let items = reader.items.filter { $0.version == version }
        guard !items.isEmpty else { throw ToolError("Appcast does not contain short version \(version)") }
        let filename = "PulseBar-\(version).zip"
        guard
            items.contains(where: { item in
                (buildNumber == nil || item.buildNumber == buildNumber)
                    && item.enclosures.contains { enclosure in
                        guard let url = enclosure["url"].flatMap(URL.init(string:)),
                            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                            url.lastPathComponent == filename,
                            let signature = enclosure["sparkle:edSignature"], !signature.isEmpty
                        else { return false }
                        return archiveSize == nil || enclosure["length"].flatMap(UInt64.init) == archiveSize
                    }
            })
        else {
            throw ToolError("Appcast entry for \(version) is missing the expected signed archive, build number, or size")
        }
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    struct Item {
        var version = ""
        var buildNumber = ""
        var enclosures: [[String: String]] = []
    }
    private(set) var items: [Item] = []
    private var current: Item?
    private var depth = 0
    private var itemDepth = 0
    private var field: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        if elementName == "item", current == nil {
            current = Item()
            itemDepth = depth
        } else if current != nil, depth == itemDepth + 1 {
            switch elementName {
            case "sparkle:shortVersionString", "sparkle:version": field = elementName
            case "enclosure": current?.enclosures.append(attributes)
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch field {
        case "sparkle:shortVersionString": current?.version += string
        case "sparkle:version": current?.buildNumber += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if depth == itemDepth + 1 { field = nil }
        if elementName == "item", depth == itemDepth, let item = current {
            var item = item
            item.version = item.version.trimmingCharacters(in: .whitespacesAndNewlines)
            item.buildNumber = item.buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(item)
            current = nil
        }
        depth -= 1
    }
}
