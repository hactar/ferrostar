import Combine
import CoreLocation
import FerrostarCoreFFI
import XCTest
@testable import FerrostarCore

final class AutomaticRerouteLifetimeTests: XCTestCase {
    @MainActor
    func testPublishedArrivalDiscardsDelayedRoutesAndClearsRecalculation() async throws {
        for usesDelegate in [false, true] {
            let fixture = Fixture(usesDelegate: usesDelegate)
            defer { fixture.stop() }
            try await startRequest(fixture)
            var completionFlags: [Bool] = []
            let completion = fixture.core.$state.sink { state in
                if let state, case .complete = state.tripState {
                    completionFlags.append(state.isCalculatingNewRoute)
                }
            }
            fixture.core.advanceToNextStep()
            try await waitUntil { fixture.core.state?.isNavigating == false }
            XCTAssertEqual(completionFlags, [false], "Publish completion once with recalculation already cleared")
            completion.cancel()
            XCTAssertEqual(fixture.core.state?.isCalculatingNewRoute, false)
            try await assertLateResultIsIgnored(fixture, result: .success([fixture.alternative]))
            assertComplete(fixture.core)
        }
    }

    @MainActor
    func testAlreadyQueuedArrivalWinsOverARerouteResponse() async throws {
        for usesDelegate in [false, true] {
            let fixture = Fixture(usesDelegate: usesDelegate)
            defer { fixture.stop() }
            try await startRequest(fixture)
            let accepted = expectation(description: "A queued arrival must win over a reroute result")
            accepted.isInverted = true
            fixture.delegate.onAlternateRoutes = { accepted.fulfill() }
            let subscription = fixture.core.$route.dropFirst().sink { route in
                if route == fixture.alternative {
                    accepted.fulfill()
                }
            }
            defer { subscription.cancel() }
            // Both actions occur in this actor turn. The provider resumes before
            // the completion update has been delivered by the core's main queue.
            fixture.provider.resolve(.success([fixture.alternative]))
            fixture.core.advanceToNextStep()
            await fulfillment(of: [fixture.provider.returned], timeout: 1)
            await fulfillment(of: [accepted], timeout: 0.15)
            assertComplete(fixture.core)
            XCTAssertEqual(fixture.core.route, mockRoute)
            XCTAssertEqual(fixture.core.state?.isCalculatingNewRoute, false)
        }
    }

    @MainActor
    func testArrivalRemainsCompleteWhenTheDelayedProviderFails() async throws {
        for usesDelegate in [false, true] {
            let fixture = Fixture(usesDelegate: usesDelegate)
            defer { fixture.stop() }
            try await startRequest(fixture)
            fixture.core.advanceToNextStep()
            try await waitUntil { fixture.core.state?.isNavigating == false }
            XCTAssertEqual(fixture.core.state?.isCalculatingNewRoute, false)
            try await assertLateResultIsIgnored(fixture, result: .failure(ProviderError.unavailable))
            assertComplete(fixture.core)
        }
    }

    @MainActor
    func testActiveReroutingStillAcceptsDefaultAndDelegateResults() async throws {
        for usesDelegate in [false, true] {
            let fixture = Fixture(usesDelegate: usesDelegate)
            defer { fixture.stop() }
            try await startRequest(fixture)
            let accepted = expectation(description: "An active session should accept its reroute")
            fixture.delegate.onAlternateRoutes = { accepted.fulfill() }
            let subscription = fixture.core.$route.dropFirst().sink { route in
                if !usesDelegate, route == fixture.alternative {
                    accepted.fulfill()
                }
            }
            defer { subscription.cancel() }
            fixture.provider.resolve(.success([fixture.alternative]))
            await fulfillment(of: [accepted], timeout: 1)
            try await waitUntil { fixture.core.state?.isCalculatingNewRoute == false }
            XCTAssertEqual(fixture.core.state?.isNavigating, true)
            XCTAssertEqual(fixture.core.route, usesDelegate ? mockRoute : fixture.alternative)
            XCTAssertEqual(fixture.delegate.alternateRouteCount, usesDelegate ? 1 : 0)
        }
    }

    @MainActor
    func testStopAndReplacementDiscardNoncooperativeProviderResults() async throws {
        for replacesSession in [false, true] {
            for usesDelegate in [false, true] {
                for providerFails in [false, true] {
                    let fixture = Fixture(usesDelegate: usesDelegate)
                    defer { fixture.stop() }
                    try await startRequest(fixture)
                    if replacesSession {
                        try fixture.core.startNavigation(route: mockRoute)
                    } else {
                        fixture.core.stopNavigation()
                    }
                    let result: Result<[Route], Error> = providerFails
                        ? .failure(ProviderError.unavailable) : .success([fixture.alternative])
                    try await assertLateResultIsIgnored(fixture, result: result)
                    XCTAssertEqual(fixture.core.state?.isNavigating == true, replacesSession)
                    XCTAssertEqual(fixture.core.route, replacesSession ? mockRoute : nil)
                }
            }
        }
    }

    @MainActor
    private func startRequest(_ fixture: Fixture) async throws {
        try fixture.core.startNavigation(route: mockRoute)
        // Manual advancement uses the latest provider event, not just the start fix.
        fixture.locations.send()
        await fulfillment(of: [fixture.provider.started], timeout: 1)
        XCTAssertEqual(fixture.core.state?.isNavigating, true)
        XCTAssertEqual(fixture.core.state?.isCalculatingNewRoute, true)
    }

    @MainActor
    private func assertLateResultIsIgnored(_ fixture: Fixture, result: Result<[Route], Error>) async throws {
        let unexpected = expectation(description: "A stale result must not reach a delegate or replace guidance")
        unexpected.isInverted = true
        fixture.delegate.onAlternateRoutes = { unexpected.fulfill() }
        let subscription = fixture.core.$route.dropFirst().sink { route in
            if route == fixture.alternative {
                unexpected.fulfill()
            }
        }
        defer { subscription.cancel() }
        fixture.provider.resolve(result)
        await fulfillment(of: [fixture.provider.returned], timeout: 1)
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(fixture.delegate.alternateRouteCount, 0)
    }

    @MainActor
    private func assertComplete(_ core: FerrostarCore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .complete = core.state?.tripState else {
            XCTFail("The completed session must stay complete", file: file, line: line)
            return
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}

private enum ProviderError: Error { case unavailable }

@MainActor
private final class Fixture {
    let provider = DelayedProvider()
    let locations = TestLocations()
    let delegate = RerouteDelegate()
    let core: FerrostarCore
    let alternative: Route

    init(usesDelegate: Bool) {
        var alternative = mockRoute
        alternative.distance += 1
        self.alternative = alternative
        let config = SwiftNavigationControllerConfig(
            waypointAdvance: .waypointWithinRange(100),
            stepAdvanceCondition: stepAdvanceManual(),
            arrivalStepAdvanceCondition: stepAdvanceManual(),
            routeDeviationTracking: .custom(detector: { _, _ in
                .deviation(kind: .completelyOffRoute(deviationFromRouteLine: 42))
            }),
            snappedLocationCourseFiltering: .raw
        )
        core = FerrostarCore(customRouteProvider: provider, locationProvider: locations,
                             navigationControllerConfig: config)
        if usesDelegate {
            core.delegate = delegate
        }
    }

    func stop() {
        core.stopNavigation()
        provider.resolve(.failure(CancellationError()))
    }
}

/// Deliberately does not cooperate with cancellation: every caller controls when
/// the result returns, including results from a session that has already ended.
@MainActor
private final class DelayedProvider: CustomRouteProvider {
    let started = XCTestExpectation(description: "The reroute request started")
    let returned = XCTestExpectation(description: "The provider returned its delayed response")
    private var continuation: CheckedContinuation<Result<[Route], Error>, Never>?

    func getRoutes(userLocation _: UserLocation, waypoints _: [Waypoint]) async throws -> [Route] {
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        returned.fulfill()
        return try result.get()
    }

    func resolve(_ result: Result<[Route], Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class TestLocations: LocationProviding {
    weak var delegate: LocationManagingDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var lastLocation: UserLocation? = UserLocation(
        coordinates: mockGeom[0], horizontalAccuracy: 5, courseOverGround: nil, timestamp: .now, speed: nil
    )
    var lastHeading: Heading?
    func startUpdating() {}
    func stopUpdating() {}
    func send() {
        if let lastLocation {
            delegate?.locationManager(self, didUpdateLocations: [lastLocation])
        }
    }
}

private final class RerouteDelegate: FerrostarCoreDelegate {
    var alternateRouteCount = 0
    var onAlternateRoutes: (() -> Void)?
    func core(_: FerrostarCore, didStartWith _: Route) {}
    func core(_: FerrostarCore, correctiveActionForDeviation _: DeviationKind,
              remainingWaypoints: [Waypoint]) -> CorrectiveAction
    {
        .getNewRoutes(waypoints: remainingWaypoints)
    }

    func core(_: FerrostarCore, loadedAlternateRoutes _: [Route]) {
        alternateRouteCount += 1
        onAlternateRoutes?()
    }
}
