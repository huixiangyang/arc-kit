import AppKit
import ArcKitPlatform
import Combine
import Foundation

/// 菜单只读取小位图；应用和模板图标的 IconServices 查询和绘制在独立串行队列完成。
/// 跨线程共享的仅为 PNG 数据和请求集合，均由锁保护，不传递系统返回的惰性 NSImage。
public final class FinderMenuIcons: ObservableObject, @unchecked Sendable {
    struct ApplicationKey: Hashable, Sendable {
        let bundleIdentifier: String?
        let path: String?

        init(_ app: FavoriteApplication) {
            bundleIdentifier = app.bundleIdentifier
            path = app.appPath
        }
    }

    enum IconKey: Hashable, Sendable {
        case application(ApplicationKey)
        case template(NewFileTemplateIcon)
    }

    public let objectWillChange = ObservableObjectPublisher()
    private let symbols: [ArcIconName: Data]
    private let loader: @Sendable (IconKey) -> Data?
    private let queue = DispatchQueue(label: "com.archalo.arckit.finder-menu-icons", qos: .utility)
    private let lock = NSLock()
    private var images: [IconKey: Data] = [:]
    private var templates: [String: IconKey] = [:]
    private var requested: Set<IconKey> = []
    private var pending: [IconKey] = []
    private var inFlight: IconKey?
    private var loading = false

    public convenience init() { self.init(loader: Self.loadIcon) }

    init(loader: @escaping @Sendable (IconKey) -> Data?) {
        self.loader = loader
        // 固定 Lucide 资源在创建缓存时就完成绘制，首次右键也无需读取 PDF。
        symbols = Dictionary(uniqueKeysWithValues: ArcIconName.allCases.compactMap { name in
            Self.bitmapData(from: ArcIconImage.image(name), tint: Self.color(for: name)).map { (name, $0) }
        })
    }

    public func prepare(for state: FinderMenuTreeState) {
        let enabled = Set(state.modules.filter(\.isEnabled).map(\.moduleID))
        var apps = enabled.contains(.favoriteApps) ? state.favoriteApplications : []
        if enabled.contains(.terminal) { apps += state.availableTerminals.map(\.favoriteApplication) }
        let templateKeys = (enabled.contains(.newFile) ? state.fileTemplates : []).reduce(into: [String: IconKey]()) {
            $0[$1.id] = .template(NewFileTemplateIcon(template: $1))
        }
        let keys = Set(apps.map { IconKey.application(ApplicationKey($0)) }).union(templateKeys.values)
        lock.lock()
        templates = templateKeys
        requested = keys
        images = images.filter { keys.contains($0.key) }
        pending = keys.filter { images[$0] == nil && $0 != inFlight }
        let shouldStart = !loading && !pending.isEmpty
        if shouldStart { loading = true }
        lock.unlock()
        // 无论配置更新多少次，都只保留一轮后台加载与最新的待办集合。
        if shouldStart { queue.async { [weak self] in self?.loadPending() } }
    }

    public func image(for entry: FinderMenuEntry) -> NSImage? {
        switch entry {
        case let .action(descriptor): image(for: descriptor)
        case let .submenu(_, _, module, icon, _): symbol(icon ?? module?.icon)
        case .separator: nil
        }
    }

    public func image(for descriptor: FinderActionDescriptor) -> NSImage? {
        lock.lock()
        let key: IconKey?
        switch descriptor.payload {
        case let .favoriteApplication(value): key = .application(ApplicationKey(value))
        case let .terminal(value): key = .application(ApplicationKey(value.terminalApp.favoriteApplication))
        case let .templateID(id): key = templates[id]
        default: key = nil
        }
        let data = key.flatMap { images[$0] }
        lock.unlock()
        if let data, let image = Self.image(data: data) { return image }
        return symbol(descriptor.icon ?? descriptor.moduleID.icon)
    }

    private func symbol(_ name: ArcIconName?) -> NSImage? {
        guard let name, let data = symbols[name] else { return nil }
        return Self.image(data: data)
    }

    private func loadPending() {
        while true {
            lock.lock()
            guard let key = pending.popLast() else {
                loading = false
                inFlight = nil
                lock.unlock()
                return
            }
            inFlight = key
            lock.unlock()
            let data = autoreleasepool { loader(key) }
            lock.lock()
            let accepts = requested.contains(key)
            if accepts, let data { images[key] = data }
            inFlight = nil
            lock.unlock()
            if accepts, data != nil {
                DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
            }
        }
    }

    private static func loadIcon(_ key: IconKey) -> Data? {
        switch key {
        case let .application(app): loadApplicationIcon(app)
        case let .template(template): template.loadImage().flatMap { bitmapData(from: $0) }
        }
    }

    private static func loadApplicationIcon(_ key: ApplicationKey) -> Data? {
        let url: URL?
        if let path = key.path, FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else {
            url = key.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        }
        guard let url else { return nil }
        return bitmapData(from: NSWorkspace.shared.icon(forFile: url.path))
    }

    static func bitmapData(from source: NSImage, tint: NSColor? = nil) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        if let tint {
            tint.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill(using: .sourceIn)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func image(data: Data) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(bitmap)
        // Finder 会重新染色模板图像；功能图标和软件原图都必须保留已绘制的颜色。
        image.isTemplate = false
        return image
    }

    private static func color(for name: ArcIconName) -> NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch name {
        case .filePlus, .folderPlus, .table2, .checkCircle: rgb = (0.16, 0.72, 0.43)
        case .folder, .folderOpen, .folderInput, .folderCog, .archive: rgb = (0.95, 0.62, 0.16)
        case .terminal, .appWindow, .squareCode, .braces, .codeXml: rgb = (0.60, 0.40, 0.94)
        case .image, .pipette, .paintbrush, .presentation: rgb = (0.91, 0.36, 0.61)
        case .trash2, .lockKeyhole, .triangleAlert: rgb = (0.95, 0.34, 0.31)
        default: rgb = (0.16, 0.55, 0.95)
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
