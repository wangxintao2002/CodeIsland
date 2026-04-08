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

    func testCodexSessionStartKeepsSparseRemoteSessionActive() throws {
        let json: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "rollout-123",
            "_source": "codex",
            "_remote_profile": "devbox",
            "_origin_id": "remote:devbox",
            "cwd": "/srv/app",
        ]

        let event = try XCTUnwrap(HookEvent(json: json))
        var sessions: [String: SessionSnapshot] = [:]

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        let snapshot = try XCTUnwrap(sessions["remote:devbox::rollout-123"])
        XCTAssertEqual(snapshot.source, "codex")
        XCTAssertEqual(snapshot.status, .processing)
    }

    func testStopFallsBackToPromptFieldWhenCodexDidNotEmitPromptEvent() throws {
        let startJSON: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "rollout-456",
            "_source": "codex",
            "_remote_profile": "devbox",
            "_origin_id": "remote:devbox",
        ]
        let stopJSON: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "rollout-456",
            "_source": "codex",
            "_remote_profile": "devbox",
            "_origin_id": "remote:devbox",
            "prompt": "Summarize the failing deployment",
            "last_assistant_message": "The deployment failed because the DB migration timed out.",
        ]

        let startEvent = try XCTUnwrap(HookEvent(json: startJSON))
        let stopEvent = try XCTUnwrap(HookEvent(json: stopJSON))
        var sessions: [String: SessionSnapshot] = [:]

        _ = reduceEvent(sessions: &sessions, event: startEvent, maxHistory: 10)
        _ = reduceEvent(sessions: &sessions, event: stopEvent, maxHistory: 10)

        let snapshot = try XCTUnwrap(sessions["remote:devbox::rollout-456"])
        XCTAssertEqual(snapshot.lastUserPrompt, "Summarize the failing deployment")
        XCTAssertEqual(snapshot.lastAssistantMessage, "The deployment failed because the DB migration timed out.")
        XCTAssertEqual(snapshot.recentMessages.map(\.text), [
            "Summarize the failing deployment",
            "The deployment failed because the DB migration timed out.",
        ])
    }

    func testCamelCaseCodexPayloadStillRoutesAndParsesToolInfo() throws {
        let json: [String: Any] = [
            "hookEventName": "preToolUse",
            "sessionId": "rollout-789",
            "toolName": "bash",
            "toolArgs": "{\"command\":\"npm test\"}",
            "_source": "codex",
            "_remote_profile": "devbox",
            "_origin_id": "remote:devbox",
        ]

        let event = try XCTUnwrap(HookEvent(json: json))

        XCTAssertEqual(event.eventName, "preToolUse")
        XCTAssertEqual(event.sessionId, "rollout-789")
        XCTAssertEqual(event.toolName, "bash")
        XCTAssertEqual(event.toolInput?["command"] as? String, "npm test")
        XCTAssertEqual(event.routingSessionId, "remote:devbox::rollout-789")
        XCTAssertEqual(event.toolDescription, "npm test")
    }
}
