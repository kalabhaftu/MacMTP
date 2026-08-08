import SwiftUI

/// Select on the initial press; reserve double-click for opening.
struct FileGridCellInteraction<Content: View>: View {
    private let onPress: () -> Void
    private let onDoubleClick: () -> Void
    private let content: Content

    @State private var didPress = false

    init(
        onPress: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onPress = onPress
        self.onDoubleClick = onDoubleClick
        self.content = content()
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !didPress else { return }
                        didPress = true
                        onPress()
                    }
                    .onEnded { _ in
                        didPress = false
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onDoubleClick()
                    }
            )
    }
}
