import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers

struct MaterialScan {
    var urls: [URL] = []
    var unreadableFolders = 0
}
struct LoadedMaterial {
    var layer: Layer
    var usedRawPreview: Bool
}

/// Reads originals only. The artwork keeps a bounded, independently embedded copy.
final class MaterialLoader {
    static let rawExtensions: Set<String> = ["raw", "dng", "nef", "nrw", "arw", "srf", "sr2", "cr2", "cr3", "crw", "raf", "orf", "rw2", "rwl", "pef", "ptx", "srw", "3fr", "fff", "iiq", "kdc", "dcr", "erf", "mos", "mrw", "mef", "x3f"]
    static let photoExtensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "tif", "tiff", "heic", "heif", "hif", "gif", "bmp", "webp", "avif", "jp2", "jxl"]
    private let context = CIContext(options: [.cacheIntermediates: false])
    static func isCandidate(_ url: URL, type: UTType?) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased()) || photoExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .image) == true
    }
    static func scan(_ folder: URL, cancelled: () -> Bool = { false }) throws -> MaterialScan {
        let fm = FileManager.default
        let root = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard root.isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        var result = MaterialScan()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .contentTypeKey]
        var directories = [folder]
        // Walk one level at a time so skipping a symbolic link never interferes
        // with traversal of a neighbouring real directory.
        while let directory = directories.popLast() {
            if cancelled() { throw CocoaError(.userCancelled) }
            let children: [URL]
            do { children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) }
            catch {
                if directory == folder { throw error }
                result.unreadableFolders += 1; continue
            }
            for url in children {
                if cancelled() { throw CocoaError(.userCancelled) }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if values.isPackage != true { directories.append(url) }
                    continue
                }
                guard values.isRegularFile == true, isCandidate(url, type: values.contentType) else { continue }
                result.urls.append(url)
            }
        }
        result.urls.sort { $0.path < $1.path }
        return result
    }
    func load(_ url: URL, maximum: Int = 3200) -> LoadedMaterial? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let type = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        let isRaw = Self.rawExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .rawImage) == true
        var cg: CGImage?
        var usedPreview = false
        if isRaw, let raw = CIRAWFilter(imageURL: url) {
            raw.isDraftModeEnabled = true
            let edge = max(raw.nativeSize.width, raw.nativeSize.height)
            if edge > 0 { raw.scaleFactor = Float(min(1, CGFloat(maximum) / edge)) }
            if let output = raw.outputImage { cg = raster(output, maximum: maximum) }
            if cg == nil, let preview = raw.previewImage {
                cg = raster(preview, maximum: maximum); usedPreview = cg != nil
            }
        }
        if cg == nil, let source {
            var options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: maximum,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            // An embedded camera preview is the fallback for RAWs that cannot develop.
            options[isRaw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways] = true
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            usedPreview = isRaw && cg != nil
        }
        guard let cg, let png = Renderer.normalizedPNG(cg, maximum: maximum) else { return nil }
        var layer = Layer(name: url.deletingPathExtension().lastPathComponent + (isRaw ? (usedPreview ? " (RAW preview)" : " (RAW)") : ""), material: .image, image: png)
        layer.sourcePath = url.path
        return LoadedMaterial(layer: layer, usedRawPreview: usedPreview)
    }
    private func raster(_ image: CIImage, maximum: Int) -> CGImage? {
        guard !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        let scale = min(1, CGFloat(maximum) / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
