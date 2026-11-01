import MapLibre
import MapLibreSwiftUI
import SwiftUI
import XCTest
@testable import FerrostarMapLibreUI

final class NavigationMapViewStyleTests: XCTestCase {
    @MainActor func testHostAndNavigationCallbacksReceiveTheSameStyleOnLoadAndReload() async throws {
        let firstURL = try makeStyle()
        let secondURL = try makeStyle()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let firstLoaded = expectation(description: "Initial host style handler")
        let secondLoaded = expectation(description: "Updated host style handler")
        var internalStyle: MLNStyle?
        var internalCalls = 0
        let host = UIHostingController(rootView: map(styleURL: firstURL, internalHandler: { style in
            internalStyle = style
            internalCalls += 1
        }, hostHandler: { style in
            XCTAssertTrue(internalStyle === style)
            firstLoaded.fulfill()
        }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await fulfillment(of: [firstLoaded], timeout: 5)

        host.rootView = map(styleURL: secondURL, internalHandler: { style in
            internalStyle = style
            internalCalls += 1
        }, hostHandler: { style in
            XCTAssertTrue(internalStyle === style)
            secondLoaded.fulfill()
        })
        host.view.layoutIfNeeded()
        await fulfillment(of: [secondLoaded], timeout: 5)
        XCTAssertEqual(internalCalls, 2)
    }

    @MainActor func testNavigationCallbackWorksWithoutAHostHandler() async throws {
        let url = try makeStyle()
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = expectation(description: "Navigation handler with no host override")
        let view = NavigationMapView(styleURL: url, camera: .constant(.default()), navigationState: nil,
                                     onStyleLoaded: { _ in loaded.fulfill() })
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        await fulfillment(of: [loaded], timeout: 5)
    }

    private func makeStyle() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8).write(to: url)
        return url
    }

    @MainActor private func map(styleURL: URL, internalHandler: @escaping (MLNStyle) -> Void,
                                hostHandler: @escaping (MLNStyle) -> Void) -> some View
    {
        NavigationMapView(styleURL: styleURL, camera: .constant(.default()), navigationState: nil,
                          onStyleLoaded: internalHandler)
            .onMapStyleLoaded(hostHandler)
    }
}
