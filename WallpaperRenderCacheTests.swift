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
        let repeatedFiles = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
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
        let finalFiles = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        assert(finalFiles.count == 4)

        // Different import identifiers can still produce exactly the same PNG.
        // Reuse its existing URL, both within this session and after restart.
        let aliasDirectory = directory.appendingPathComponent("aliases")
        try fm.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let legacyURL = aliasDirectory.appendingPathComponent("old-random-name.png")
        let samePNG = Data("same-encoded-wallpaper".utf8)
        try samePNG.write(to: legacyURL)
        let legacyDate = Date(timeIntervalSince1970: 2_000_000)
        try fm.setAttributes([.modificationDate: legacyDate], ofItemAtPath: legacyURL.path)
        let aliases = WallpaperRenderCache(directory: aliasDirectory)
        var aliasEncodes = 0
        for number in 0..<30 {
            let result = try aliases.imageURL(sourceID: "import-\(number)", width: 1920, height: 1080, menuBarHeight: 24) {
                aliasEncodes += 1
                return samePNG
            }
            if result != legacyURL { FileHandle.standardError.write(Data("Expected: \(legacyURL.absoluteString) actual: \(result.absoluteString)\n".utf8)) }
            assert(result == legacyURL, "Identical image bytes must reuse an existing legacy URL")
        }
        let aliasFiles = try fm.contentsOfDirectory(atPath: aliasDirectory.path).filter { $0.hasSuffix(".png") }
        assert(aliasFiles.count == 1 && aliasEncodes == 30)
        let aliasRestart = WallpaperRenderCache(directory: aliasDirectory)
        for number in 0..<30 {
            let result = try aliasRestart.imageURL(sourceID: "import-\(number)", width: 1920, height: 1080, menuBarHeight: 24) {
                fatalError("Known aliases must survive restart without re-encoding")
            }
            assert(result == legacyURL)
        }
        let legacyAfter = try fm.attributesOfItem(atPath: legacyURL.path)
        assert(legacyAfter[.modificationDate] as? Date == legacyDate)

        // A lost/corrupt lookup index can be reconstructed by matching content;
        // it must not make duplicate images, nor delete unrelated images.
        try Data("invalid-index".utf8).write(to: aliasDirectory.appendingPathComponent(".render-index-v1.plist"))
        let repaired = try aliases.imageURL(sourceID: "import-0", width: 1920, height: 1080, menuBarHeight: 24) { samePNG }
        assert(repaired == legacyURL)
        do {
            _ = try aliases.imageURL(sourceID: "empty", width: 10, height: 10, menuBarHeight: 1) { Data() }
            assertionFailure("Empty images must not create files")
        } catch WallpaperRenderCache.CacheError.emptyImage {}
        let filesAfterRecovery = try fm.contentsOfDirectory(atPath: aliasDirectory.path).filter { $0.hasSuffix(".png") }
        assert(filesAfterRecovery.count == 1)
        let concurrentDirectory = directory.appendingPathComponent("concurrent")
        let concurrent = WallpaperRenderCache(directory: concurrentDirectory)
        let resultLock = NSLock()
        var results: [URL] = []
        var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 40) { number in
            do {
                let result = try concurrent.imageURL(sourceID: "concurrent-\(number)", width: 100, height: 100, menuBarHeight: 10) { samePNG }
                resultLock.lock(); results.append(result); resultLock.unlock()
            } catch {
                resultLock.lock(); errors.append(String(describing: error)); resultLock.unlock()
            }
        }
        assert(errors.isEmpty && results.count == 40 && Set(results).count == 1)
        let concurrentFiles = try fm.contentsOfDirectory(atPath: concurrentDirectory.path).filter { $0.hasSuffix(".png") }
        assert(concurrentFiles.count == 1, "Concurrent requests for identical output must write one PNG")
        let afterConcurrency = WallpaperRenderCache(directory: concurrentDirectory)
        for number in 0..<40 {
            let result = try afterConcurrency.imageURL(sourceID: "concurrent-\(number)", width: 100, height: 100, menuBarHeight: 10) {
                fatalError("Concurrent request mappings must all survive restart")
            }
            assert(result == results[0])
        }
        print("PASS: 40 simultaneous requests produce one PNG and retain every mapping across restart")
        print("PASS: 30 different import IDs reuse one legacy PNG; restart avoids re-encoding; corrupt index recovers without duplicates; empty output rejected")
        print("PASS: 500 refreshes and app restart reuse one file; wallpaper/geometry changes use distinct files; failed encoding leaves no file")
    }
}
