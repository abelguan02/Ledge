import Foundation
import ImageIO
@preconcurrency import Vision

// Copied from Ming's local OCR engine; UI integration is implemented by Dump.
struct DumpOCRResult: Sendable { let text: String; let note: String }
enum DumpOCRError: LocalizedError {
    case image, tooLarge, textTooLarge, busy
    var errorDescription: String? {
        switch self {
        case .image: return "无法识别这张图片，文件可能已移除或格式不支持；原图未改动。"
        case .tooLarge: return "图片超过本地识别范围（64 MiB 或一亿像素），请使用较小的图片副本。"
        case .textTooLarge: return "识别文字超过 256 KiB，未截断保存；请分区域处理图片。"
        case .busy: return "上一项识别仍在结束，请稍后再试。"
        }
    }
}

// One background request at a time. Never writes a file, polls a directory,
// reads the screen/clipboard or starts a model. The URL is a validated library copy.
protocol DumpOCRRecognizing: Sendable {
    func recognize(_ url: URL) async throws -> DumpOCRResult
    func cancel()
}
final class DumpOCREngine: DumpOCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: VNRecognizeTextRequest?
    private var active = false
    private var cancelled = false
    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return false }; active = true; cancelled = false; return true
    }
    private func finish() { lock.lock(); current = nil; active = false; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let request = current; lock.unlock()
        request?.cancel()
    }
    private func install(_ request: VNRecognizeTextRequest) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }; current = request
    }
    private func checkCancelled() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func recognize(_ url: URL) async throws -> DumpOCRResult {
        try Task.checkCancellation()
        guard begin() else { throw DumpOCRError.busy }
        defer { finish() }
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) { [self] in
                try autoreleasepool { () throws -> DumpOCRResult in
                    let request = VNRecognizeTextRequest()
                    try install(request)
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DumpOCRError.image }
                    guard let size = values.fileSize, size <= 64 * 1024 * 1024 else { throw DumpOCRError.tooLarge }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw DumpOCRError.image }
                    guard width <= 100_000, height <= 100_000, Int64(width) * Int64(height) <= 100_000_000 else { throw DumpOCRError.tooLarge }
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw DumpOCRError.image }
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true
                    let supported = try request.supportedRecognitionLanguages()
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
                    try checkCancelled()
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let lines = (request.results ?? []).sorted {
                        if $0.boundingBox.midY == $1.boundingBox.midY { return $0.boundingBox.minX < $1.boundingBox.minX }
                        return $0.boundingBox.midY > $1.boundingBox.midY
                    }.compactMap { $0.topCandidates(1).first?.string }
                    let text = lines.joined(separator: "\n")
                    guard text.utf8.count <= 256 * 1024 else { throw DumpOCRError.textTooLarge }
                    var notes = ["本地识别，请对照原图校正；复杂排版可能顺序不准。"]
                    if max(width, height) > 4096 { notes.append("已缩小用于识别，原图未改变。") }
                    if CGImageSourceGetCount(source) > 1 { notes.append("多帧图片仅识别第一帧。") }
                    return DumpOCRResult(text: text, note: notes.joined(separator: " "))
                }
            }
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { self.cancel() }
    }
}
