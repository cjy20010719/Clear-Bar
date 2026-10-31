import Foundation
import CryptoKit

/// Persist one image per wallpaper and display geometry, across app restarts.
struct WallpaperRenderCache {
    let directory: URL

    func imageURL(sourceID: String, width: Int, height: Int, menuBarHeight: Int,
                  createImage: () throws -> Data) throws -> URL {
        let identity = "clear-bar-render-v1:\(sourceID):\(width):\(height):\(menuBarHeight)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("cached-\(digest).png")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber, size.intValue > 0 { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try createImage().write(to: url, options: .atomic)
        return url
    }
}
