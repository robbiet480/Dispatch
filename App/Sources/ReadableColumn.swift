import SwiftUI

extension View {
    /// Plan 27: constrain content to a readable column on wide layouts.
    ///
    /// A no-op at compact widths (every iPhone width is under the cap), so
    /// iPhone rendering is pixel-identical; on iPad it stops forms, lists,
    /// and editors from stretching edge-to-edge. The inner frame caps the
    /// width, the outer one re-centers the capped content in the available
    /// space.
    func readableColumn(maxWidth: CGFloat = 640) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
