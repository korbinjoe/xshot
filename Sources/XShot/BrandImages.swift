import AppKit

enum BrandImages {
    static func applicationIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "XShot", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func mark() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "XShotMark", withExtension: "png", subdirectory: "Logo") else { return nil }
        let image = NSImage(contentsOf: url)
        image?.accessibilityDescription = "XShot 开角标志"
        return image
    }

    static func menuBar() -> NSImage? {
        // A multi-resolution image keeps the custom mark sharp on Retina screens.
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for filename in ["XShotTemplate", "XShotTemplate@2x"] {
            guard let url = Bundle.main.url(forResource: filename, withExtension: "png", subdirectory: "Logo"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = NSSize(width: 18, height: 18)
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "XShot 截图"
        return image
    }
}
