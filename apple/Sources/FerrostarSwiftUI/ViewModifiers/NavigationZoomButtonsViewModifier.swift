import SwiftUI

private struct NavigationZoomButtonsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var navigationZoomButtonsVisible: Bool {
        get { self[NavigationZoomButtonsVisibleKey.self] }
        set { self[NavigationZoomButtonsVisibleKey.self] = newValue }
    }
}

public extension View {
    /// Controls the visibility of Ferrostar's on-screen zoom buttons.
    /// Pass `false` to rely on map gestures for zooming.
    /// When `true` (the default), the navigation view decides when to show the buttons.
    func navigationZoomButtonsVisible(_ visible: Bool) -> some View {
        environment(\.navigationZoomButtonsVisible, visible)
    }
}
