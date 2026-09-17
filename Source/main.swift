import Cocoa
import Carbon.HIToolbox
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ServiceManagement

// OkiPaste — historial de portapapeles para macOS.
// Un solo archivo, sin dependencias. Compilar con build.sh.

func oklog(_ msg: String) {
    NSLog("[OkiPaste] %@", msg)
}

let okiHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OkiPaste")

// =====================================================================
// MARK: - Tema visual
// =====================================================================

enum Theme {
    static let cardW: CGFloat = 196
    static let cardH: CGFloat = 228
    static let cardGap: CGFloat = 12
    static let cardHeaderH: CGFloat = 54
    static let cardFooterH: CGFloat = 28
    static let cardRadius: CGFloat = 13

    static let barHeaderH: CGFloat = 58
    static let pad: CGFloat = 18
    static let barRadius: CGFloat = 20
    static let barMinW: CGFloat = 760

    static let cardBody = NSColor(srgbRed: 0.145, green: 0.145, blue: 0.16, alpha: 1)
    static let cardFooter = NSColor(srgbRed: 0.125, green: 0.125, blue: 0.14, alpha: 1)
    static let textPrimary = NSColor(white: 1, alpha: 0.92)
    static let textSecondary = NSColor(white: 1, alpha: 0.50)
    static let textTertiary = NSColor(white: 1, alpha: 0.34)
    static let hairline = NSColor(white: 1, alpha: 0.08)
    static var accent: NSColor { NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }

    static let textColor = NSColor(srgbRed: 0.35, green: 0.37, blue: 0.86, alpha: 1)
    static let imageColor = NSColor(srgbRed: 0.10, green: 0.56, blue: 0.60, alpha: 1)
    static let fileColor = NSColor(srgbRed: 0.88, green: 0.48, blue: 0.14, alpha: 1)
    static let graphite = NSColor(srgbRed: 0.30, green: 0.31, blue: 0.35, alpha: 1)
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
               color: NSColor = Theme.textPrimary) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.cell?.usesSingleLineMode = true
    return l
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func sha(_ s: String) -> String { sha(Data(s.utf8)) }

// =====================================================================
// MARK: - Modelo
// =====================================================================

enum ClipKind: String, Codable { case text, image, file }

struct ClipRecord: Codable {
    let id: String
    var kind: ClipKind
    var date: Double
    var text: String?        // texto (kind == .text); primera ruta (kind == .file, compatibilidad)
    var paths: [String]?     // rutas de archivos (kind == .file)
    var imageFile: String?   // PNG guardado junto al json (kind == .image)
    var rtfFile: String?     // formato enriquecido opcional (kind == .text)
    var hash: String?        // huella del contenido, para no duplicar
    var appBundleID: String?
    var appName: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
}

enum Flavor {
    case text, link(URL), color(NSColor, String)
    case image
    case video, picture, pdf, audio, folder, file, files(Int), missing
}

final class ClipItem {
    var record: ClipRecord
    var thumbnail: NSImage?
    var fileIcon: NSImage?
    var onThumbnailReady: (() -> Void)?
    private(set) var flavor: Flavor = .text

    init(record: ClipRecord) {
        self.record = record
        flavor = computeFlavor()
    }

    var paths: [String] {
        if let p = record.paths, !p.isEmpty { return p }
        if record.kind == .file, let t = record.text { return [t] }
        return []
    }

    private func computeFlavor() -> Flavor {
        switch record.kind {
        case .image:
            return .image
        case .text:
            let t = (record.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= 2048, !t.contains(where: { $0.isWhitespace }) {
                var candidate = t
                if candidate.lowercased().hasPrefix("www.") { candidate = "https://" + candidate }
                if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
                   ["http", "https"].contains(scheme), url.host != nil {
                    return .link(url)
                }
            }
            if let c = ClipItem.parseHexColor(t) { return .color(c.0, c.1) }
            return .text
        case .file:
            let ps = paths
            if ps.count > 1 { return .files(ps.count) }
            guard let p = ps.first, FileManager.default.fileExists(atPath: p) else { return .missing }
            let url = URL(fileURLWithPath: p)
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return .file }
            if type.conforms(to: .folder) || type.conforms(to: .directory) {
                return type.conforms(to: .application) || type.conforms(to: .package) ? .file : .folder
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .image) { return .picture }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .audio) { return .audio }
            return .file
        }
    }

    static func parseHexColor(_ s: String) -> (NSColor, String)? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() } else { return nil }
        guard hex.count == 6 || hex.count == 3, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(hex, radix: 16) else { return nil }
        let c = NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                        green: CGFloat((v >> 8) & 0xff) / 255,
                        blue: CGFloat(v & 0xff) / 255, alpha: 1)
        return (c, "#" + hex.uppercased())
    }

    var title: String {
        switch flavor {
        case .text: return "Texto"
        case .link: return "Enlace"
        case .color: return "Color"
        case .image, .picture: return "Imagen"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .folder: return "Carpeta"
        case .file: return "Archivo"
        case .files(let n): return "\(n) archivos"
        case .missing: return "Archivo no encontrado"
        }
    }

    var info: String {
        switch flavor {
        case .text:
            let n = (record.text ?? "").count
            return n == 1 ? "1 carácter" : "\(n.formatted()) caracteres"
        case .link(let url): return (url.host ?? "Enlace").replacingOccurrences(of: "www.", with: "")
        case .color(_, let hex): return hex
        case .image:
            if let w = record.pixelWidth, let h = record.pixelHeight { return "\(w) × \(h) px" }
            return "Imagen"
        case .video, .picture, .pdf, .audio, .file:
            guard let p = paths.first else { return "" }
            let url = URL(fileURLWithPath: p)
            let ext = url.pathExtension.uppercased()
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                let s = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                return ext.isEmpty ? s : "\(ext) · \(s)"
            }
            return ext
        case .folder: return "Carpeta"
        case .files(let n):
            let total = paths.compactMap { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
                .reduce(0, +)
            return total > 0 ? "\(n) archivos · " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                             : "\(n) archivos"
        case .missing: return (paths.first as NSString?)?.lastPathComponent ?? ""
        }
    }

    var searchText: String {
        var parts = [title, record.appName ?? ""]
        if let t = record.text, record.kind == .text { parts.append(t) }
        parts.append(contentsOf: paths.map { ($0 as NSString).lastPathComponent })
        return parts.joined(separator: " ")
    }
}

func relativeTime(_ date: Double) -> String {
    let s = Date().timeIntervalSince1970 - date
    if s < 60 { return "Justo ahora" }
    if s < 3600 { return "Hace \(Int(s / 60)) min" }
    if s < 86400 { return "Hace \(Int(s / 3600)) h" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "es_MX")
    f.dateFormat = "d MMM, HH:mm"
    return f.string(from: Date(timeIntervalSince1970: date))
}

// Ícono y color característico de la app de origen (como las cabeceras de Paste)
enum AppStyle {
    private static var cache: [String: (NSImage, NSColor)] = [:]

    static func lookup(_ bundleID: String?) -> (icon: NSImage, color: NSColor)? {
        guard let bid = bundleID else { return nil }
        if let c = cache[bid] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let entry = (icon, dominantColor(of: icon))
        cache[bid] = entry
        return entry
    }

    /// Color dominante: agrupa los píxeles con color por tono y toma el grupo con más peso.
    static func dominantColor(of image: NSImage) -> NSColor {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Theme.graphite }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var weight = [CGFloat](repeating: 0, count: 12)
        var rs = [CGFloat](repeating: 0, count: 12), gs = rs, bs = rs
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                guard s > 0.25, b > 0.2 else { continue }
                let i = min(11, Int(h * 12))
                let w = s * b
                weight[i] += w
                rs[i] += c.redComponent * w; gs[i] += c.greenComponent * w; bs[i] += c.blueComponent * w
            }
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 25 else {
            return Theme.graphite
        }
        let w = weight[best]
        let avg = NSColor(srgbRed: rs[best] / w, green: gs[best] / w, blue: bs[best] / w, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(max(s, 0.50), 0.85), brightness: min(max(b, 0.50), 0.66), alpha: 1)
    }
}

// =====================================================================
// MARK: - Almacén de historial
// =====================================================================

final class ClipHistory {
    let dir: URL
    let maxItems = 25
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    // Configurables para poder probar captura/límite/purga con datos falsos,
    // sin tocar NSPasteboard.general ni ~/OkiPaste/Historial (ver runSelfTests).
    private let pasteboard: NSPasteboard
    private var lastChangeCount = -1
    private var ownChangeCount = -1
    private let purgeMarker: URL
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    // Contenido que marcan como privado los gestores de contraseñas: nunca se guarda.
    private static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType", "Pasteboard generator type",
    ]

    init(dir: URL = okiHome.appendingPathComponent("Historial"), pasteboard: NSPasteboard = .general) {
        self.dir = dir
        self.pasteboard = pasteboard
        purgeMarker = dir.appendingPathComponent(".ultima_limpieza")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if purgeIfNewDay() {
            // Lo que quedó en el portapapeles es de ayer: no se vuelve a guardar
            lastChangeCount = pasteboard.changeCount
        }
        loadExisting()
        oklog("Historial listo en \(dir.path) con \(items.count) elemento(s)")
    }

    // ---------- Limpieza diaria ----------

    /// Si cambió el día calendario desde la última limpieza, borra todo el historial.
    @discardableResult
    func purgeIfNewDay() -> Bool {
        let today = dayFormatter.string(from: Date())
        let lastDay = (try? String(contentsOf: purgeMarker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lastDay != today else { return false }
        oklog("Nuevo día (anterior: \(lastDay ?? "ninguno"), hoy: \(today)) — borrando historial")
        removeAllFiles()
        try? today.write(to: purgeMarker, atomically: true, encoding: .utf8)
        let hadItems = !items.isEmpty
        items.removeAll()
        if hadItems { onChange?() }
        return true
    }

    func clearAll() {
        oklog("Historial borrado manualmente")
        removeAllFiles()
        items.removeAll()
        onChange?()
    }

    private func removeAllFiles() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent != ".ultima_limpieza" {
            try? fm.removeItem(at: f)
        }
    }

    // ---------- Carga ----------

    private func loadExisting() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var records: [ClipRecord] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  var rec = try? JSONDecoder().decode(ClipRecord.self, from: data) else {
                try? fm.removeItem(at: f)
                continue
            }
            if rec.hash == nil { rec.hash = computeHash(for: rec) }
            records.append(rec)
        }
        records.sort { $0.date > $1.date }

        var seen = Set<String>()
        var keep: [ClipRecord] = []
        for rec in records {
            let h = rec.hash ?? rec.id
            if seen.contains(h) || keep.count >= maxItems {
                deleteFiles(of: rec)
                continue
            }
            seen.insert(h)
            keep.append(rec)
        }

        // Archivos sueltos que ya no pertenecen a ningún elemento
        let referenced = Set(keep.flatMap { [$0.id + ".json", $0.imageFile, $0.rtfFile].compactMap { $0 } })
        for f in files where !f.lastPathComponent.hasPrefix(".") && !referenced.contains(f.lastPathComponent) {
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
        }

        for rec in keep {
            save(rec)
            let item = ClipItem(record: rec)
            prepareThumbnail(item)
            items.append(item)
        }
    }

    private func computeHash(for rec: ClipRecord) -> String? {
        switch rec.kind {
        case .text: return rec.text.map { sha("text\n" + $0) }
        case .file: return sha("file\n" + (rec.paths ?? [rec.text].compactMap { $0 }).joined(separator: "\n"))
        case .image:
            guard let name = rec.imageFile, let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return sha(data)
        }
    }

    // ---------- Captura ----------

    /// Revisa el portapapeles del sistema; si cambió, guarda un nuevo elemento.
    func poll() {
        purgeIfNewDay()

        let pb = pasteboard
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        guard cc != ownChangeCount else { return } // lo acabamos de escribir nosotros al pegar

        let types = pb.types ?? []
        if types.contains(where: { ClipHistory.privateTypes.contains($0.rawValue) }) {
            oklog("Contenido marcado como privado (contraseña) — no se guarda")
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        // La pantalla de bloqueo o el protector de pantalla no cuentan como "app de origen"
        let ignoredApps: Set<String> = [Bundle.main.bundleIdentifier ?? "", "com.apple.loginwindow",
                                        "com.apple.ScreenSaver.Engine", "com.apple.dock"]
        let isSelf = ignoredApps.contains(front?.bundleIdentifier ?? "")
        let appID = isSelf ? nil : front?.bundleIdentifier
        let appName = isSelf ? nil : front?.localizedName

        // 1) Archivos (copiados en Finder: documentos, videos, carpetas...). Solo se guarda la ruta.
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }
            let h = sha("file\n" + paths.joined(separator: "\n"))
            if bump(hash: h) { return }
            var rec = newRecord(kind: .file, hash: h, appID: appID, appName: appName)
            rec.paths = paths
            rec.text = paths.first
            oklog("Nuevo elemento: \(paths.count) archivo(s) -> \(paths.first ?? "") [\(appName ?? "?")]")
            insert(rec)
            return
        }

        let str = pb.string(forType: .string)
        let hasText = !(str?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        // 2) Imagen (capturas de pantalla, imágenes copiadas de Vista Previa, Fotos, navegador...)
        if !hasText, let imgType = pb.availableType(from: [.png, .tiff]), let raw = pb.data(forType: imgType) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let png: Data? = imgType == .png ? raw
                    : NSBitmapImageRep(data: raw)?.representation(using: .png, properties: [:])
                guard let png = png else { return }
                let h = sha(png)
                let thumb = ClipHistory.downsample(png, maxPixels: 640)
                DispatchQueue.main.async {
                    if self.bump(hash: h) { return }
                    var rec = self.newRecord(kind: .image, hash: h, appID: appID, appName: appName)
                    let name = rec.id + ".png"
                    do { try png.write(to: self.dir.appendingPathComponent(name)) } catch {
                        oklog("No se pudo guardar la imagen: \(error)")
                        return
                    }
                    rec.imageFile = name
                    rec.pixelWidth = thumb.width
                    rec.pixelHeight = thumb.height
                    oklog("Nuevo elemento: imagen \(thumb.width)×\(thumb.height) (\(png.count) bytes) [\(appName ?? "?")]")
                    self.insert(rec, thumbnail: thumb.image)
                }
            }
            return
        }

        // 3) Texto (con su formato enriquecido si lo trae)
        if hasText, let s = str {
            let h = sha("text\n" + s)
            if bump(hash: h) { return }
            var rec = newRecord(kind: .text, hash: h, appID: appID, appName: appName)
            rec.text = s
            if let rtf = pb.data(forType: .rtf), rtf.count < 5_000_000 {
                let name = rec.id + ".rtf"
                if (try? rtf.write(to: dir.appendingPathComponent(name))) != nil { rec.rtfFile = name }
            }
            oklog("Nuevo elemento: texto (\(s.count) car.) [\(appName ?? "?")]")
            insert(rec)
        }
    }

    /// Marca el cambio de portapapeles que hizo OkiPaste al pegar, para no volver a capturarlo.
    func markOwnWrite() {
        ownChangeCount = pasteboard.changeCount
    }

    private func newRecord(kind: ClipKind, hash: String, appID: String?, appName: String?) -> ClipRecord {
        let now = Date().timeIntervalSince1970
        let id = "\(Int(now * 1000))_\(Int.random(in: 1000...9999))"
        return ClipRecord(id: id, kind: kind, date: now, hash: hash, appBundleID: appID, appName: appName)
    }

    /// Si el contenido ya existe, lo sube al primer lugar en vez de duplicarlo.
    @discardableResult
    private func bump(hash: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.record.hash == hash }) else { return false }
        if idx > 0 { moveToTop(items[idx]) }
        return true
    }

    func moveToTop(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0 === item }) else { return }
        items.remove(at: idx)
        item.record.date = Date().timeIntervalSince1970
        items.insert(item, at: 0)
        save(item.record)
        onChange?()
    }

    private func insert(_ rec: ClipRecord, thumbnail: NSImage? = nil) {
        save(rec)
        let item = ClipItem(record: rec)
        if let t = thumbnail { item.thumbnail = t } else { prepareThumbnail(item) }
        items.insert(item, at: 0)
        while items.count > maxItems {
            let removed = items.removeLast()
            deleteFiles(of: removed.record)
            oklog("Límite de \(maxItems) alcanzado — se eliminó el más antiguo (\(removed.record.kind.rawValue))")
        }
        onChange?()
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0 === item }
        deleteFiles(of: item.record)
        onChange?()
    }

    private func save(_ rec: ClipRecord) {
        if let data = try? JSONEncoder().encode(rec) {
            try? data.write(to: dir.appendingPathComponent(rec.id + ".json"), options: .atomic)
        }
    }

    private func deleteFiles(of rec: ClipRecord) {
        let fm = FileManager.default
        for name in [rec.id + ".json", rec.imageFile, rec.rtfFile].compactMap({ $0 }) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // ---------- Miniaturas ----------

    static func downsample(_ data: Data, maxPixels: Int) -> (image: NSImage?, width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, 0, 0) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return (nil, w, h) }
        return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), w, h)
    }

    func prepareThumbnail(_ item: ClipItem) {
        switch item.record.kind {
        case .text:
            break
        case .image:
            guard let name = item.record.imageFile,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return }
            let t = ClipHistory.downsample(data, maxPixels: 640)
            item.thumbnail = t.image
            if item.record.pixelWidth == nil { item.record.pixelWidth = t.width; item.record.pixelHeight = t.height }
        case .file:
            let paths = item.paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return }
            item.fileIcon = paths.count > 1 ? NSWorkspace.shared.icon(forFiles: paths)
                                            : NSWorkspace.shared.icon(forFile: paths[0])
            switch item.flavor {
            case .video, .picture, .pdf:
                let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: paths[0]),
                                                       size: CGSize(width: Theme.cardW, height: 146),
                                                       scale: 2, representationTypes: .thumbnail)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                    guard let rep = rep else { return }
                    DispatchQueue.main.async {
                        item.thumbnail = rep.nsImage
                        item.onThumbnailReady?()
                    }
                }
            default:
                break
            }
        }
    }
}

// =====================================================================
// MARK: - Captura automática de capturas de pantalla
// =====================================================================

/// Vigila la carpeta donde macOS guarda las capturas de pantalla (Escritorio por defecto,
/// o la que el usuario haya configurado en Ajustes de captura) y, en cuanto aparece una
/// nueva -sin importar el formato que use (PNG, JPG, TIFF, PDF)-, la copia al portapapeles
/// del sistema para que ClipHistory la capture igual que cualquier otra imagen copiada.
final class ScreenshotWatcher {
    private let dirURL: URL
    private let pasteboard: NSPasteboard
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String>
    private let queue = DispatchQueue(label: "com.alejandro.okipaste.screenshotwatcher")

    // `directory`/`pasteboard` permiten probar la lógica con una carpeta y un portapapeles
    // de prueba, sin tocar el Escritorio real ni NSPasteboard.general (ver runSelfTests).
    init?(directory: URL? = nil, pasteboard: NSPasteboard = .general) {
        let dir = directory ?? ScreenshotWatcher.resolveScreenshotDirectory()
        self.pasteboard = pasteboard
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            oklog("No se pudo vigilar la carpeta de capturas de pantalla (\(dir.path))")
            return nil
        }
        dirURL = dir
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        src.setEventHandler { [weak self] in self?.directoryChanged() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        oklog("Vigilando capturas de pantalla en \(dir.path)")
    }

    /// Dónde guarda macOS las capturas: la carpeta elegida en Ajustes de captura, o Escritorio si no se ha cambiado.
    private static func resolveScreenshotDirectory() -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private func directoryChanged() {
        let current = Set((try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? [])
        let added = current.subtracting(seen)
        seen = current
        for name in added where !name.hasPrefix(".") {
            let url = dirURL.appendingPathComponent(name)
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.processIfScreenshot(url)
            }
        }
    }

    /// macOS marca cada captura con este atributo extendido, sin importar el formato o el nombre elegido.
    private func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    private func processIfScreenshot(_ url: URL) {
        guard waitUntilStable(url), isScreenshot(url) else { return }
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            oklog("No se pudo leer la captura de pantalla \(url.lastPathComponent)")
            return
        }
        DispatchQueue.main.async { [pasteboard] in
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            oklog("Captura de pantalla detectada (\(url.lastPathComponent)) -> copiada al portapapeles")
        }
    }

    /// Espera a que el archivo termine de escribirse (capturas grandes pueden tardar un momento).
    private func waitUntilStable(_ url: URL) -> Bool {
        var lastSize: Int64 = -1
        for _ in 0..<20 {
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return false }
            if size == lastSize && size > 0 { return true }
            lastSize = size
            Thread.sleep(forTimeInterval: 0.15)
        }
        return lastSize > 0
    }
}

// =====================================================================
// MARK: - Motor de pegado automático
// =====================================================================

enum PasteEngine {
    /// Pone el elemento en el portapapeles del sistema. Devuelve false si ya no se puede (p. ej. archivo borrado).
    static func write(_ item: ClipItem, history: ClipHistory, plainText: Bool = false) -> Bool {
        let pb = NSPasteboard.general
        switch item.record.kind {
        case .text:
            guard let text = item.record.text else { return false }
            pb.clearContents()
            if !plainText, let rtfName = item.record.rtfFile,
               let rtf = try? Data(contentsOf: history.dir.appendingPathComponent(rtfName)) {
                pb.declareTypes([.rtf, .string], owner: nil)
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(text, forType: .string)
        case .image:
            guard let name = item.record.imageFile,
                  let png = try? Data(contentsOf: history.dir.appendingPathComponent(name)) else { return false }
            // TIFF además de PNG para apps antiguas que solo aceptan TIFF (se omite en imágenes enormes)
            let tiff = png.count < 8_000_000 ? NSBitmapImageRep(data: png)?.tiffRepresentation : nil
            pb.clearContents()
            pb.declareTypes(tiff == nil ? [.png] : [.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            if let tiff = tiff { pb.setData(tiff, forType: .tiff) }
        case .file:
            let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pb.clearContents()
            pb.writeObjects(urls)
        }
        history.markOwnWrite()
        history.moveToTop(item)
        oklog("Portapapeles listo con elemento tipo \(item.record.kind.rawValue)\(plainText ? " (texto simple)" : "")")
        return true
    }

    /// Devuelve el foco a la app donde estabas, espera a que de verdad esté al frente y pega.
    static func pasteInto(_ target: NSRunningApplication?, attempt: Int = 0) {
        let front = NSWorkspace.shared.frontmostApplication
        guard let t = target, !t.isTerminated else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sendCommandV() }
            return
        }
        if front?.processIdentifier == t.processIdentifier {
            // Pequeño margen para que la ventana de la app recupere el teclado
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.12)) {
                sendCommandV()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    oklog("Después de pegar, al frente: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                }
            }
            return
        }
        if attempt == 0 || attempt % 5 == 0 {
            oklog("Al frente está «\(front?.localizedName ?? "?")», regresando a «\(t.localizedName ?? "?")» (intento \(attempt))")
            t.activate(options: [.activateIgnoringOtherApps])
        }
        guard attempt < 30 else {
            oklog("No se pudo regresar a «\(t.localizedName ?? "?")» — se cancela el pegado para no pegar en otra app")
            NSSound.beep()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { pasteInto(t, attempt: attempt + 1) }
    }

    static func sendCommandV() {
        let trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        oklog("Simulando ⌘V en «\(front)» (Accesibilidad: \(trusted))")
        postKey(9, flags: .maskCommand)
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// =====================================================================
// MARK: - Piezas visuales
// =====================================================================

/// Imagen que llena su espacio recortando lo que sobra (como "aspect fill").
final class FillImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let img = image, img.size.width > 0, img.size.height > 0 else { return }
        let scale = max(bounds.width / img.size.width, bounds.height / img.size.height)
        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Tecla dibujada (⌘1, esc, ↩...)
func makeKeycap(_ text: String) -> NSView {
    let label = makeLabel(text, size: 10, weight: .semibold, color: NSColor(white: 1, alpha: 0.62))
    label.sizeToFit()
    let w = max(18, label.frame.width + 10)
    let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 17))
    v.wantsLayer = true
    v.layer?.cornerRadius = 4.5
    v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
    v.layer?.borderWidth = 0.5
    v.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
    label.frame = NSRect(x: 0, y: (17 - label.frame.height) / 2, width: w, height: label.frame.height)
    label.alignment = .center
    v.addSubview(label)
    return v
}

// =====================================================================
// MARK: - Tarjeta de un elemento
// =====================================================================

final class ClipCardView: FlippedView {
    let item: ClipItem
    var onClick: (() -> Void)?
    var onSelect: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var isSelected = false { didSet { updateBorder(animated: true) } }
    private var hovering = false
    private var pressed = false
    private var thumbView: FillImageView?

    init(item: ClipItem, shortcut: Int?) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.cardW, height: Theme.cardH))
        wantsLayer = true
        layer?.cornerRadius = Theme.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.cardBody.cgColor
        buildHeader()
        buildBody()
        buildFooter(shortcut: shortcut)
        updateBorder(animated: false)
        item.onThumbnailReady = { [weak self] in self?.refreshThumbnail() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var W: CGFloat { Theme.cardW }
    private var bodyTop: CGFloat { Theme.cardHeaderH }
    private var bodyH: CGFloat { Theme.cardH - Theme.cardHeaderH - Theme.cardFooterH }

    private func buildHeader() {
        let app = AppStyle.lookup(item.record.appBundleID)
        let color: NSColor
        if let c = app?.color { color = c } else {
            switch item.record.kind {
            case .text: color = Theme.textColor
            case .image: color = Theme.imageColor
            case .file: color = Theme.fileColor
            }
        }
        let header = NSView(frame: NSRect(x: 0, y: 0, width: W, height: Theme.cardHeaderH))
        header.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = header.bounds
        grad.colors = [(color.blended(withFraction: 0.12, of: .white) ?? color).cgColor, color.cgColor]
        grad.startPoint = CGPoint(x: 0, y: 1)
        grad.endPoint = CGPoint(x: 1, y: 0)
        header.layer?.addSublayer(grad)
        addSubview(header)

        let iconSize: CGFloat = 36
        let textW = W - 14 - 14 - iconSize - 6
        let title = makeLabel(item.title, size: 13, weight: .semibold, color: .white)
        title.frame = NSRect(x: 14, y: 10, width: textW, height: 18)
        addSubview(title)

        let time = makeLabel(relativeTime(item.record.date), size: 11, weight: .medium,
                             color: NSColor(white: 1, alpha: 0.78))
        time.frame = NSRect(x: 14, y: 28, width: textW, height: 16)
        time.toolTip = item.record.appName
        addSubview(time)

        let iconFrame = NSRect(x: W - 12 - iconSize, y: (Theme.cardHeaderH - iconSize) / 2, width: iconSize, height: iconSize)
        let iv = NSImageView(frame: iconFrame)
        iv.imageScaling = .scaleProportionallyUpOrDown
        if let icon = app?.icon {
            iv.image = icon
            iv.toolTip = item.record.appName
        } else {
            let name: String
            switch item.record.kind {
            case .text: name = "text.alignleft"
            case .image: name = "photo"
            case .file: name = "doc"
            }
            iv.image = symbol(name, size: 17, weight: .medium)
            iv.contentTintColor = NSColor(white: 1, alpha: 0.9)
            iv.imageScaling = .scaleNone
        }
        addSubview(iv)
    }

    private func buildBody() {
        let bodyRect = NSRect(x: 0, y: bodyTop, width: W, height: bodyH)
        switch item.flavor {
        case .text:
            let preview = ClipCardView.previewText(item.record.text ?? "")
            let label = NSTextField(wrappingLabelWithString: preview)
            label.font = NSFont.systemFont(ofSize: 12.5)
            label.textColor = Theme.textPrimary
            label.maximumNumberOfLines = 7
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.frame = NSRect(x: 13, y: bodyTop + 11, width: W - 26, height: bodyH - 16)
            addSubview(label)

        case .link(let url):
            let icon = NSImageView(frame: NSRect(x: 13, y: bodyTop + 13, width: 18, height: 18))
            icon.image = symbol("link", size: 13, weight: .semibold)
            icon.contentTintColor = Theme.accent
            addSubview(icon)
            let host = makeLabel((url.host ?? "").replacingOccurrences(of: "www.", with: ""),
                                 size: 15, weight: .semibold)
            host.frame = NSRect(x: 13, y: bodyTop + 36, width: W - 26, height: 20)
            addSubview(host)
            let full = NSTextField(wrappingLabelWithString: item.record.text ?? "")
            full.font = NSFont.systemFont(ofSize: 11)
            full.textColor = Theme.textSecondary
            full.maximumNumberOfLines = 4
            full.lineBreakMode = .byCharWrapping
            full.cell?.truncatesLastVisibleLine = true
            full.frame = NSRect(x: 13, y: bodyTop + 60, width: W - 26, height: 66)
            addSubview(full)

        case .color(let c, let hex):
            let sw = NSView(frame: bodyRect.insetBy(dx: 10, dy: 10))
            sw.wantsLayer = true
            sw.layer?.backgroundColor = c.cgColor
            sw.layer?.cornerRadius = 8
            sw.layer?.borderWidth = 0.5
            sw.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
            addSubview(sw)
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            let l = makeLabel(hex, size: 15, weight: .semibold, color: lum > 0.6 ? .black : .white)
            l.alignment = .center
            l.sizeToFit()
            l.frame = NSRect(x: 0, y: (sw.bounds.height - l.frame.height) / 2, width: sw.bounds.width, height: l.frame.height)
            sw.addSubview(l)

        case .image:
            let tv = FillImageView(frame: bodyRect)
            tv.image = item.thumbnail
            addSubview(tv)
            thumbView = tv

        case .video, .picture, .pdf:
            if item.thumbnail != nil {
                showThumbnail()
            } else {
                buildFileIcon()
            }

        case .folder, .file, .audio, .files, .missing:
            buildFileIcon()
        }
    }

    private func buildFileIcon() {
        let iconSide: CGFloat = 64
        if case .files(let n) = item.flavor {
            // Abanico con los íconos de los primeros archivos
            let shown = Array(item.paths.prefix(3).reversed())
            for (i, p) in shown.enumerated() {
                let offset = CGFloat(i - (shown.count - 1) / 2) * 26 - (shown.count == 2 ? 13 : 0)
                let iv = NSImageView(frame: NSRect(x: (W - 58) / 2 + offset, y: bodyTop + 20, width: 58, height: 58))
                iv.image = FileManager.default.fileExists(atPath: p) ? NSWorkspace.shared.icon(forFile: p)
                                                                      : NSWorkspace.shared.icon(for: .data)
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.frameCenterRotation = CGFloat(i - (shown.count - 1) / 2) * -8
                addSubview(iv)
            }
            let first = makeLabel((item.paths.first as NSString?)?.lastPathComponent ?? "", size: 11.5, weight: .medium)
            first.alignment = .center
            first.lineBreakMode = .byTruncatingMiddle
            first.frame = NSRect(x: 12, y: bodyTop + 92, width: W - 24, height: 16)
            addSubview(first)
            let more = makeLabel("y \(n - 1) más", size: 11, color: Theme.textSecondary)
            more.alignment = .center
            more.frame = NSRect(x: 12, y: bodyTop + 109, width: W - 24, height: 15)
            addSubview(more)
            return
        }
        let iv = NSImageView(frame: NSRect(x: (W - iconSide) / 2, y: bodyTop + 16, width: iconSide, height: iconSide))
        iv.imageScaling = .scaleProportionallyUpOrDown
        if case .missing = item.flavor {
            iv.image = symbol("exclamationmark.triangle", size: 34)
            iv.contentTintColor = NSColor.systemYellow
            iv.imageScaling = .scaleNone
        } else {
            iv.image = item.fileIcon ?? NSWorkspace.shared.icon(for: .data)
        }
        addSubview(iv)

        let name = (item.paths.first as NSString?)?.lastPathComponent ?? "Archivo"
        let label = NSTextField(wrappingLabelWithString: name)
        label.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = Theme.textPrimary
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byCharWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.frame = NSRect(x: 12, y: bodyTop + 88, width: W - 24, height: 34)
        addSubview(label)
    }

    private func showThumbnail() {
        let bodyRect = NSRect(x: 0, y: bodyTop, width: W, height: bodyH)
        let tv = FillImageView(frame: bodyRect)
        tv.image = item.thumbnail
        addSubview(tv)
        thumbView = tv

        let name = makeLabel((item.paths.first as NSString?)?.lastPathComponent ?? "", size: 11, weight: .medium, color: .white)
        name.lineBreakMode = .byTruncatingMiddle
        let shade = NSView(frame: NSRect(x: 0, y: bodyTop + bodyH - 26, width: W, height: 26))
        shade.wantsLayer = true
        let g = CAGradientLayer()
        g.frame = shade.bounds
        g.colors = [NSColor(white: 0, alpha: 0.65).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        shade.layer?.addSublayer(g)
        addSubview(shade)
        name.frame = NSRect(x: 10, y: bodyTop + bodyH - 21, width: W - 20, height: 15)
        addSubview(name)

        if case .video = item.flavor {
            let side: CGFloat = 38
            let play = NSView(frame: NSRect(x: (W - side) / 2, y: bodyTop + (bodyH - side) / 2 - 6, width: side, height: side))
            play.wantsLayer = true
            play.layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
            play.layer?.cornerRadius = side / 2
            play.layer?.borderWidth = 1
            play.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
            let pv = NSImageView(frame: play.bounds.offsetBy(dx: 1.5, dy: 0))
            pv.image = symbol("play.fill", size: 15, weight: .bold)
            pv.contentTintColor = .white
            pv.imageScaling = .scaleNone
            play.addSubview(pv)
            addSubview(play)
        }
    }

    private func refreshThumbnail() {
        if let tv = thumbView {
            tv.image = item.thumbnail
            return
        }
        switch item.flavor {
        case .video, .picture, .pdf:
            // Reemplaza el ícono provisional por la miniatura real
            let keep = subviews.filter { $0.frame.minY < bodyTop || $0.frame.minY >= bodyTop + bodyH }
            subviews.filter { !keep.contains($0) }.forEach { $0.removeFromSuperview() }
            showThumbnail()
        default:
            break
        }
    }

    private func buildFooter(shortcut: Int?) {
        let footer = NSView(frame: NSRect(x: 0, y: Theme.cardH - Theme.cardFooterH, width: W, height: Theme.cardFooterH))
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.cardFooter.cgColor
        let line = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 0.5))
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.hairline.cgColor
        footer.addSubview(line)
        addSubview(footer)

        var infoW = W - 26
        if let n = shortcut {
            let cap = makeKeycap("⌘\(n)")
            cap.frame.origin = NSPoint(x: W - 11 - cap.frame.width, y: Theme.cardH - Theme.cardFooterH + 5.5)
            addSubview(cap)
            infoW -= cap.frame.width + 8
        }
        let info = makeLabel(item.info, size: 10.5, weight: .medium, color: Theme.textSecondary)
        info.lineBreakMode = .byTruncatingMiddle
        info.frame = NSRect(x: 13, y: Theme.cardH - Theme.cardFooterH + 6, width: infoW, height: 15)
        addSubview(info)
    }

    static func previewText(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 500 { t = String(t.prefix(500)) }
        t = t.replacingOccurrences(of: "\t", with: "   ")
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return t
    }

    // ---------- Estados: selección / hover / clic ----------

    private func updateBorder(animated: Bool) {
        guard let layer = layer else { return }
        let width: CGFloat
        let color: CGColor
        if isSelected {
            width = 3; color = Theme.accent.cgColor
        } else if hovering {
            width = 1.5; color = NSColor(white: 1, alpha: 0.35).cgColor
        } else {
            width = 1; color = NSColor(white: 1, alpha: 0.07).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        layer.borderWidth = width
        layer.borderColor = color
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateBorder(animated: true) }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        setPressed(false)
        updateBorder(animated: true)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { setPressed(true) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = pressed
        setPressed(false)
        guard inside && wasPressed else { return }
        if event.clickCount >= 2 { onClick?() } else { onSelect?() }
    }

    private func setPressed(_ p: Bool) {
        pressed = p
        alphaValue = p ? 0.82 : 1
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

// =====================================================================
// MARK: - Scroll horizontal (la rueda del mouse también desplaza de lado)
// =====================================================================

final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
        var origin = contentView.bounds.origin
        let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        origin.x = min(max(0, origin.x - event.scrollingDeltaY * factor), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

// =====================================================================
// MARK: - La barra flotante
// =====================================================================

final class BarPanel: NSPanel {
    // Puede recibir teclado (buscar, flechas, Enter) sin activar la app:
    // la app donde estabas escribiendo sigue siendo la app activa.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class BarController: NSObject, NSSearchFieldDelegate, NSMenuDelegate {
    let history: ClipHistory
    let panel: BarPanel
    private let root = FlippedView()
    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private let logo = NSView()
    private let titleLabel = makeLabel("OkiPaste", size: 14, weight: .bold, color: .white)
    private let countLabel = makeLabel("", size: 11, weight: .medium, color: Theme.textTertiary)
    private let searchField = NSSearchField()
    private var hintsView = NSView()
    private let scroll = HorizontalScrollView()
    private let docView = FlippedView()
    private let emptyView = FlippedView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = makeLabel("", size: 14, weight: .semibold, color: Theme.textPrimary)
    private let emptySub = makeLabel("", size: 12, color: Theme.textSecondary)

    private(set) var isShown = false
    private var cards: [ClipCardView] = []
    private(set) var visibleItems: [ClipItem] = []
    private(set) var selectedIndex = 0
    private(set) var previousApp: NSRunningApplication?
    private var monitors: [Any] = []
    private var workspaceObserver: Any?
    private var showGeneration = 0

    init(history: ClipHistory) {
        self.history = history
        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.barMinW, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .none
        buildUI()
        history.onChange = { [weak self] in
            guard let self = self, self.isShown else { return }
            self.applyFilter(keepSelection: true)
        }
    }

    // ---------- Construcción ----------

    private func buildUI() {
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = BarController.roundedMask(radius: Theme.barRadius)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.42).cgColor
        tint.layer?.cornerRadius = Theme.barRadius
        tint.layer?.borderWidth = 1
        tint.layer?.borderColor = NSColor(white: 1, alpha: 0.11).cgColor
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)

        root.autoresizingMask = [.width, .height]
        effect.addSubview(root)

        // Logo
        logo.frame = NSRect(x: Theme.pad, y: 16, width: 26, height: 26)
        logo.wantsLayer = true
        let g = CAGradientLayer()
        g.frame = logo.bounds
        g.cornerRadius = 7
        g.cornerCurve = .continuous
        let accent = Theme.accent
        g.colors = [(accent.blended(withFraction: 0.25, of: .white) ?? accent).cgColor, accent.cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        logo.layer?.addSublayer(g)
        let glyph = NSImageView(frame: logo.bounds)
        glyph.image = symbol("doc.on.clipboard.fill", size: 12.5, weight: .semibold)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleNone
        logo.addSubview(glyph)
        root.addSubview(logo)

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: Theme.pad + 36, y: 20)
        root.addSubview(titleLabel)
        root.addSubview(countLabel)

        searchField.placeholderString = "Buscar"
        searchField.font = NSFont.systemFont(ofSize: 12.5)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        root.addSubview(searchField)

        hintsView = BarController.makeHints()
        root.addSubview(hintsView)

        docView.frame = NSRect(x: 0, y: 0, width: 100, height: Theme.cardH)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.documentView = docView
        root.addSubview(scroll)

        emptyIcon.imageScaling = .scaleNone
        emptyIcon.contentTintColor = Theme.textTertiary
        emptyTitle.alignment = .center
        emptySub.alignment = .center
        emptyView.addSubview(emptyIcon)
        emptyView.addSubview(emptyTitle)
        emptyView.addSubview(emptySub)
        root.addSubview(emptyView)
    }

    static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    static func makeHints() -> NSView {
        let v = FlippedView()
        var x: CGFloat = 0
        for (key, text) in [("← →", "elegir"), ("↩", "pegar"), ("esc", "cerrar")] {
            let cap = makeKeycap(key)
            cap.frame.origin = NSPoint(x: x, y: 0)
            v.addSubview(cap)
            x += cap.frame.width + 5
            let l = makeLabel(text, size: 11, weight: .medium, color: Theme.textTertiary)
            l.sizeToFit()
            l.frame.origin = NSPoint(x: x, y: (17 - l.frame.height) / 2)
            v.addSubview(l)
            x += l.frame.width + 14
        }
        v.frame = NSRect(x: 0, y: 0, width: x - 14, height: 17)
        return v
    }

    private func layout(width W: CGFloat) {
        let H = panel.frame.height
        root.frame = NSRect(x: 0, y: 0, width: W, height: H)
        tint.frame = root.frame

        let searchW: CGFloat = 210
        let searchH = searchField.intrinsicContentSize.height > 0 ? searchField.intrinsicContentSize.height : 22
        searchField.frame = NSRect(x: W - Theme.pad - searchW, y: 29 - searchH / 2, width: searchW, height: searchH)

        countLabel.stringValue = history.items.isEmpty ? "" : "\(history.items.count) de \(history.maxItems)"
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: titleLabel.frame.maxX + 8, y: 21.5)

        let hintsX = searchField.frame.minX - 20 - hintsView.frame.width
        hintsView.frame.origin = NSPoint(x: hintsX, y: 20.5)
        hintsView.isHidden = hintsX < countLabel.frame.maxX + 24

        scroll.frame = NSRect(x: 0, y: Theme.barHeaderH, width: W, height: Theme.cardH)
        emptyView.frame = scroll.frame
    }

    // ---------- Contenido ----------

    @objc private func searchChanged() { applyFilter(keepSelection: false) }
    func controlTextDidChange(_ obj: Notification) { applyFilter(keepSelection: false) }

    func applyFilter(keepSelection: Bool) {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let previous = keepSelection && visibleItems.indices.contains(selectedIndex) ? visibleItems[selectedIndex] : nil
        visibleItems = q.isEmpty ? history.items : history.items.filter {
            $0.searchText.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if let p = previous, let i = visibleItems.firstIndex(where: { $0 === p }) {
            selectedIndex = i
        } else {
            selectedIndex = 0
        }
        rebuildCards(animated: false)
        layout(width: panel.frame.width)
    }

    private func rebuildCards(animated: Bool) {
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()

        let n = visibleItems.count
        let contentW = Theme.pad * 2 + CGFloat(n) * Theme.cardW + CGFloat(max(0, n - 1)) * Theme.cardGap
        let viewW = panel.frame.width
        docView.frame = NSRect(x: 0, y: 0, width: max(contentW, viewW), height: Theme.cardH)
        let startX = contentW < viewW ? (viewW - contentW) / 2 + Theme.pad : Theme.pad

        for (i, item) in visibleItems.enumerated() {
            let card = ClipCardView(item: item, shortcut: i < 9 ? i + 1 : nil)
            card.frame.origin = NSPoint(x: startX + CGFloat(i) * (Theme.cardW + Theme.cardGap), y: 0)
            card.isSelected = i == selectedIndex
            card.onClick = { [weak self, weak item] in
                guard let self = self, let item = item else { return }
                self.paste(item, plainText: false)
            }
            card.onSelect = { [weak self] in self?.setSelection(i) }
            card.menuProvider = { [weak self, weak item] in
                guard let item = item else { return nil }
                return self?.contextMenu(for: item)
            }
            docView.addSubview(card)
            cards.append(card)

            if animated && i < 10 {
                card.layer?.add(BarController.entrance(delay: Double(i) * 0.022), forKey: "entrance")
            }
        }

        emptyView.isHidden = n > 0
        if n == 0 { configureEmpty() }
        if !cards.isEmpty { scrollTo(selectedIndex, animated: false) }
    }

    private static func entrance(delay: Double) -> CAAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -14
        move.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, move]
        group.duration = 0.34
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        return group
    }

    private func configureEmpty() {
        let searching = !searchField.stringValue.isEmpty
        emptyIcon.image = symbol(searching ? "magnifyingglass" : "doc.on.clipboard", size: 30, weight: .light)
        emptyTitle.stringValue = searching ? "Sin resultados" : "Tu historial está vacío"
        emptySub.stringValue = searching ? "No hay nada que coincida con «\(searchField.stringValue)»"
                                         : "Copia texto, imágenes o archivos y aparecerán aquí"
        let w = emptyView.frame.width
        emptyIcon.frame = NSRect(x: 0, y: 58, width: w, height: 40)
        emptyTitle.frame = NSRect(x: 20, y: 108, width: w - 40, height: 20)
        emptySub.frame = NSRect(x: 20, y: 132, width: w - 40, height: 18)
    }

    private func setSelection(_ i: Int) {
        guard !cards.isEmpty else { return }
        let new = min(max(0, i), cards.count - 1)
        if cards.indices.contains(selectedIndex) { cards[selectedIndex].isSelected = false }
        selectedIndex = new
        cards[new].isSelected = true
        scrollTo(new, animated: true)
    }

    private func scrollTo(_ i: Int, animated: Bool) {
        guard cards.indices.contains(i) else { return }
        let clip = scroll.contentView
        let f = cards[i].frame
        var o = clip.bounds.origin
        let vw = clip.bounds.width
        if f.minX - Theme.pad < o.x { o.x = f.minX - Theme.pad }
        else if f.maxX + Theme.pad > o.x + vw { o.x = f.maxX + Theme.pad - vw }
        o.x = min(max(0, o.x), max(0, docView.frame.width - vw))
        guard o.x != clip.bounds.origin.x else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(o)
            }
        } else {
            clip.setBoundsOrigin(o)
        }
        scroll.reflectScrolledClipView(clip)
    }

    // ---------- Mostrar / ocultar ----------

    func toggle() { isShown ? hide() : show() }

    /// passive = true: se muestra sin tomar el teclado (solo para pruebas de diagnóstico).
    func show(passive: Bool = false) {
        guard !isShown else { return }
        showGeneration += 1
        history.poll()

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame

        let n = CGFloat(history.items.count)
        let contentW = Theme.pad * 2 + n * Theme.cardW + max(0, n - 1) * Theme.cardGap
        let W = min(vis.width - 32, max(Theme.barMinW, contentW))
        let H = Theme.barHeaderH + Theme.cardH + Theme.pad
        let x = vis.midX - W / 2
        let finalFrame = NSRect(x: x, y: vis.minY + 14, width: W, height: H)

        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: -22), display: false)
        searchField.stringValue = ""
        selectedIndex = 0
        visibleItems = history.items
        layout(width: W)
        rebuildCards(animated: true)
        scroll.contentView.setBoundsOrigin(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        panel.alphaValue = 0
        if passive {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
        }
        panel.invalidateShadow()
        isShown = true
        installMonitors()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            oklog("Barra visible: pantalla=\(screen.localizedName) frame=\(self.panel.frame) key=\(self.panel.isKeyWindow) elementos=\(self.history.items.count) appPrevia=\(self.previousApp?.localizedName ?? "ninguna")")
        })
    }

    func hide(completion: (() -> Void)? = nil) {
        guard isShown else { completion?(); return }
        isShown = false
        removeMonitors()
        let generation = showGeneration
        let target = panel.frame.offsetBy(dx: 0, dy: -16)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            // Si se volvió a abrir durante la animación de cierre, no tocar la barra nueva
            if generation == self.showGeneration && !self.isShown {
                self.panel.orderOut(nil)
                self.cards.forEach { $0.removeFromSuperview() }
                self.cards.removeAll()
            }
            oklog("Barra oculta; al frente: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            completion?()
        })
    }

    // ---------- Acciones ----------

    func paste(_ item: ClipItem, plainText: Bool) {
        guard PasteEngine.write(item, history: history, plainText: plainText) else {
            NSSound.beep()
            oklog("No se pudo pegar: el archivo original ya no existe")
            return
        }
        let target = previousApp
        hide {
            PasteEngine.pasteInto(target)
        }
    }

    func pasteSelected(plainText: Bool) {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        paste(visibleItems[selectedIndex], plainText: plainText)
    }

    func pasteVisible(at index: Int) {
        guard visibleItems.indices.contains(index) else { NSSound.beep(); return }
        paste(visibleItems[index], plainText: false)
    }

    private func contextMenu(for item: ClipItem) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, _ symbolName: String) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.representedObject = item
            mi.image = symbol(symbolName, size: 13)
            menu.addItem(mi)
        }
        add("Pegar", #selector(menuPaste(_:)), "doc.on.clipboard")
        if item.record.kind == .text && item.record.rtfFile != nil {
            add("Pegar como texto simple", #selector(menuPastePlain(_:)), "textformat")
        }
        add("Copiar sin pegar", #selector(menuCopy(_:)), "doc.on.doc")
        if item.record.kind == .file {
            add("Mostrar en Finder", #selector(menuReveal(_:)), "folder")
        }
        menu.addItem(.separator())
        add("Eliminar del historial", #selector(menuDelete(_:)), "trash")
        return menu
    }

    @objc private func menuPaste(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? ClipItem { paste(item, plainText: false) }
    }
    @objc private func menuPastePlain(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? ClipItem { paste(item, plainText: true) }
    }
    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        if PasteEngine.write(item, history: history) { hide() } else { NSSound.beep() }
    }
    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        hide()
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        history.delete(item)
    }

    // ---------- Teclado y clics ----------

    /// Devuelve true si la tecla fue manejada por la barra.
    func handleKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection([.command, .shift, .option, .control])
        switch Int(code) {
        case kVK_Escape:
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                applyFilter(keepSelection: false)
            } else {
                hide()
            }
            return true
        case kVK_LeftArrow:
            setSelection(selectedIndex - 1); return true
        case kVK_RightArrow:
            setSelection(selectedIndex + 1); return true
        case kVK_Home where mods.isEmpty:
            setSelection(0); return true
        case kVK_End where mods.isEmpty:
            setSelection(cards.count - 1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pasteSelected(plainText: mods.contains(.shift)); return true
        case kVK_Delete where mods == .command:
            if visibleItems.indices.contains(selectedIndex) { history.delete(visibleItems[selectedIndex]) }
            return true
        default:
            let digits: [Int: Int] = [kVK_ANSI_1: 0, kVK_ANSI_2: 1, kVK_ANSI_3: 2, kVK_ANSI_4: 3, kVK_ANSI_5: 4,
                                      kVK_ANSI_6: 5, kVK_ANSI_7: 6, kVK_ANSI_8: 7, kVK_ANSI_9: 8]
            if mods == .command, let i = digits[Int(code)] {
                pasteVisible(at: i)
                return true
            }
            return false
        }
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self, self.isShown else { return event }
            return self.handleKey(code: event.keyCode, flags: event.modifierFlags) ? nil : event
        }) { monitors.append(m) }

        // Clic fuera de la barra: se cierra
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.hide()
        }) { monitors.append(m) }

        // Cambiaste a otra app (⌘Tab, clic en el Dock): se cierra
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.isShown,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.processIdentifier != self.previousApp?.processIdentifier else { return }
            self.hide()
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObserver = nil
    }

    // ---------- Diagnóstico (lo usa DebugChannel) ----------

    func typeSearch(_ text: String) {
        searchField.stringValue = text
        applyFilter(keepSelection: false)
    }

    func snapshot(to url: URL) -> Bool {
        let wid = CGWindowID(panel.windowNumber)
        guard panel.isVisible,
              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .bestResolution])
        else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Arma la barra con el contenido actual y la captura fuera de cualquier pantalla real
    /// (coordenadas lejanas), para revisar el diseño sin mostrar nada en pantalla. Solo la usa
    /// el modo --snapshot de línea de comandos.
    @discardableResult
    func renderOffscreenSnapshot(to url: URL) -> Bool {
        let n = CGFloat(history.items.count)
        let contentW = Theme.pad * 2 + n * Theme.cardW + max(0, n - 1) * Theme.cardGap
        let W = max(Theme.barMinW, contentW)
        let H = Theme.barHeaderH + Theme.cardH + Theme.pad
        panel.setFrame(NSRect(x: 100_000, y: 100_000, width: W, height: H), display: false)
        searchField.stringValue = ""
        selectedIndex = 0
        visibleItems = history.items
        layout(width: W)
        rebuildCards(animated: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // deja que el servidor de ventanas componga el contenido
        let ok = snapshot(to: url)
        panel.orderOut(nil)
        return ok
    }

    func stateDictionary() -> [String: Any] {
        var onscreen = false
        if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]],
           let first = info.first {
            onscreen = (first[kCGWindowIsOnscreen as String] as? Bool) ?? false
        }
        return [
            "isShown": isShown,
            "panelVisible": panel.isVisible,
            "panelKey": panel.isKeyWindow,
            "occlusionVisible": panel.occlusionState.contains(.visible),
            "windowServerOnscreen": onscreen,
            "alpha": panel.alphaValue,
            "frame": NSStringFromRect(panel.frame),
            "items": history.items.count,
            "visibleItems": visibleItems.count,
            "selectedIndex": selectedIndex,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "previousApp": previousApp?.bundleIdentifier ?? "",
            "accessibilityTrusted": AXIsProcessTrusted(),
        ]
    }
}

// =====================================================================
// MARK: - Atajo de teclado global ⌃⌥⌘V (Carbon, no requiere permisos)
// =====================================================================

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private(set) var registered = false

    func register() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4f4b4250), id: 1) // 'OKBP'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            oklog("Atajo ⌃⌥⌘V detectado")
            mgr.onPress?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let regStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        registered = installStatus == noErr && regStatus == noErr
        oklog("Atajo registrado: \(registered) (install=\(installStatus), register=\(regStatus))")
    }
}

// =====================================================================
// MARK: - Canal de diagnóstico por archivo (para probar sin tocar la pantalla)
// =====================================================================
//
// Escribe comandos (uno por línea) en ~/OkiPaste/.cmd — la app los ejecuta y borra el archivo.
//   show [passive] | hide | toggle abrir / cerrar la barra (passive: sin tomar el teclado)
//   click N                        igual que hacer clic en la tarjeta N (1 = la más reciente)
//   copy N                         pone el elemento N en el portapapeles, sin pegar
//   key left|right|return|shift-return|esc|cmd-N|cmd-delete
//   search TEXTO                   escribir en el buscador
//   clear                          borrar todo el historial
//   snapshot                       guarda la barra en ~/OkiPaste/.debug/bar.png
//   state                          guarda el estado en ~/OkiPaste/.debug/state.json
//   pastefirst                     pega el elemento más reciente sin abrir la barra
//   hotkeytest                     simula que se aprieta ⌃⌥⌘V en el teclado
//   presscmdc / presscmda          simula ⌘C / ⌘A reales en la app que esté al frente (para
//                                  probar captura desde apps reales sin que este proceso
//                                  necesite permiso de Accesibilidad — OkiPaste ya lo tiene)

final class DebugChannel {
    let cmdFile = okiHome.appendingPathComponent(".cmd")
    let outDir = okiHome.appendingPathComponent(".debug")
    unowned let app: AppDelegate

    init(app: AppDelegate) { self.app = app }

    func check() {
        guard FileManager.default.fileExists(atPath: cmdFile.path) else { return }
        let text = (try? String(contentsOf: cmdFile, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: cmdFile)
        for line in text.split(whereSeparator: \.isNewline) {
            run(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private func run(_ line: String) {
        guard !line.isEmpty else { return }
        oklog("Diagnóstico: \(line)")
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let bar = app.bar!
        switch parts[0] {
        case "show": bar.show(passive: arg == "passive")
        case "hide": bar.hide()
        case "toggle": bar.toggle()
        case "click": bar.pasteVisible(at: (Int(arg) ?? 1) - 1)
        case "copy":
            let i = (Int(arg) ?? 1) - 1
            if app.history.items.indices.contains(i) {
                oklog("Diagnóstico copy: \(PasteEngine.write(app.history.items[i], history: app.history))")
            }
        case "search": bar.typeSearch(arg)
        case "clear": app.history.clearAll()
        case "key":
            let map: [String: (Int, NSEvent.ModifierFlags)] = [
                "left": (kVK_LeftArrow, []), "right": (kVK_RightArrow, []), "return": (kVK_Return, []),
                "shift-return": (kVK_Return, .shift), "esc": (kVK_Escape, []), "cmd-delete": (kVK_Delete, .command),
                "cmd-1": (kVK_ANSI_1, .command), "cmd-2": (kVK_ANSI_2, .command), "cmd-3": (kVK_ANSI_3, .command),
            ]
            if let (code, flags) = map[arg] { _ = bar.handleKey(code: UInt16(code), flags: flags) }
        case "snapshot":
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let ok = bar.snapshot(to: outDir.appendingPathComponent("bar.png"))
            oklog("Captura de la barra: \(ok)")
        case "state":
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var st = bar.stateDictionary()
            st["hotkeyRegistered"] = app.hotKey.registered
            st["statusItemHasImage"] = app.statusItem?.button?.image != nil
            st["history"] = app.history.items.map { ["kind": $0.record.kind.rawValue, "title": $0.title, "info": $0.info,
                                                     "app": $0.record.appName ?? "", "appBundleID": $0.record.appBundleID ?? "",
                                                     "textPreview": $0.record.text.map { String($0.prefix(80)) } ?? ""] }
            if let data = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: outDir.appendingPathComponent("state.json"))
            }
        case "pastefirst":
            app.history.poll()
            if let first = app.history.items.first, PasteEngine.write(first, history: app.history) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { PasteEngine.sendCommandV() }
            }
        case "hotkeytest":
            PasteEngine.postKey(CGKeyCode(kVK_ANSI_V), flags: [.maskControl, .maskAlternate, .maskCommand])
        case "presscmdc":
            PasteEngine.postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        case "presscmda":
            PasteEngine.postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        case "pressesc":
            PasteEngine.postKey(CGKeyCode(kVK_Escape), flags: [])
        default:
            oklog("Diagnóstico: comando desconocido «\(line)»")
        }
    }
}

// =====================================================================
// MARK: - Primer arranque (instalación arrastrando a Aplicaciones)
// =====================================================================

enum FirstRun {
    static let devLaunchAgent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.alejandro.okipaste.plist")
    static let welcomeMarker = okiHome.appendingPathComponent(".bienvenida")

    /// true en la Mac de un amigo; false en la instalación original (arranca por LaunchAgent).
    static var isStandaloneInstall: Bool {
        !FileManager.default.fileExists(atPath: devLaunchAgent.path)
    }

    /// Abierta directo desde el .dmg o desde Descargas sin mover (macOS la "traslada" a una ruta temporal).
    static var isRunningFromDiskImage: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    static var isFirstLaunch: Bool {
        !FileManager.default.fileExists(atPath: welcomeMarker.path)
    }

    static func askToMoveToApplications() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Primero arrastra OkiPaste a Aplicaciones"
        alert.informativeText = "En la ventana donde viene OkiPaste, arrastra su ícono a la carpeta Aplicaciones. Después ábrelo desde Aplicaciones (o con Launchpad)."
        alert.addButton(withTitle: "Entendido")
        alert.runModal()
        exit(0)
    }

    /// Hace que OkiPaste se abra solo al encender la Mac.
    static func enableOpenAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            guard service.status != .enabled else { return }
            do {
                try service.register()
                oklog("Abrir al iniciar sesión: activado")
            } catch {
                oklog("No se pudo activar abrir al iniciar sesión: \(error)")
            }
        } else {
            let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            let plist = agents.appendingPathComponent("com.alejandro.okipaste.login.plist")
            guard !FileManager.default.fileExists(atPath: plist.path) else { return }
            let dict: [String: Any] = [
                "Label": "com.alejandro.okipaste.login",
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? data.write(to: plist)
                oklog("Abrir al iniciar sesión: activado (LaunchAgent)")
            }
        }
    }

    /// Quita todo sin pelear con Finder: inicio automático, historial, permiso y la app misma.
    static func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¿Desinstalar OkiPaste?"
        alert.informativeText = "Se quitará de tu Mac junto con tu historial. Puedes volver a instalarla cuando quieras."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Desinstalar")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        oklog("Desinstalando OkiPaste")
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }
        let fm = FileManager.default
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.alejandro.okipaste.login.plist"))
        try? fm.removeItem(at: okiHome)

        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.alejandro.okipaste"]
        try? tcc.run()
        tcc.waitUntilExit()

        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appURL]) { _, error in
            DispatchQueue.main.async {
                if error != nil {
                    // Sin permiso para moverla: la muestra en Finder para arrastrarla (ya no está en uso)
                    NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    let fallback = NSAlert()
                    fallback.messageText = "Último paso"
                    fallback.informativeText = "OkiPaste ya se cerró. Arrástrala a la Papelera desde la ventana que se abrió."
                    fallback.addButton(withTitle: "OK")
                    fallback.runModal()
                } else {
                    let done = NSAlert()
                    done.messageText = "OkiPaste se desinstaló"
                    done.informativeText = "Ya está en la Papelera. ¡Gracias por probarla!"
                    done.addButton(withTitle: "OK")
                    done.runModal()
                }
                exit(0)
            }
        }
    }

    static func showWelcome() {
        try? FileManager.default.createDirectory(at: okiHome, withIntermediateDirectories: true)
        try? "".write(to: welcomeMarker, atomically: true, encoding: .utf8)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "¡OkiPaste ya está funcionando!"
        alert.informativeText = """
        Copia cosas como siempre y OkiPaste las irá guardando.

        Para ver tu historial presiona:
        Control + Opción + Comando + V

        También está el ícono del clip arriba, en la barra de menú.

        Al cerrar este aviso, macOS te pedirá el permiso de Accesibilidad: actívalo para que OkiPaste pueda pegar por ti.
        """
        alert.addButton(withTitle: "Continuar")
        alert.runModal()
    }
}

// =====================================================================
// MARK: - App
// =====================================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let history = ClipHistory()
    var bar: BarController!
    let hotKey = HotKeyManager()
    var statusItem: NSStatusItem?
    private var timer: Timer?
    private var debug: DebugChannel!
    private var screenshotWatcher: ScreenshotWatcher?
    private var activity: NSObjectProtocol?
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            oklog("Ya hay otra copia de OkiPaste abierta — le pide mostrar el historial y esta se cierra")
            try? "show\n".write(to: okiHome.appendingPathComponent(".cmd"), atomically: true, encoding: .utf8)
            exit(0)
        }

        oklog("Arrancando OkiPaste \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")")
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        // Evita que macOS "duerma" la app (App Nap) y se pierdan copias rápidas
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Historial de portapapeles")

        bar = BarController(history: history)
        debug = DebugChannel(app: self)

        hotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.bar.toggle() }
        }
        hotKey.register()

        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.debug.check()
            self?.history.poll()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        screenshotWatcher = ScreenshotWatcher()

        setupStatusItem()
        if FirstRun.isStandaloneInstall {
            // Copia instalada arrastrando a Aplicaciones (no la de desarrollo con LaunchAgent)
            if FirstRun.isRunningFromDiskImage {
                FirstRun.askToMoveToApplications()
                return
            }
            FirstRun.enableOpenAtLogin()
            if FirstRun.isFirstLaunch {
                FirstRun.showWelcome()
            }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        oklog("Listo. Pantallas: \(NSScreen.screens.map { $0.localizedName }) · Accesibilidad: \(AXIsProcessTrusted())")
    }

    /// Menú Edición oculto: hace que ⌘C / ⌘V / ⌘A funcionen dentro del buscador.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "OkiPaste")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            img?.isTemplate = true
            button.image = img
            button.toolTip = "OkiPaste — ⌃⌥⌘V"
        }
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "Mostrar historial", action: #selector(openBar), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.control, .option, .command]
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        infoItem.isEnabled = false
        menu.addItem(infoItem)
        let clear = NSMenuItem(title: "Borrar historial ahora", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Salir de OkiPaste", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        if FirstRun.isStandaloneInstall {
            let uninstall = NSMenuItem(title: "Desinstalar OkiPaste…", action: #selector(uninstall), keyEquivalent: "")
            uninstall.target = self
            menu.addItem(uninstall)
        }
        item.menu = menu
        statusItem = item
        oklog("Ícono de barra de menú listo: \(item.button?.image != nil)")
    }

    func menuWillOpen(_ menu: NSMenu) {
        let n = history.items.count
        infoItem.title = n == 0 ? "Historial vacío" : "\(n) de \(history.maxItems) elementos · se borra cada día"
    }

    @objc private func openBar() {
        // Espera a que se cierre el menú para que la barra reciba el teclado
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.bar.show() }
    }
    @objc private func clearHistory() { history.clearAll() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func uninstall() { FirstRun.uninstall() }
}

// =====================================================================
// MARK: - Pruebas de línea de comandos (no tocan el portapapeles ni la app real)
// =====================================================================
//
// swiftc -O main.swift -o pruebas_bin && ./pruebas_bin --selftest
// swiftc -O main.swift -o pruebas_bin && ./pruebas_bin --snapshot /ruta/salida.png
//
// Ambas usan un NSPasteboard con nombre propio y una carpeta temporal — nunca
// NSPasteboard.general ni ~/OkiPaste/Historial — y corren como binario aparte,
// sin afectar la copia de OkiPaste que ya está corriendo.

private func testLog(_ ok: Bool, _ label: String) -> Bool {
    print(ok ? "OK  - \(label)" : "MAL - \(label)")
    return ok
}

private func makeFakeImagePNG() -> Data {
    let size = NSSize(width: 40, height: 40)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.6, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

func runSelfTests() -> Bool {
    var allOK = true
    let pb = NSPasteboard(name: NSPasteboard.Name("com.alejandro.okipaste.pruebas"))
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("OkiPastePruebas-\(Int(Date().timeIntervalSince1970))")
    defer { try? FileManager.default.removeItem(at: base) }

    // ---- Captura de texto, imagen, y deduplicado ----
    let h1 = ClipHistory(dir: base.appendingPathComponent("captura"), pasteboard: pb)
    pb.clearContents(); pb.setString("hola mundo", forType: .string)
    h1.poll()
    allOK = testLog(h1.items.count == 1 && h1.items.first?.record.text == "hola mundo", "captura texto") && allOK

    pb.clearContents(); pb.setData(makeFakeImagePNG(), forType: .png)
    h1.poll()
    let imgDeadline = Date().addingTimeInterval(2)
    while h1.items.count < 2 && Date() < imgDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    allOK = testLog(h1.items.count == 2 && h1.items.first?.record.kind == .image, "captura imagen") && allOK

    pb.clearContents(); pb.setString("hola mundo", forType: .string)
    h1.poll()
    allOK = testLog(h1.items.count == 2 && h1.items.first?.record.text == "hola mundo",
                    "recopiar el mismo texto lo sube al tope sin duplicar") && allOK

    // ---- Límite de 25 elementos ----
    let h2 = ClipHistory(dir: base.appendingPathComponent("limite"), pasteboard: pb)
    for i in 0..<30 {
        pb.clearContents(); pb.setString("elemento \(i)", forType: .string)
        h2.poll()
    }
    allOK = testLog(h2.items.count == 25, "límite de 25 elementos (hay \(h2.items.count))") && allOK
    allOK = testLog(h2.items.first?.record.text == "elemento 29", "el más reciente queda primero") && allOK
    allOK = testLog(!h2.items.contains { $0.record.text == "elemento 0" }, "el más antiguo se descarta") && allOK

    // ---- Gestor de contraseñas: nunca se guarda ----
    let h4 = ClipHistory(dir: base.appendingPathComponent("privado"), pasteboard: pb)
    pb.clearContents()
    pb.setString("contraseña-secreta-123", forType: .string)
    pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    h4.poll()
    allOK = testLog(h4.items.isEmpty, "contenido marcado como confidencial (1Password, etc.) no se guarda") && allOK

    // ---- Imagen grande (varios MB) ----
    let h5 = ClipHistory(dir: base.appendingPathComponent("imagen-grande"), pasteboard: pb)
    let bigSize = NSSize(width: 3000, height: 3000)
    let bigImg = NSImage(size: bigSize)
    bigImg.lockFocus()
    NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.3, alpha: 1).setFill()
    NSRect(origin: .zero, size: bigSize).fill()
    bigImg.unlockFocus()
    let bigRep = NSBitmapImageRep(data: bigImg.tiffRepresentation!)!
    let bigPNG = bigRep.representation(using: .png, properties: [:])!
    pb.clearContents(); pb.setData(bigPNG, forType: .png)
    let t0 = Date()
    h5.poll()
    let bigDeadline = Date().addingTimeInterval(5)
    while h5.items.count < 1 && Date() < bigDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let elapsed = Date().timeIntervalSince(t0)
    allOK = testLog(h5.items.count == 1 && h5.items.first?.record.kind == .image,
                    "imagen grande (\(bigPNG.count / 1024) KB) se captura") && allOK
    allOK = testLog(elapsed < 3, "imagen grande no bloquea (\(String(format: "%.2f", elapsed))s)") && allOK

    // ---- Borrado diario ----
    let dirPurga = base.appendingPathComponent("purga")
    let h3a = ClipHistory(dir: dirPurga, pasteboard: pb)
    pb.clearContents(); pb.setString("de ayer", forType: .string)
    h3a.poll()
    allOK = testLog(h3a.items.count == 1, "hay un elemento antes de purgar") && allOK
    try? "2000-01-01".write(to: dirPurga.appendingPathComponent(".ultima_limpieza"), atomically: true, encoding: .utf8)
    let h3b = ClipHistory(dir: dirPurga, pasteboard: pb) // al crear la instancia, detecta que cambió el día
    allOK = testLog(h3b.items.isEmpty, "se vacía solo al detectar que cambió el día") && allOK

    // ---- Vigilancia de capturas de pantalla ----
    let capturaDir = base.appendingPathComponent("capturas-pantalla")
    try? FileManager.default.createDirectory(at: capturaDir, withIntermediateDirectories: true)
    let watcher = ScreenshotWatcher(directory: capturaDir, pasteboard: pb)
    allOK = testLog(watcher != nil, "ScreenshotWatcher arranca sobre una carpeta de prueba") && allOK

    let capturaFile = capturaDir.appendingPathComponent("Captura de pantalla de prueba.png")
    try? makeFakeImagePNG().write(to: capturaFile)
    let marker = "true"
    _ = marker.withCString { setxattr(capturaFile.path, "com.apple.metadata:kMDItemIsScreenCapture", $0, marker.utf8.count, 0, 0) }
    pb.clearContents()
    let pasteDeadline = Date().addingTimeInterval(3)
    while pb.data(forType: .png) == nil && Date() < pasteDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    allOK = testLog(pb.data(forType: .png) != nil, "una captura de pantalla nueva se copia sola al portapapeles") && allOK

    pb.clearContents()
    let archivoNormal = capturaDir.appendingPathComponent("foto cualquiera.png")
    try? makeFakeImagePNG().write(to: archivoNormal)
    Thread.sleep(forTimeInterval: 1.0)
    allOK = testLog(pb.data(forType: .png) == nil, "un PNG que no es captura de pantalla se ignora") && allOK
    _ = watcher

    print(allOK ? "\nTODAS LAS PRUEBAS PASARON" : "\nALGUNA PRUEBA FALLÓ")
    return allOK
}

func runOffscreenSnapshot(to url: URL) -> Bool {
    NSApplication.shared.setActivationPolicy(.accessory)
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("OkiPasteSnapshot-\(Int(Date().timeIntervalSince1970))")
    defer { try? FileManager.default.removeItem(at: base) }
    let pb = NSPasteboard(name: NSPasteboard.Name("com.alejandro.okipaste.snapshot"))
    let h = ClipHistory(dir: base, pasteboard: pb)

    func addText(_ s: String) {
        pb.clearContents(); pb.setString(s, forType: .string)
        h.poll()
    }
    addText("https://www.apple.com")
    addText("#3F5C9A")
    addText("Un texto normal de ejemplo para revisar cómo se ve la tarjeta con varias líneas de contenido.")
    pb.clearContents(); pb.setData(makeFakeImagePNG(), forType: .png)
    h.poll()
    let deadline = Date().addingTimeInterval(2)
    while h.items.count < 4 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    let bar = BarController(history: h)
    let ok = bar.renderOffscreenSnapshot(to: url)
    print(ok ? "Captura guardada en \(url.path)" : "No se pudo capturar")
    return ok
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTests() ? 0 : 1)
}
if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > idx + 1 {
    exit(runOffscreenSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1])) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
