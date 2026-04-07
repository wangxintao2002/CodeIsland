import XCTest
@testable import CodeIslandCore

final class RemoteSessionKeyTests: XCTestCase {
    func testRemoteHookEventBuildsDistinctRoutingSessionId() throws {
        let json: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "abc-123",
            "_source": "claude",
            "_remote_profile": "prod-box",
            "_origin_id": "remote:prod-box",
        ]

        let event = try XCTUnwrap(HookEvent(json: json))

        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.originId, "remote:prod-box")
        XCTAssertEqual(event.routingSessionId, "remote:prod-box::abc-123")
    }

    func testPlainSessionIdDefaultsToLocalOrigin() {
        let key = SessionKey(rawValue: "local-session")

        XCTAssertEqual(key.originId, SessionKey.localOriginId)
        XCTAssertEqual(key.sessionId, "local-session")
        XCTAssertEqual(key.rawValue, "local-session")
    }
}
