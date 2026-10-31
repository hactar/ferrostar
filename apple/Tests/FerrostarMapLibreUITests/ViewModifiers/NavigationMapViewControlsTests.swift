import MapLibre
import MapLibreSwiftDSL
import MapLibreSwiftUI
import SwiftUI
import XCTest
@testable import FerrostarMapLibreUI

final class NavigationMapViewControlsTests: XCTestCase {
    @MainActor func testCustomOrnamentsReachTheNativeMapAndCanBeRemoved() async throws {
        let styleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8).write(to: styleURL)
        defer { try? FileManager.default.removeItem(at: styleURL) }

        let shown = expectation(description: "Custom attribution is applied")
        shown.assertForOverFulfill = false
        var initialMap: MLNMapView?
        let controls: [MapControl] = [
            AttributionButton().position(.topLeft).margins(CGPoint(x: 7, y: 9)),
            ProbingMapControl { map in
                initialMap = map
                XCTAssertFalse(map.attributionButton.isHidden)
                XCTAssertEqual(map.attributionButtonPosition, .topLeft)
                XCTAssertEqual(map.attributionButtonMargins, CGPoint(x: 7, y: 9))
                shown.fulfill()
            },
        ]
        let host = UIHostingController(rootView: map(styleURL: styleURL, controls: controls))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await fulfillment(of: [shown], timeout: 5)
        XCTAssertNotNil(initialMap)

        let hidden = expectation(description: "Removing attribution keeps the same map")
        hidden.assertForOverFulfill = false
        host.rootView = map(styleURL: styleURL, controls: [ProbingMapControl { map in
            XCTAssertTrue(map === initialMap)
            XCTAssertTrue(map.attributionButton.isHidden)
            hidden.fulfill()
        }])
        host.view.layoutIfNeeded()
        await fulfillment(of: [hidden], timeout: 5)
    }

    @MainActor private func map(styleURL: URL, controls: [MapControl]) -> some View {
        NavigationMapView(styleURL: styleURL, camera: .constant(.default()), navigationState: nil,
                          onStyleLoaded: { _ in })
            .navigationMapViewControls { controls }
    }
}

private struct ProbingMapControl: MapControl {
    var position: MLNOrnamentPosition?
    var margins: CGPoint?
    var isHidden = false
    let inspect: @MainActor (MLNMapView) -> Void

    init(_ inspect: @escaping @MainActor (MLNMapView) -> Void) {
        self.inspect = inspect
    }

    @MainActor func configureMapView(_ mapView: MLNMapView) {
        inspect(mapView)
    }
}
