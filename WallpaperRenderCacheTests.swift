import Foundation

@main
struct WallpaperRenderCacheTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("clear-bar-cache-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: directory) }
        let cache = WallpaperRenderCache(directory: directory)
        var encodes = 0
        func image(_ source: String = "wallpaper-1", _ width: Int = 3840,
                   _ height: Int = 2160, _ bar: Int = 48) throws -> URL {
            try cache.imageURL(sourceID: source, width: width, height: height, menuBarHeight: bar) {
                encodes += 1
                return Data("image-\(source)-\(width)-\(height)-\(bar)".utf8)
            }
        }

        let first = try image()
        let originalAttributes = try fm.attributesOfItem(atPath: first.path)
        // A fixed old timestamp detects unwanted rewrites even on fast filesystems.
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.modificationDate: timestamp], ofItemAtPath: first.path)
        for _ in 0..<500 {
            let repeated = try image()
            assert(repeated == first)
        }
        let after = try fm.attributesOfItem(atPath: first.path)
        assert(encodes == 1, "Repeated refreshes must not encode or write new images")
        assert(after[.modificationDate] as? Date == timestamp)
        assert((after[.systemFileNumber] as? NSNumber) == (originalAttributes[.systemFileNumber] as? NSNumber))
        let repeatedFiles = try fm.contentsOfDirectory(atPath: directory.path)
        assert(repeatedFiles.count == 1)

        let restarted = WallpaperRenderCache(directory: directory)
        let restored = try restarted.imageURL(sourceID: "wallpaper-1", width: 3840, height: 2160, menuBarHeight: 48) {
            fatalError("Restarting the app must reuse its persistent cache")
        }
        assert(restored == first)
        let resized = try image("wallpaper-1", 3456, 2234, 74)
        let changed = try image("wallpaper-2")
        let differentBar = try image("wallpaper-1", 3840, 2160, 74)
        assert(resized != first && changed != first && differentBar != first)
        assert(encodes == 4)

        enum EncodingError: Error { case failed }
        do {
            _ = try cache.imageURL(sourceID: "broken", width: 10, height: 10, menuBarHeight: 1) {
                throw EncodingError.failed
            }
            assertionFailure("Encoding failures must propagate")
        } catch EncodingError.failed {}
        let finalFiles = try fm.contentsOfDirectory(atPath: directory.path)
        assert(finalFiles.count == 4)
        print("PASS: 500 refreshes and app restart reuse one file; wallpaper/geometry changes use distinct files; failed encoding leaves no file")
    }
}
