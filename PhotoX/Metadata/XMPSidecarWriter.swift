import Foundation
import IndexingCore

/// What we want a sidecar write to converge to. Sparse on purpose: each field
/// is `T??` where `.none` means "leave this tag alone", `.some(nil)` means
/// "remove the tag", and `.some(value)` means "set the tag to value". Used
/// both as the coalescing unit inside `XMPWriteCoordinator` (rapid 1→2→3
/// keypresses collapse to a single intent with the latest value) and as the
/// payload of `FailedWrite` (so the failures UI can render `★N` / label
/// chips for what we tried to write).
struct SidecarIntent: Sendable, Equatable {
    var rating: Int??
    var label: String??

    var hasWork: Bool { rating != nil || label != nil }

    /// Merge `other` into self — other's *set* fields (`.some(...)`) win,
    /// `.none` fields leave self untouched. Used by the failures consumer
    /// so a label failure after a rating failure on the same stem keeps
    /// both fields in the row instead of overwriting.
    mutating func merge(_ other: SidecarIntent) {
        if let r = other.rating { rating = r }
        if let l = other.label  { label  = l }
    }

    static func setRating(_ r: Int?) -> SidecarIntent {
        SidecarIntent(rating: .some(r), label: nil)
    }
    static func setLabel(_ l: String?) -> SidecarIntent {
        SidecarIntent(rating: nil, label: .some(l))
    }
    static func setBoth(rating: Int?, label: String?) -> SidecarIntent {
        SidecarIntent(rating: .some(rating), label: .some(label))
    }
}

/// Writes culling decisions to `<stem>.xmp` next to the ARW. Three invariants:
///
///  * Never touches the ARW/HIF files — only the sidecar.
///  * Atomic write — `Data.write(.atomic)` uses a temp file + rename, so the
///    sidecar is never observed in a partially-written state.
///  * Preserves all other tags (xmp:Label, xmp:Rating, keywords, history,
///    etc.) by re-parsing the existing XMP and modifying only the targeted
///    element(s).
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

    /// Patch the sidecar to satisfy `intent`. If `existingData` matches the
    /// file's current mtime, the in-memory bytes are reused instead of being
    /// re-read from disk — that's the cache-hit fast path the coordinator
    /// relies on for rapid same-stem writes. If the disk mtime drifted
    /// (another tool wrote the file) the cache is discarded and we re-read,
    /// keeping the "preserve foreign tags" invariant.
    ///
    /// Always bumps `xmp:ModifyDate` / `xmp:MetadataDate` / `xmp:CreatorTool`
    /// — the modify timestamp lives *in the XMP content*, so the bump
    /// itself counts as a meaningful write even if no field changed.
    ///
    /// Returns the serialized bytes + file mtime after the write so the
    /// coordinator can prime its cache for the next call.
    @discardableResult
    static func applyIntent(
        _ intent: SidecarIntent,
        existingData: Data?,
        cachedMTime: Date?,
        for entry: PhotoEntry
    ) throws -> (newData: Data, mtime: Date) {
        let xmpURL = entry.xmpURL
        let baseData = try loadBaseData(
            xmpURL: xmpURL,
            existingData: existingData,
            cachedMTime: cachedMTime
        )

        let doc: XMLDocument
        if let baseData {
            do {
                doc = try XMLDocument(data: baseData, options: [.nodePreserveWhitespace])
            } catch {
                throw WriteError.malformedXMP(error.localizedDescription)
            }
        } else {
            doc = newTemplate()
        }

        guard let desc = findDescription(in: doc) else {
            throw WriteError.missingDescription
        }

        if case .some(let optionalRating) = intent.rating {
            removeChildren(named: "xmp:Rating", from: desc)
            if let r = optionalRating {
                desc.addChild(XMLElement(name: "xmp:Rating", stringValue: String(r)))
            }
        }
        if case .some(let optionalLabel) = intent.label {
            removeChildren(named: "xmp:Label", from: desc)
            if let l = optionalLabel, !l.isEmpty {
                desc.addChild(XMLElement(name: "xmp:Label", stringValue: l))
            }
        }

        let now = isoFormatter.string(from: Date())
        setSingleChild(named: "xmp:ModifyDate",   to: now, in: desc)
        setSingleChild(named: "xmp:MetadataDate", to: now, in: desc)
        setSingleChild(named: "xmp:CreatorTool",  to: "PhotoX", in: desc)

        let serialized = doc.xmlData(options: [.nodePrettyPrint])
        try serialized.write(to: xmpURL, options: .atomic)

        let mtime = (try? xmpURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
        return (newData: serialized, mtime: mtime)
    }

    static func updateRating(_ rating: Int?, for entry: PhotoEntry) throws {
        _ = try applyIntent(.setRating(rating),
                            existingData: nil, cachedMTime: nil, for: entry)
    }

    static func updateLabel(_ label: String?, for entry: PhotoEntry) throws {
        _ = try applyIntent(.setLabel(label),
                            existingData: nil, cachedMTime: nil, for: entry)
    }

    // MARK: - load helpers

    /// Resolve which bytes to parse for this write:
    ///  - no file on disk → nil (caller creates from template).
    ///  - cache present AND disk mtime matches → reuse cached bytes.
    ///  - otherwise → read from disk (drift safety net).
    private static func loadBaseData(
        xmpURL: URL,
        existingData: Data?,
        cachedMTime: Date?
    ) throws -> Data? {
        guard FileManager.default.fileExists(atPath: xmpURL.path) else {
            return nil
        }
        if let existingData,
           let cachedMTime,
           let diskMTime = try? xmpURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
           diskMTime == cachedMTime {
            return existingData
        }
        return try Data(contentsOf: xmpURL)
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
        return try! XMLDocument(xmlString: xml)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
