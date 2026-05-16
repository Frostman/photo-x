import OSLog

enum Log {
    static let app = Logger(subsystem: "dev.frostman.PhotoX", category: "app")
    static let decode = Logger(subsystem: "dev.frostman.PhotoX", category: "decode")
    static let canvas = Logger(subsystem: "dev.frostman.PhotoX", category: "canvas")
}
