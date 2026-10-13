import SwiftUI

public extension Image {
    /// The custom `custom.wowie` SF Symbol from Core's asset catalog.
    /// Looked up by name (not a generated `ImageResource`) so it compiles under `swift build`.
    static var wowie: Image { Image("custom.wowie", bundle: .module) }
}
