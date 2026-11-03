import Foundation
import CryptoKit

/// Persist one image per wallpaper and display geometry, across app restarts.
struct WallpaperRenderCache {
    let directory: URL
    private static let lock = NSLock()
    private var indexURL: URL { directory.appendingPathComponent(".render-index-v1.plist") }

    enum CacheError: LocalizedError {
        case emptyImage
        var errorDescription: String? { "无法保存空的壁纸图片。" }
    }

    func imageURL(sourceID: String, width: Int, height: Int, menuBarHeight: Int,
                  createImage: () throws -> Data) throws -> URL {
        // A manual refresh and a screen-change refresh must not race to write
        // two copies or lose each other's request-to-content mapping.
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let identity = "clear-bar-render-v1:\(sourceID):\(width):\(height):\(menuBarHeight)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("cached-\(digest).png")
        // Preserve existing URLs and their hard links, including system Spaces
        // that still refer to a previously generated wallpaper.
        if usable(url) { return url }
        var index = readIndex()
        if let name = index[digest], (name as NSString).lastPathComponent == name, name.hasSuffix(".png") {
            let mapped = directory.appendingPathComponent(name)
            if usable(mapped) { return mapped }
        }

        let data = try createImage()
        guard !data.isEmpty else { throw CacheError.emptyImage }
        let contentDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let contentURL = directory.appendingPathComponent("content-\(contentDigest).png")
        let existing = matchingImage(data, preferred: contentURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = existing ?? contentURL
        if existing == nil { try data.write(to: result, options: .atomic) }
        index[digest] = result.lastPathComponent
        // The image remains usable even if optional index persistence fails;
        // content matching still prevents another PNG from being written.
        if let encoded = try? PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0) {
            try? encoded.write(to: indexURL, options: .atomic)
        }
        return result
    }

    private func usable(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    private func readIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else { return [:] }
        return index
    }

    private func matchingImage(_ data: Data, preferred: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let candidates = [preferred] + files.filter { $0.pathExtension.lowercased() == "png" && $0 != preferred }
            .sorted {
                let a = $0.lastPathComponent, b = $1.lastPathComponent
                if a.hasPrefix("cached-") != b.hasPrefix("cached-") { return a.hasPrefix("cached-") }
                return a < b
            }
        var checkedInodes = Set<UInt64>()
        for candidate in candidates {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == data.count else { continue }
            if let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
               !checkedInodes.insert(inode).inserted { continue }
            if let previous = try? Data(contentsOf: candidate, options: .mappedIfSafe), previous == data {
                // Directory enumeration may resolve /var to /private/var.
                // Keep URLs in the caller's original namespace so reuse does
                // not look like a wallpaper change to NSWorkspace.
                return directory.appendingPathComponent(candidate.lastPathComponent)
            }
        }
        return nil
    }
}
