import Foundation

protocol ImageDecoder: Sendable {
    func decode(url: URL) async throws -> DecodedImage
}

enum DecodeError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case sourceCreationFailed(URL)
    case imageCreationFailed(URL)
    case unsupportedFormat(URL)
    case libRawFailure(code: Int32, message: String)

    var description: String {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .sourceCreationFailed(let url):
            return "Could not create image source for \(url.lastPathComponent)"
        case .imageCreationFailed(let url):
            return "Could not decode image data from \(url.lastPathComponent)"
        case .unsupportedFormat(let url):
            return "Unsupported format: \(url.lastPathComponent)"
        case .libRawFailure(let code, let message):
            return "LibRaw error \(code): \(message)"
        }
    }
}
