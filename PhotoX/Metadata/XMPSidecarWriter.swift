import Foundation

/// Writes culling decisions to `<stem>.xmp` next to the ARW. Three invariants:
///
///  * Never touches the ARW/HIF files — only the sidecar.
///  * Atomic write — `Data.write(.atomic)` uses a temp file + rename, so the
///    sidecar is never observed in a partially-written state.
///  * Preserves all other tags (xmp:Label, keywords, history, etc.) by
///    re-parsing the existing XMP and modifying only the targeted element(s).
///
/// Adobe-standard namespaces only, so Lightroom and PhotoCuller round-trip
/// correctly.
enum XMPSidecarWriter {
    enum WriteError: Error, CustomStringConvertible {
        case malformedXMP(String)
        case missingDescription

        var description: String {
            switch self {
            case .malformedXMP(let detail): return "Malformed XMP: \(detail)"
            case .missingDescription: return "XMP file is missing rdf:Description"
            }
        }
    }

    private static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let metaNamespace = "adobe:ns:meta/"

    /// Set xmp:Rating to the given value, or remove it entirely when `rating`
    /// is nil. Per Adobe convention: -1 = rejected, 0 = explicitly unrated,
    /// 1...5 = star count.
    static func updateRating(_ rating: Int?, for pair: PhotoPair) throws {
        let xmpURL = pair.rawURL.deletingPathExtension().appendingPathExtension("xmp")

        let doc: XMLDocument
        if FileManager.default.fileExists(atPath: xmpURL.path) {
            let data = try Data(contentsOf: xmpURL)
            do {
                doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
            } catch {
                throw WriteError.malformedXMP(error.localizedDescription)
            }
        } else {
            doc = newTemplate()
        }

        guard let desc = findDescription(in: doc) else {
            throw WriteError.missingDescription
        }

        // Replace xmp:Rating
        removeChildren(named: "xmp:Rating", from: desc)
        if let rating {
            desc.addChild(XMLElement(name: "xmp:Rating", stringValue: String(rating)))
        }

        // Stamp timestamps + creator
        let now = isoFormatter.string(from: Date())
        setSingleChild(named: "xmp:ModifyDate",   to: now, in: desc)
        setSingleChild(named: "xmp:MetadataDate", to: now, in: desc)
        setSingleChild(named: "xmp:CreatorTool",  to: "PhotoX", in: desc)

        let serialized = doc.xmlData(options: [.nodePrettyPrint])
        // .atomic = Foundation writes to a temp file then rename(2) into place.
        // POSIX rename is atomic; the sidecar can't be observed half-written.
        try serialized.write(to: xmpURL, options: .atomic)
    }

    // MARK: - DOM helpers

    private static func findDescription(in doc: XMLDocument) -> XMLElement? {
        guard let root = doc.rootElement() else { return nil }
        for rdf in root.elements(forName: "rdf:RDF") {
            if let desc = rdf.elements(forName: "rdf:Description").first {
                return desc
            }
        }
        return nil
    }

    private static func removeChildren(named name: String, from parent: XMLElement) {
        for child in parent.elements(forName: name) {
            parent.removeChild(at: child.index)
        }
    }

    private static func setSingleChild(named name: String, to value: String, in parent: XMLElement) {
        removeChildren(named: name, from: parent)
        parent.addChild(XMLElement(name: name, stringValue: value))
    }

    private static func newTemplate() -> XMLDocument {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="\(metaNamespace)" x:xmptk="PhotoX">
           <rdf:RDF xmlns:rdf="\(rdfNamespace)">
              <rdf:Description rdf:about=""
                    xmlns:xmp="\(xmpNamespace)">
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        """
        // Force-try is safe: literal XML, parsing can't fail.
        return try! XMLDocument(xmlString: xml)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
