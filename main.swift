// Local integrated edition, GPL-3.0-or-later. Source is bundled with the app.
import Cocoa
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import ServiceManagement

struct WallpaperItem: Codable {
    let id: String
    let title: String
    let fileName: String
    let importedFrom: String
}

struct SavedSettings: Codable {
    var items: [WallpaperItem] = []
    var selectedID: String?
    var paused = false
}

final class WallpaperPreview: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let factor = max(bounds.width / image.size.width, bounds.height / image.size.height)
        image.draw(in: NSRect(x: (bounds.width - image.size.width * factor) / 2,
                              y: (bounds.height - image.size.height * factor) / 2,
                              width: image.size.width * factor, height: image.size.height * factor),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

final class WallpaperCard: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        clip.addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let factor = max(bounds.width / image.size.width, bounds.height / image.size.height)
            image.draw(in: NSRect(x: (bounds.width - image.size.width * factor) / 2,
                                  y: (bounds.height - image.size.height * factor) / 2,
                                  width: image.size.width * factor, height: image.size.height * factor),
                       from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.75 : 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
            border.lineWidth = 3
            border.stroke()
        }
    }
}

final class WallpaperPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { orderOut(sender) }
}

final class ScreenOverlay {
    let window: OverlayWindow
    let generatedURL: URL
    let signature: String
    init(window: OverlayWindow, generatedURL: URL, signature: String) {
        self.window = window
        self.generatedURL = generatedURL
        self.signature = signature
    }
}

final class UnifiedMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private lazy var root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TransparentMenuBar", isDirectory: true)
    private var library: URL { root.appendingPathComponent("Wallpapers", isDirectory: true) }
    private var generated: URL { root.appendingPathComponent("Rendered", isDirectory: true) }
    private var settings = SavedSettings()
    private var overlays: [String: ScreenOverlay] = [:]
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var preview: NSImageView?
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var gallery: NSStackView?
    private var transparencySwitch: NSSwitch?
    private var nextButton: NSButton?
    private var timer: Timer?
    private var busy = false
    private var initialized = false
    private var status = "正在准备…"
    private var loginItem: NSMenuItem?
    private var loginDetailItem: NSMenuItem?
    private var loginError: String?

    private var selected: WallpaperItem? { settings.items.first { $0.id == settings.selectedID } }
    private var sourceURL: URL? { selected.map { library.appendingPathComponent($0.fileName) } }
    private let imageOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count == 1 else {
            NSApp.terminate(nil)
            return
        }
        do {
            for directory in [root, library, generated] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            let legacySettings = NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier?.hasSuffix(".SecondaryMenuBar") == true }
                .compactMap { app -> Data? in
                    guard let identifier = app.bundleIdentifier else { return nil }
                    return UserDefaults(suiteName: identifier)?.data(forKey: "unifiedSettings")
                }.first
            if let data = defaults.data(forKey: "unifiedSettings") ?? legacySettings,
               let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) {
                settings = saved
                settings.items.removeAll { !fm.fileExists(atPath: library.appendingPathComponent($0.fileName).path) }
                save()
            }
            if selected == nil {
                let legacyPath = defaults.string(forKey: "sourcePath")
                    ?? UserDefaults(suiteName: "com.zorth64.ClearMenuBar")?.string(forKey: "currentWallpaperPath")
                let legacyURL = legacyPath.map { URL(fileURLWithPath: $0) }
                let currentWallpapers = NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
                let candidates = [legacyURL].compactMap { $0 } + currentWallpapers
                if let candidate = candidates.first(where: isUsableOriginal) {
                    let item = try importImage(candidate)
                    settings.selectedID = item.id
                } else { settings.selectedID = settings.items.first?.id }
                save()
            }
            initialized = true
            makeMenu()
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged), name: name, object: nil)
            }
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenChanged), name: .init("com.apple.screenIsUnlocked"), object: nil)
            refresh(force: true)
            timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.refresh() }
            // Launch quietly, including at login. The panel is created only on request.
        } catch { setStatus("未启用：\(error.localizedDescription)"); makeMenu() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "unifiedSettings") }
    }

    private func managed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(generated.path + "/")
            || path.contains("/com.zorth64.ClearMenuBar/")
            || url.lastPathComponent.hasPrefix("Managed by Clear Menu Bar")
    }

    private func isUsableOriginal(_ url: URL) -> Bool {
        guard url.isFileURL, !managed(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { return false }
        return [UTType.jpeg.identifier, UTType.png.identifier].contains(type as String)
    }

    @discardableResult private func importImage(_ url: URL) throws -> WallpaperItem {
        guard isUsableOriginal(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw Failure.message("请选择可读取的静态 JPG 或 PNG 原图。")
        }
        if let existing = settings.items.first(where: {
            let stored = library.appendingPathComponent($0.fileName)
            return stored.standardizedFileURL == url.standardizedFileURL ||
                fm.contentsEqual(atPath: stored.path, andPath: url.path)
        }) { return existing }
        let id = UUID().uuidString
        let fileName = id + ((type as String) == UTType.png.identifier ? ".png" : ".jpg")
        try fm.copyItem(at: url, to: library.appendingPathComponent(fileName))
        let item = WallpaperItem(id: id, title: url.deletingPathExtension().lastPathComponent, fileName: fileName, importedFrom: url.path)
        settings.items.append(item)
        save()
        return item
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func screenKey(_ screen: NSScreen) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screenID(screen))?.takeRetainedValue() else { return String(screenID(screen)) }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func menuHeight(_ screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return max(37, screen.safeAreaInsets.top) }
        return 24
    }

    private func render(_ screen: NSScreen, sourceURL: URL) throws -> (CGImage, CGImage) {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.message("无法读取当前壁纸。") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        if orientation != 1 {
            let corrected = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
            guard let oriented = CIContext(options: [.cacheIntermediates: false]).createCGImage(corrected, from: corrected.extent) else {
                throw Failure.message("无法读取这张照片的旋转方向。")
            }
            image = oriented
        }
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        let bar = Int((menuHeight(screen) * scale).rounded())
        // Render into an RGB canvas so grayscale JPEGs also work.
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > bar,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.message("无法建立屏幕壁纸画布。") }
        // Flatten transparency against black to match the menu-bar base.
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let factor = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        context.draw(image, in: CGRect(x: (CGFloat(width) - CGFloat(image.width) * factor) / 2,
                                      y: (CGFloat(height) - CGFloat(image.height) * factor) / 2,
                                      width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
        guard let full = context.makeImage(), let top = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: bar)) else {
            throw Failure.message("无法裁剪菜单栏区域。")
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: height - bar, width: width, height: bar))
        guard let wallpaper = context.makeImage() else { throw Failure.message("无法生成屏幕专用壁纸。") }
        return (wallpaper, top)
    }

    private func prepare(_ screen: NSScreen, sourceURL: URL, signature: String) throws -> ScreenOverlay {
        let (wallpaper, top) = try render(screen, sourceURL: sourceURL)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - menuHeight(screen), width: screen.frame.width, height: menuHeight(screen))
        let content = try WallpaperOverlay(frame: NSRect(origin: .zero, size: frame.size), image: top, scale: screen.backingScaleFactor)
        let url = generated.appendingPathComponent("\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.message("无法创建屏幕壁纸文件。")
        }
        CGImageDestinationAddImage(destination, wallpaper, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("无法保存屏幕壁纸文件。") }
        let overlay = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.title = "Clear Bar · \(screen.localizedName)"
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .statusBar
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .stationary, .ignoresCycle]
        overlay.contentView = content
        return ScreenOverlay(window: overlay, generatedURL: url, signature: signature)
    }

    private func conflictingApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                ($0.bundleIdentifier == "com.zorth64.ClearMenuBar" || $0.bundleIdentifier?.hasSuffix(".SecondaryMenuBar") == true)
        }
    }

    @objc private func screenChanged() { refresh(force: true) }

    private func refresh(force: Bool = false, adoptSystemWallpaper: Bool = true) {
        guard initialized, !busy else { return }
        if !conflictingApps().isEmpty {
            setStatus("旧版工具仍在运行，点透明开关即可接管全部屏幕。")
            return
        }
        guard !settings.paused else { setStatus("透明效果已暂停，当前壁纸保留原图。") ; return }
        guard sourceURL != nil else { setStatus("选择一张壁纸，自动开启多屏透明。") ; return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            setStatus("系统“降低透明度”已打开。关闭该设置后，再点“启用透明”。")
            return
        }
        busy = true
        defer { busy = false }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        do {
            if adoptSystemWallpaper {
                for screen in screens {
                    if let current = NSWorkspace.shared.desktopImageURL(for: screen), !managed(current),
                       current.standardizedFileURL != sourceURL?.standardizedFileURL, isUsableOriginal(current) {
                        let item = try importImage(current)
                        settings.selectedID = item.id
                        save()
                        updateLibraryUI()
                        break
                    }
                }
            }
            guard let sourceURL, let selected else { throw Failure.message("请先选择一张壁纸。") }
            var candidates: [(NSScreen, String, ScreenOverlay)] = []
            // Finish all image generation and view construction before
            // changing any display. A failed preparation preserves live output.
            for screen in screens {
                let key = screenKey(screen)
                let signature = "\(selected.id):\(screen.frame):\(screen.backingScaleFactor)"
                let current = NSWorkspace.shared.desktopImageURL(for: screen)
                if !force, let active = overlays[key], active.signature == signature, current == active.generatedURL {
                    continue
                }
                candidates.append((screen, key, try prepare(screen, sourceURL: sourceURL, signature: signature)))
            }
            var applied: [(NSScreen, URL?, [NSWorkspace.DesktopImageOptionKey: Any]?, String, ScreenOverlay)] = []
            do {
                for (screen, key, candidate) in candidates {
                    let oldURL = NSWorkspace.shared.desktopImageURL(for: screen)
                    let oldOptions = NSWorkspace.shared.desktopImageOptions(for: screen)
                    try NSWorkspace.shared.setDesktopImageURL(candidate.generatedURL, for: screen, options: imageOptions)
                    candidate.window.orderFrontRegardless()
                    applied.append((screen, oldURL, oldOptions, key, candidate))
                }
            } catch {
                for (screen, oldURL, options, _, candidate) in applied.reversed() {
                    if let oldURL { try? NSWorkspace.shared.setDesktopImageURL(oldURL, for: screen, options: options ?? imageOptions) }
                    candidate.window.close()
                }
                throw error
            }
            for (_, _, _, key, candidate) in applied {
                overlays[key]?.window.close()
                overlays[key] = candidate
            }
            let present = Set(screens.map(screenKey))
            for key in Array(overlays.keys) where !present.contains(key) { overlays.removeValue(forKey: key)?.window.close() }
            setStatus("已为 \(screens.count) 块屏幕启用透明菜单栏\n" + screens.map(\.localizedName).joined(separator: " · "))
        } catch { setStatus("更换未完成：\(error.localizedDescription)\n可重新选择壁纸，或暂停透明效果。") }
    }

    @discardableResult private func restore() -> Bool {
        guard let sourceURL else { return true }
        var success = true
        for screen in NSScreen.screens {
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), current.standardizedFileURL.path.hasPrefix(generated.path + "/") {
                do { try NSWorkspace.shared.setDesktopImageURL(sourceURL, for: screen, options: imageOptions) }
                catch { success = false }
            }
        }
        if success {
            for active in overlays.values { active.window.close() }
            overlays.removeAll()
        }
        return success
    }

    private func choose(_ id: String) {
        guard settings.items.contains(where: { $0.id == id }) else { return }
        settings.selectedID = id
        settings.paused = false
        save()
        updateLibraryUI()
        refresh(force: true, adoptSystemWallpaper: false)
    }

    @objc private func chooseImage() { openImages(multiple: false) }
    @objc private func importMany() { openImages(multiple: true) }

    private func openImages(multiple: Bool) {
        let panel = NSOpenPanel()
        panel.title = multiple ? "添加壁纸：之后点“下一张”即可切换" : "选择壁纸，自动应用到全部屏幕"
        panel.prompt = multiple ? "添加并应用" : "应用到全部屏幕"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.directoryURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        do {
            var first: WallpaperItem?
            for url in panel.urls { let item = try importImage(url); if first == nil { first = item } }
            if let first { choose(first.id) }
        } catch { setStatus("无法添加：\(error.localizedDescription)") }
    }

    @objc private func nextImage() {
        guard !settings.items.isEmpty else { chooseImage(); return }
        let current = settings.items.firstIndex { $0.id == settings.selectedID } ?? -1
        choose(settings.items[(current + 1) % settings.items.count].id)
    }

    @objc private func selectFromMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { choose(id) } }
    @objc private func selectFromCard(_ sender: NSButton) { if let id = sender.identifier?.rawValue { choose(id) } }

    @objc private func togglePause() {
        if settings.paused || !conflictingApps().isEmpty {
            // This explicit user action hands ownership to the integrated app.
            for app in conflictingApps() { app.terminate() }
            settings.paused = false
            save()
            updateLibraryUI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refresh(force: true, adoptSystemWallpaper: false) }
        } else if restore() {
            settings.paused = true
            save()
            updateLibraryUI()
            setStatus("透明效果已暂停，全部屏幕保留当前壁纸原图。")
        } else { setStatus("有屏幕未能恢复原图。请重试暂停，或到系统墙纸设置选择原图。") }
    }

    @objc private func toggleLaunchAtLogin() {
        loginError = nil
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            @unknown default:
                loginError = "无法读取登录项状态"
            }
        } catch {
            loginError = "设置未完成：\(error.localizedDescription)"
        }
        updateLoginMenu()
    }

    private func updateLoginMenu() {
        let serviceStatus = SMAppService.mainApp.status
        loginItem?.state = serviceStatus == .enabled ? .on : .off
        loginItem?.title = serviceStatus == .requiresApproval
            ? "开机静默启动（需在系统设置允许）" : "开机静默启动"
        let detail = loginError ?? (serviceStatus == .requiresApproval
            ? "点击上方项目，在系统登录项中允许 Clear Bar" : nil)
        loginDetailItem?.title = detail ?? ""
        loginDetailItem?.isHidden = detail == nil
    }

    func menuWillOpen(_ menu: NSMenu) { updateLoginMenu() }

    private func makeMenu() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Clear Bar")
        }
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("更换壁纸…（全部屏幕）", #selector(chooseImage))
        add("下一张壁纸", #selector(nextImage))
        add("添加多张壁纸…", #selector(importMany))
        if !settings.items.isEmpty {
            let recent = NSMenuItem(title: "壁纸库", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for wallpaper in settings.items {
                let item = NSMenuItem(title: wallpaper.title, action: #selector(selectFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = wallpaper.id
                item.state = wallpaper.id == settings.selectedID ? .on : .off
                submenu.addItem(item)
            }
            recent.submenu = submenu
            menu.addItem(recent)
        }
        menu.addItem(.separator())
        add(settings.paused || !conflictingApps().isEmpty ? "启用透明" : "暂停透明并恢复原图", #selector(togglePause))
        add("打开壁纸面板", #selector(showWindow))
        let login = NSMenuItem(title: "开机静默启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.toolTip = "登录 Mac 后只显示菜单栏图标，不弹出页面"
        menu.addItem(login)
        loginItem = login
        let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        loginDetailItem = detail
        updateLoginMenu()
        menu.addItem(.separator())
        add("退出并恢复原图", #selector(quit))
        statusItem?.menu = menu
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func makeWindow() {
        guard window == nil else { updateLibraryUI(); return }
        let panel = WallpaperPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 470), styleMask: .borderless, backing: .buffered, defer: false)
        panel.title = "Clear Bar"
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 470))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        panel.contentView = glass
        panel.center()
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.widthAnchor.constraint(equalToConstant: 360),
            rootStack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18)
        ])
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8
        heading.addArrangedSubview(label("Clear Bar", size: 19, weight: .semibold))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.addArrangedSubview(spacer)
        let more = button("更多操作", action: #selector(showActions(_:)))
        more.isBordered = false
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多操作")
        more.imagePosition = .imageOnly
        more.toolTip = "壁纸库、暂停和恢复原图"
        heading.addArrangedSubview(more)
        let close = button("收起面板", action: #selector(hidePanel))
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "收起面板")
        close.imagePosition = .imageOnly
        close.contentTintColor = .secondaryLabelColor
        close.keyEquivalent = "\u{1b}"
        close.toolTip = "收起面板，透明效果继续运行"
        close.setAccessibilityLabel("收起面板，后台继续运行")
        close.widthAnchor.constraint(equalToConstant: 24).isActive = true
        close.heightAnchor.constraint(equalToConstant: 24).isActive = true
        heading.addArrangedSubview(close)
        rootStack.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        rootStack.addArrangedSubview(label("换张壁纸，双屏一起透明", size: 11, color: .secondaryLabelColor))
        let imageView = WallpaperPreview()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        rootStack.addArrangedSubview(imageView)
        imageView.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 136).isActive = true
        preview = imageView
        let title = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingMiddle
        rootStack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        titleLabel = title
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        let change = button("更换壁纸", action: #selector(chooseImage))
        change.keyEquivalent = "\r"
        actions.addArrangedSubview(change)
        let next = button("下一张", action: #selector(nextImage))
        actions.addArrangedSubview(next)
        nextButton = next
        let add = button("添加多张", action: #selector(importMany))
        actions.addArrangedSubview(add)
        change.widthAnchor.constraint(equalToConstant: 140).isActive = true
        next.widthAnchor.constraint(equalToConstant: 90).isActive = true
        add.widthAnchor.constraint(equalToConstant: 90).isActive = true
        rootStack.addArrangedSubview(actions)
        rootStack.addArrangedSubview(label("壁纸库 · 点选切换", size: 10, weight: .medium, color: .secondaryLabelColor))
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 8
        scroll.documentView = cards
        gallery = cards
        rootStack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let statusField = label(status.components(separatedBy: "\n").first ?? status, size: 11, color: .secondaryLabelColor)
        rootStack.addArrangedSubview(statusField)
        statusField.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        statusField.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        statusLabel = statusField
        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.addArrangedSubview(label("透明效果", size: 11))
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(togglePause)
        toggle.setAccessibilityLabel("透明效果")
        bottom.addArrangedSubview(toggle)
        transparencySwitch = toggle
        bottom.addArrangedSubview(label("关闭面板后继续运行", size: 10, color: .tertiaryLabelColor))
        rootStack.addArrangedSubview(bottom)
        window = panel
        updateLibraryUI()
    }

    private func updateLibraryUI() {
        if let sourceURL { preview?.image = NSImage(contentsOf: sourceURL) }
        titleLabel?.stringValue = selected?.title ?? "尚未选择壁纸"
        transparencySwitch?.state = settings.paused || !conflictingApps().isEmpty ? .off : .on
        nextButton?.isEnabled = settings.items.count > 1
        if let gallery {
            for view in gallery.arrangedSubviews { gallery.removeArrangedSubview(view); view.removeFromSuperview() }
            for wallpaper in settings.items {
                let card = WallpaperCard(title: wallpaper.title, target: self, action: #selector(selectFromCard(_:)))
                card.state = wallpaper.id == settings.selectedID ? .on : .off
                card.setAccessibilityLabel(wallpaper.title + (wallpaper.id == settings.selectedID ? "，当前壁纸" : ""))
                card.identifier = NSUserInterfaceItemIdentifier(wallpaper.id)
                card.toolTip = wallpaper.title
                card.image = NSImage(contentsOf: library.appendingPathComponent(wallpaper.fileName))
                card.imagePosition = .imageOnly
                card.imageScaling = .scaleProportionallyDown
                card.bezelStyle = .regularSquare
                card.font = .systemFont(ofSize: 10)
                card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                gallery.addArrangedSubview(card)
                card.widthAnchor.constraint(equalToConstant: 96).isActive = true
                card.heightAnchor.constraint(equalToConstant: 60).isActive = true
            }
            let width = CGFloat(settings.items.count) * 104
            gallery.frame = NSRect(x: 0, y: 0, width: max(width, 360), height: 62)
        }
        makeMenu()
    }

    private func setStatus(_ text: String) {
        if status != text {
            status = text
            statusLabel?.stringValue = text.components(separatedBy: "\n").first ?? text
            statusLabel?.toolTip = text
            statusItem?.button?.toolTip = text
        }
        let switchState: NSControl.StateValue = settings.paused || !conflictingApps().isEmpty ? .off : .on
        if transparencySwitch?.state != switchState { transparencySwitch?.state = switchState }
    }

    @objc private func showActions(_ sender: NSButton) {
        guard let menu = statusItem?.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc private func showWindow() {
        makeWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func hidePanel() { window?.orderOut(nil) }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard initialized else { return .terminateNow }
        if restore() { return .terminateNow }
        setStatus("暂未退出：有屏幕未能恢复原图，请点“暂停透明”重试。")
        showWindow()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = UnifiedMenuBar()
application.delegate = controller
application.run()
