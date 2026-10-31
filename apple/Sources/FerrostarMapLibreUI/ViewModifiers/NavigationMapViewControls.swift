import MapLibreSwiftDSL
import SwiftUI

private struct NavigationMapViewControlsKey: EnvironmentKey {
    static var defaultValue: [MapControl] {
        []
    }
}

public extension EnvironmentValues {
    /// Native map ornaments used by Ferrostar's map views.
    /// Empty by default to preserve the navigation UI's existing layout.
    var navigationMapViewControls: [MapControl] {
        get { self[NavigationMapViewControlsKey.self] }
        set { self[NavigationMapViewControlsKey.self] = newValue }
    }
}

public extension View {
    /// Configures native map ornaments using the MapLibre SwiftUI DSL's controls.
    ///
    /// Ferrostar leaves these controls hidden by default.
    /// Hosts can opt into attribution, a logo, or a compass and position them
    /// around their own overlays without replacing the map or its delegate.
    /// This does not change Ferrostar's navigation buttons or camera behavior.
    ///
    /// - Parameter controls: The native ornaments to display.
    @MainActor
    func navigationMapViewControls(@MapControlsBuilder _ controls: () -> [MapControl]) -> some View {
        environment(\.navigationMapViewControls, controls())
    }
}
