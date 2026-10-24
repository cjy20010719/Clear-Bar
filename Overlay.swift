// Transparent Menu Bar — local integrated edition using the 1.2 rendering technique.
// Rendering technique: https://github.com/zorth64/ClearMenuBar
// Copyright 2026. Distributed with source under GPL-3.0-or-later.
import Cocoa
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

final class WallpaperOverlay: NSVisualEffectView {
    private let backdrop = CABackdropLayer()
    private let imageGroup = CALayer()
    private let imageLayer = CALayer()
    private let tint = CALayer()
    private let invert: CAFilter
    private let hue: CAFilter

    init(frame: NSRect, image: CGImage, scale: CGFloat) throws {
        guard NSClassFromString("CABackdropLayer") != nil,
              let brightness = CAFilter(type: kCAFilterColorBrightness),
              let contrast = CAFilter(type: kCAFilterColorContrast),
              let invert = CAFilter(type: kCAFilterColorInvert),
              let hue = CAFilter(type: kCAFilterColorHueRotate) else {
            throw Failure.message("此系统的菜单栏混合功能不可用，未更改壁纸。")
        }
        self.invert = invert
        self.hue = hue
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        state = .active
        blendingMode = .behindWindow
        material = .appearanceBased
        setValue(true, forKey: "clear")

        brightness.name = "brightness"
        brightness.setValue(0.0, forKey: "inputAmount")
        contrast.name = "contrast"
        contrast.setValue(1.0, forKey: "inputAmount")
        invert.name = "invert"
        hue.name = "hue"
        hue.setValue(Double.pi, forKey: "inputAngle")
        backdrop.filters = [brightness, contrast, invert, hue]
        backdrop.masksToBounds = true
        backdrop.allowsGroupOpacity = true
        backdrop.allowsEdgeAntialiasing = false
        backdrop.disablesOccludedBackdropBlurs = true
        backdrop.ignoresOffscreenGroups = false
        backdrop.allowsInPlaceFiltering = false
        backdrop.scale = 1
        backdrop.bleedAmount = 0.1
        backdrop.windowServerAware = true
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageGroup.sublayers = [imageLayer, tint]
        layer?.sublayers = [backdrop, imageGroup]
        for item in [layer, backdrop, imageGroup, imageLayer, tint] {
            item?.contentsScale = scale
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        invert.setValue(!dark, forKey: "enabled")
        hue.setValue(!dark, forKey: "enabled")
        imageGroup.compositingFilter = CAFilter(type: dark ? kCAFilterScreenBlendMode : kCAFilterMultiplyBlendMode)
        tint.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.305) : NSColor.white.withAlphaComponent(0.4)).cgColor
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [backdrop, imageGroup, imageLayer, tint] { item.frame = bounds }
        CATransaction.commit()
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

