import AVFoundation
import Combine
import FerrostarCoreFFI
import XCTest
@testable import FerrostarCore

final class SpokenInstructionLifetimeTests: XCTestCase {
    func testStoppedInstructionCannotSpeakAfterDelayedFocusReturns() async {
        let requested = expectation(description: "old instruction requested focus")
        let returned = expectation(description: "cancelled focus request returned")
        let unexpectedSpeech = expectation(description: "stopped instruction spoke")
        unexpectedSpeech.isInverted = true
        let audio = SuspendedAudioSession(holdRequests: true,
                                          onRequest: { _ in requested.fulfill() },
                                          onRequestReturned: { _ in returned.fulfill() })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { _ in unexpectedSpeech.fulfill() }
        let observer = makeObserver(synth: synth, audio: audio)
        observer.spokenInstructionTriggered(instruction("Old"))
        await fulfillment(of: [requested], timeout: 3)

        observer.stopAndClearQueue()
        await waitForStops(1, synth: synth)
        XCTAssertEqual(synth.stopCount, 1)
        await audio.allowRequests()
        await fulfillment(of: [returned], timeout: 3)
        await fulfillment(of: [unexpectedSpeech], timeout: 0.1)
        XCTAssertEqual(synth.spoken, [])
        let focused = await audio.hasFocus
        XCTAssertFalse(focused)
    }

    func testMuteAndUnmuteDoNotReviveSpeechWaitingForFocus() async {
        let oldRequested = expectation(description: "old instruction requested focus")
        let newRequested = expectation(description: "new instruction requested focus")
        let newSpoken = expectation(description: "new instruction spoke")
        let audio = SuspendedAudioSession(holdRequests: true, onRequest: { count in
            if count == 1 {
                oldRequested.fulfill()
            } else {
                newRequested.fulfill()
            }
        })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { text in
            XCTAssertEqual(text, "New")
            newSpoken.fulfill()
        }
        let observer = makeObserver(synth: synth, audio: audio)
        observer.spokenInstructionTriggered(instruction("Old"))
        await fulfillment(of: [oldRequested], timeout: 3)
        observer.spokenInstructionTriggered(instruction("Queued old"))
        observer.toggleMute()
        observer.spokenInstructionTriggered(instruction("Muted"))
        observer.toggleMute()
        observer.spokenInstructionTriggered(instruction("New"))
        // A new generation does not wait for the cancelled old focus request.
        await fulfillment(of: [newRequested], timeout: 3)
        await audio.allowRequests()
        await fulfillment(of: [newSpoken], timeout: 3)
        XCTAssertEqual(synth.spoken, ["New"])
        XCTAssertFalse(observer.isMuted)
        observer.stopAndClearQueue()
    }

    func testNewSpeechWaitsForPriorStopFocusCleanup() async {
        let releaseStarted = expectation(description: "stop cleanup started")
        let acquired = expectation(description: "new instruction requested focus")
        let spoken = expectation(description: "new instruction spoke")
        let audio = SuspendedAudioSession(holdReleases: true, onRequest: { _ in acquired.fulfill() },
                                          onRelease: {
                                              count in if count == 1 {
                                                  releaseStarted.fulfill()
                                              }
                                          })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { text in
            XCTAssertEqual(text, "New")
            spoken.fulfill()
        }
        let observer = makeObserver(synth: synth, audio: audio)
        observer.stopAndClearQueue()
        await fulfillment(of: [releaseStarted], timeout: 3)
        observer.spokenInstructionTriggered(instruction("New"))
        let requestsBeforeCleanup = await audio.requestCount
        XCTAssertEqual(requestsBeforeCleanup, 0)
        await audio.allowReleases()
        await fulfillment(of: [acquired, spoken], timeout: 3)
        XCTAssertEqual(synth.stopCount, 1)
        let events = await audio.events
        XCTAssertEqual(Array(events.prefix(3)), ["release:1:began", "release:1:finished", "request:1"])
        withExtendedLifetime(observer) {}
        synth.onSpeak = nil
    }

    func testRepeatedStopsFinishBeforeNewSpeechStarts() async {
        let releaseStarted = expectation(description: "first stop cleanup started")
        let spoken = expectation(description: "new instruction spoke after both stops")
        let audio = SuspendedAudioSession(holdReleases: true, onRelease: { count in
            if count == 1 {
                releaseStarted.fulfill()
            }
        })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { _ in
            XCTAssertEqual(synth.stopCount, 2)
            spoken.fulfill()
        }
        let observer = makeObserver(synth: synth, audio: audio)
        observer.stopAndClearQueue()
        await fulfillment(of: [releaseStarted], timeout: 3)
        observer.stopAndClearQueue()
        observer.spokenInstructionTriggered(instruction("New"))
        await audio.allowReleases()
        await fulfillment(of: [spoken], timeout: 3)
        XCTAssertEqual(synth.spoken, ["New"])
        let releases = await audio.releaseCount
        XCTAssertGreaterThanOrEqual(releases, 2)
        let events = await audio.events
        XCTAssertEqual(
            Array(events.prefix(5)),
            ["release:1:began", "release:1:finished", "release:2:began", "release:2:finished", "request:1"]
        )
        withExtendedLifetime(observer) {}
        synth.onSpeak = nil
    }

    func testQueuedInstructionsRetainTriggerOrder() async {
        let requested = expectation(description: "first instruction is waiting for focus")
        let spoken = expectation(description: "both instructions spoke")
        spoken.expectedFulfillmentCount = 2
        let audio = SuspendedAudioSession(holdRequests: true, onRequest: { count in
            if count == 1 {
                requested.fulfill()
            }
        })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { _ in spoken.fulfill() }
        let observer = makeObserver(synth: synth, audio: audio)
        observer.spokenInstructionTriggered(instruction("First"))
        await fulfillment(of: [requested], timeout: 3)
        observer.spokenInstructionTriggered(instruction("Second"))
        await audio.allowRequests()
        await fulfillment(of: [spoken], timeout: 3)
        XCTAssertEqual(synth.spoken, ["First", "Second"])
        observer.stopAndClearQueue()
    }

    func testReleasingObserverCancelsPendingSpeech() async {
        let requested = expectation(description: "instruction requested focus")
        let returned = expectation(description: "cancelled focus request returned")
        let unexpectedSpeech = expectation(description: "released observer spoke")
        unexpectedSpeech.isInverted = true
        let audio = SuspendedAudioSession(holdRequests: true,
                                          onRequest: { _ in requested.fulfill() },
                                          onRequestReturned: { _ in returned.fulfill() })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { _ in unexpectedSpeech.fulfill() }
        var observer: SpokenInstructionObserver? = makeObserver(synth: synth, audio: audio)
        weak var released = observer
        observer?.spokenInstructionTriggered(instruction("Old"))
        await fulfillment(of: [requested], timeout: 3)
        observer = nil
        XCTAssertNil(released)
        await audio.allowRequests()
        await fulfillment(of: [returned], timeout: 3)
        await fulfillment(of: [unexpectedSpeech], timeout: 0.1)
        XCTAssertEqual(synth.spoken, [])
    }

    func testReleasingObserverAlsoReleasesItsSpeakingPoller() async {
        let spoken = expectation(description: "custom synth started")
        let audio = SuspendedAudioSession()
        let synth = LifetimeSpeechSynthesizer()
        synth.isSpeaking = true
        synth.onSpeak = { _ in spoken.fulfill() }
        var observer: SpokenInstructionObserver? = makeObserver(synth: synth, audio: audio)
        weak var released = observer
        observer?.spokenInstructionTriggered(instruction("One"))
        await fulfillment(of: [spoken], timeout: 3)
        observer = nil
        // The speak callback can fulfill just before the synchronous helper
        // returns. Allow that helper to finish, without waiting for speech.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while released != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // The polling task must not keep the observer alive while speech lasts.
        XCTAssertNil(released)
        synth.onSpeak = nil
    }

    func testCustomSynthCanStopReentrantlyWithoutDeadlock() async {
        let spoken = expectation(description: "custom synth spoke and stopped")
        let audio = SuspendedAudioSession()
        let synth = LifetimeSpeechSynthesizer()
        let observer = makeObserver(synth: synth, audio: audio)
        synth.onSpeak = { [weak observer] _ in
            observer?.stopAndClearQueue()
            spoken.fulfill()
        }
        observer.spokenInstructionTriggered(instruction("One"))
        await fulfillment(of: [spoken], timeout: 3)
        await waitForStops(1, synth: synth)
        XCTAssertEqual(synth.stopCount, 1)
        XCTAssertEqual(synth.spoken, ["One"])
    }

    func testCustomSynthCanQueueNewSpeechDuringStop() async {
        let spoken = expectation(description: "reentrant new instruction spoke")
        let audio = SuspendedAudioSession()
        let synth = LifetimeSpeechSynthesizer()
        let observer = makeObserver(synth: synth, audio: audio)
        synth.onStop = { [weak observer] in
            observer?.spokenInstructionTriggered(self.instruction("New"))
        }
        synth.onSpeak = { _ in spoken.fulfill() }
        observer.stopAndClearQueue()
        await fulfillment(of: [spoken], timeout: 3)
        XCTAssertEqual(synth.spoken, ["New"])
        synth.onStop = nil
        synth.onSpeak = nil
    }

    func testStopInvalidatesAnUnmanagedQueueBeforeReturning() async {
        let completed = expectation(description: "replacement instruction completed")
        let audio = SuspendedAudioSession()
        let synth = LifetimeSpeechSynthesizer()
        let observer = makeObserver(synth: synth, audio: audio, managesAudio: false)
        for index in 0 ..< 50 {
            observer.spokenInstructionTriggered(instruction("Old \(index)"))
        }
        observer.stopAndClearQueue()
        let countAtStop = synth.spoken.count
        synth.onSpeak = { text in
            XCTAssertEqual(text, "New")
            completed.fulfill()
        }
        observer.spokenInstructionTriggered(instruction("New"))
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(synth.spoken.count, countAtStop + 1)
        XCTAssertEqual(synth.spoken.last, "New")
        observer.stopAndClearQueue()
    }

    func testDisabledAudioManagementAndInvalidSSMLKeepCustomSynthesis() async {
        let spoken = expectation(description: "plain-text fallback spoke")
        let audio = SuspendedAudioSession()
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { text in
            XCTAssertEqual(text, "Plain text")
            spoken.fulfill()
        }
        let observer = makeObserver(synth: synth, audio: audio, managesAudio: false)
        observer.spokenInstructionTriggered(instruction("Plain text", ssml: "invalid ssml"))
        await fulfillment(of: [spoken], timeout: 3)
        observer.toggleMute()
        await waitForStops(1, synth: synth)
        let requests = await audio.requestCount
        let releases = await audio.releaseCount
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(synth.stopCount, 1)
        XCTAssertTrue(observer.isMuted)
    }

    @MainActor
    func testRouteReplacementCancelsSpeechFromPreviousRoute() async throws {
        let oldRequested = expectation(description: "old route requested focus")
        let newRequested = expectation(description: "new route requested focus")
        let spoken = expectation(description: "new route spoke")
        let audio = SuspendedAudioSession(holdRequests: true, onRequest: { count in
            if count == 1 {
                oldRequested.fulfill()
            } else {
                newRequested.fulfill()
            }
        })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { text in
            XCTAssertEqual(text, "New route")
            spoken.fulfill()
        }
        let observer = makeObserver(synth: synth, audio: audio)
        let core = makeCore(observer: observer)
        try core.startNavigation(route: speakingRoute("Old route"))
        await fulfillment(of: [oldRequested], timeout: 3)
        try core.startNavigation(route: speakingRoute("New route"))
        await fulfillment(of: [newRequested], timeout: 3)
        await audio.allowRequests()
        await fulfillment(of: [spoken], timeout: 3)
        XCTAssertEqual(synth.spoken, ["New route"])
        core.stopNavigation()
    }

    @MainActor
    func testRejectedRouteReplacementRetainsCurrentSpeech() async throws {
        let requested = expectation(description: "current route requested focus")
        let spoken = expectation(description: "current route still spoke")
        let audio = SuspendedAudioSession(holdRequests: true, onRequest: { _ in requested.fulfill() })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { _ in spoken.fulfill() }
        let observer = makeObserver(synth: synth, audio: audio)
        let core = makeCore(observer: observer)
        try core.startNavigation(route: speakingRoute("Kept route"))
        await fulfillment(of: [requested], timeout: 3)
        let stops = synth.stopCount
        var invalid = mockRoute
        invalid.geometry = []
        XCTAssertThrowsError(try core.startNavigation(route: invalid))
        XCTAssertEqual(synth.stopCount, stops)
        await audio.allowRequests()
        await fulfillment(of: [spoken], timeout: 3)
        XCTAssertEqual(synth.spoken, ["Kept route"])
        core.stopNavigation()
    }

    @MainActor
    func testArrivalCancelsSpeechStillWaitingForFocus() async throws {
        let requested = expectation(description: "instruction requested focus")
        let arrived = expectation(description: "trip arrived")
        let unexpectedSpeech = expectation(description: "instruction spoke after arrival")
        unexpectedSpeech.isInverted = true
        let audio = SuspendedAudioSession(holdRequests: true, onRequest: { _ in requested.fulfill() })
        let synth = LifetimeSpeechSynthesizer()
        synth.onSpeak = { _ in unexpectedSpeech.fulfill() }
        let observer = makeObserver(synth: synth, audio: audio)
        let locations = SimulatedLocationProvider()
        let core = makeCore(observer: observer, locations: locations)
        try core.startNavigation(route: speakingRoute("Old"))
        await fulfillment(of: [requested], timeout: 3)
        let stops = synth.stopCount
        let subscription = core.$state.sink { state in
            if case .complete? = state?.tripState {
                arrived.fulfill()
            }
        }
        locations.lastLocation = try UserLocation(coordinates: XCTUnwrap(mockGeom.first), horizontalAccuracy: 5,
                                                  courseOverGround: nil, timestamp: Date(), speed: nil)
        core.advanceToNextStep()
        await fulfillment(of: [arrived], timeout: 3)
        await waitForStops(stops + 1, synth: synth)
        XCTAssertEqual(synth.stopCount, stops + 1)
        await audio.allowRequests()
        await fulfillment(of: [unexpectedSpeech], timeout: 0.1)
        XCTAssertEqual(synth.spoken, [])
        withExtendedLifetime(subscription) {}
        core.stopNavigation()
    }

    private func speakingRoute(_ text: String) -> Route {
        var route = mockRoute
        route.steps[0].spokenInstructions = [
            SpokenInstruction(text: text, ssml: nil, triggerDistanceBeforeManeuver: 1_000_000_000, utteranceId: UUID()),
        ]
        return route
    }

    @MainActor
    private func makeCore(observer: SpokenInstructionObserver,
                          locations: SimulatedLocationProvider? = nil) -> FerrostarCore
    {
        FerrostarCore(routeAdapter: mockGETRouteAdapter, locationProvider: locations ?? SimulatedLocationProvider(),
                      navigationControllerConfig: manualAdvanceConfig, networkSession: MockURLSession(),
                      spokenInstructionObserver: observer)
    }

    private func waitForStops(_ count: Int, synth: LifetimeSpeechSynthesizer) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while synth.stopCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(synth.stopCount, count)
    }

    private func instruction(_ text: String, ssml: String? = nil) -> SpokenInstruction {
        .init(text: text, ssml: ssml, triggerDistanceBeforeManeuver: 1, utteranceId: UUID())
    }

    private func makeObserver(synth: LifetimeSpeechSynthesizer, audio: SuspendedAudioSession,
                              managesAudio: Bool = true) -> SpokenInstructionObserver
    {
        SpokenInstructionObserver(synthesizer: synth, isMuted: false, managesAudioSession: managesAudio,
                                  audioManager: audio)
    }
}

private final class LifetimeSpeechSynthesizer: SpeechSynthesizer {
    private let lock = NSRecursiveLock()
    private var strings: [String] = []
    private var stops = 0
    private var speaking = false
    private var speakCallback: ((String) -> Void)?
    private var stopCallback: (() -> Void)?

    var onSpeak: ((String) -> Void)? {
        get { lock.withLock { speakCallback } }
        set { lock.withLock { speakCallback = newValue } }
    }

    var onStop: (() -> Void)? {
        get { lock.withLock { stopCallback } }
        set { lock.withLock { stopCallback = newValue } }
    }

    var spoken: [String] {
        lock.withLock { strings }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var isSpeaking: Bool {
        get { lock.withLock { speaking } }
        set { lock.withLock { speaking = newValue } }
    }

    func speak(_ utterance: AVSpeechUtterance) {
        XCTAssertTrue(Thread.isMainThread)
        let callback = lock.withLock {
            strings.append(utterance.speechString)
            return speakCallback
        }
        callback?(utterance.speechString)
    }

    func stopSpeaking(at _: AVSpeechBoundary) -> Bool {
        XCTAssertTrue(Thread.isMainThread)
        let callback = lock.withLock {
            stops += 1
            return stopCallback
        }
        callback?()
        return true
    }
}

/// Deterministic focus suspension. Like the production actor, cancellation is
/// checked immediately before changing focus, including after a test suspension.
private actor SuspendedAudioSession: AudioSessionManaging {
    private var holdRequests: Bool
    private var holdReleases: Bool
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private let onRequest: @Sendable (Int) -> Void
    private let onRelease: @Sendable (Int) -> Void
    private let onRequestReturned: @Sendable (Int) -> Void
    private(set) var requestCount = 0
    private(set) var releaseCount = 0
    private(set) var hasFocus = false
    private(set) var events: [String] = []

    init(holdRequests: Bool = false, holdReleases: Bool = false,
         onRequest: @escaping @Sendable (Int) -> Void = { _ in },
         onRelease: @escaping @Sendable (Int) -> Void = { _ in },
         onRequestReturned: @escaping @Sendable (Int) -> Void = { _ in })
    {
        self.holdRequests = holdRequests
        self.holdReleases = holdReleases
        self.onRequest = onRequest
        self.onRelease = onRelease
        self.onRequestReturned = onRequestReturned
    }

    func requestAudioFocus() async {
        requestCount += 1
        let count = requestCount
        events.append("request:\(count)")
        onRequest(count)
        if holdRequests {
            await withCheckedContinuation { requestWaiters.append($0) }
        }
        if !Task.isCancelled {
            hasFocus = true
        }
        onRequestReturned(count)
    }

    func releaseAudioFocus() async {
        releaseCount += 1
        let count = releaseCount
        events.append("release:\(count):began")
        onRelease(count)
        if holdReleases {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        if !Task.isCancelled {
            hasFocus = false
        }
        events.append("release:\(count):finished")
    }

    func allowRequests() {
        holdRequests = false
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func allowReleases() {
        holdReleases = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
