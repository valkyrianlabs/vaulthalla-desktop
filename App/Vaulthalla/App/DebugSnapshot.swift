#if DEBUG
import AppKit
import SwiftUI
import VHCore

/// DEBUG-only hooks so agents and scripts can check the UI without Screen Recording permission:
///
///     Vaulthalla.app/Contents/MacOS/Vaulthalla -VHDebugSelect 0:files -VHDebugSheet addNode \
///         -VHDebugSnapshot /tmp/shell.png
///
/// `-VHDebugSelect` takes `all` or `<node position>:<section>`; `-VHDebugSheet` takes `addNode` or `pair:<position>`.
/// `-VHDebugPreviewData YES` serves the preview nodes from PREVIEW DATA (`PreviewTransport`); with it,
/// `-VHDebugVault <id>` selects a vault and `-VHDebugDeleteVault YES` opens its delete sheet.
/// `-VHDebugRegistry <nodes.json>` uses another node list, and `-VHDebugPairing <phase>` shows the pairing sheet in a
/// fixed phase without contacting the node (`DebugPairing`).
/// The window renders itself to the PNG (and the sheet to `<name>.sheet.png`), then the app exits. Glass can't be
/// captured this way, so it shows as flat gray with its content drawn on top.
enum DebugSnapshot {
    static func run(model: AppModel) {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "VHDebugSnapshot") else { return }

        if let select = defaults.string(forKey: "VHDebugSelect") {
            let parts = select.split(separator: ":").map(String.init)
            if parts.first == "all" {
                model.showAllNodes()
            } else if let position = Int(parts[0]) {
                model.selectNode(atPosition: position)
                if parts.count > 1, let section = NodeSection(rawValue: parts[1]) { model.select(section) }
            }
        }
        if let sheet = defaults.string(forKey: "VHDebugSheet") {
            if sheet == "addNode" {
                model.presentAddNode()
            } else if sheet.hasPrefix("pair:"), let position = Int(sheet.dropFirst(5)), model.nodes.indices.contains(position) {
                model.presentPairing(for: model.nodes[position].id)
            }
        }

        Task {
            // `-VHDebugWindowSize 1280x1400`: resize the window first (taller than the screen is fine for a capture).
            if let size = defaults.string(forKey: "VHDebugWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2 {
                try? await Task.sleep(for: .milliseconds(300))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
                    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: size[0], height: size[1])),
                                    display: true)
                }
            }
            try? await Task.sleep(for: .seconds(2.5))
            let url = URL(filePath: path)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) {
                write(window, to: url)
                if let sheet = window.attachedSheet {
                    write(sheet, to: url.deletingPathExtension().appendingPathExtension("sheet.png"))
                }
            }
            // Not `terminate`: AppKit refuses to quit while a sheet is up, and there's nothing to save.
            exit(0)
        }
    }

    private static func hostingLeaves(in view: NSView) -> [NSView] {
        let name = String(describing: type(of: view))
        if name.hasPrefix("CellHostingView") || name.hasPrefix("NSHostingView<ModifiedContent<_ViewList_View")
            || (name.contains("HostingView") && view.subviews.isEmpty) {
            return [view]
        }
        return view.subviews.filter { !$0.isHidden }.flatMap(hostingLeaves(in:))
    }

    private static func descendants<T: NSView>(of view: NSView, ofType type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            (subview as? T).map { [$0] } ?? descendants(of: subview, ofType: type)
        }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        layer.render(in: cg)
        // Glass doesn't survive CALayer rendering (it comes out white), and vibrant text on it renders black. Stand in
        // a mid-gray fill so that text stays legible, then draw what sits on the glass.
        for glass in descendants(of: view, ofType: NSGlassEffectView.self) {
            guard let content = glass.contentView else { continue }
            cg.saveGState()
            cg.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            cg.fill(glass.convert(glass.bounds, to: view))
            cg.restoreGState()
            // Draw each SwiftUI-hosted leaf (list cells, headers, toolbar items) where it sits.
            for leaf in hostingLeaves(in: content) {
                guard let leafLayer = leaf.layer else { continue }
                let rect = leaf.convert(leaf.bounds, to: view)
                cg.saveGState()
                cg.translateBy(x: rect.minX, y: rect.maxY)
                cg.scaleBy(x: 1, y: -1)
                leafLayer.render(in: cg)
                cg.restoreGState()
            }
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
