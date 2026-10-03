import Foundation

/// Background images bundled with the app (from Unsplash, resized to 2048px),
/// offered in the space menu's "Background Image" submenu. Photographers are
/// credited in Settings › Credits.
public struct BuiltinSpaceBackground: Identifiable, Equatable {
    /// Resource name in `BuiltinBackgrounds/` (without `.jpg`); also persisted
    /// as `SpaceImageInfo.builtinID`.
    public var id: String
    public var title: String
    public var photographer: String
    public var photoPageURL: URL

    public static let all: [BuiltinSpaceBackground] = [
        .init(id: "mountains", title: "Mountains", photographer: "Kalen Emsley", unsplashID: "Bkci_8qcdvQ"),
        .init(id: "starry-peak", title: "Starry Peak", photographer: "Benjamin Voros", unsplashID: "phIFdC6lA4E"),
        .init(id: "forest", title: "Forest", photographer: "Sebastian Unrau", unsplashID: "sp-p7uuT0tw"),
        .init(id: "ocean", title: "Ocean", photographer: "Silas Baisch", unsplashID: "ceITO2rlDgc"),
        .init(id: "aurora", title: "Aurora", photographer: "v2osk", unsplashID: "WNS__aBJjl4"),
        .init(id: "dunes", title: "Dunes", photographer: "Christian Weiss", unsplashID: "r8eL7SY3lHA"),
        .init(id: "lake", title: "Lake", photographer: "Pietro De Grandi", unsplashID: "T7K4aEPoGGk"),
        .init(id: "gradient", title: "Gradient", photographer: "Milad Fakurian", unsplashID: "E8Ufcyxz514"),
    ]

    init(id: String, title: String, photographer: String, unsplashID: String) {
        self.id = id
        self.title = title
        self.photographer = photographer
        var components = URLComponents()
        components.scheme = "https"
        components.host = "unsplash.com"
        components.path = "/photos/\(unsplashID)"
        self.photoPageURL = components.url!
    }

    var resourceURL: URL? {
        Bundle.module.url(forResource: id, withExtension: "jpg", subdirectory: "BuiltinBackgrounds")
    }
}

public extension BrowserStore {
    /// Sets a bundled image as the space background, in fade mode.
    func setBuiltinSpaceBackground(_ background: BuiltinSpaceBackground, profileID: ID<Profile>) {
        guard let url = background.resourceURL else {
            print("[SpaceBG] Missing bundled background \(background.id)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: url) else { return }
            self.setSpaceBackgroundImage(data: data, profileID: profileID, mode: .fade, builtinID: background.id)
        }
    }
}
