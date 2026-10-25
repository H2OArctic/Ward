import AppKit
import ScreenCaptureKit
import Vision

enum QRScanner {
    enum Failure: LocalizedError {
        case permission

        var errorDescription: String? {
            "Нужен доступ к записи экрана: Системные настройки → Конфиденциальность и безопасность → Запись экрана → Ward"
        }
    }

    /// Снимает все экраны без окон самого Ward — QR на странице под окном тоже найдётся.
    static func scanScreens() async throws -> [String] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure.permission
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        var found: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = await MainActor.run { backingScale(for: display.displayID) }
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            found += detect(in: image)
        }
        return found
    }

    /// Разбор картинок — не на главном потоке: окно не замирает, пока Vision ищет коды в нескольких файлах.
    static func scanFiles(_ urls: [URL]) async -> [String] {
        await Task.detached(priority: .userInitiated) { urls.flatMap(scanFile) }.value
    }

    /// Картинка из файла — какая угодно: огромную (десятки тысяч точек по стороне) не раскрываем целиком,
    /// а уменьшаем при чтении — для QR хватает с запасом, а память и время остаются ограниченными.
    static func scanFile(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 50_000, height <= 50_000 else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 4096),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
        return detect(in: image)
    }

    static func detect(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    @MainActor
    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }
        return screen?.backingScaleFactor ?? 2
    }
}
