import Foundation
import CodeIslandCore

struct PermissionRequest {
    let sessionKey: String
    let event: HookEvent
    let continuation: CheckedContinuation<Data, Never>
}

struct QuestionRequest {
    let sessionKey: String
    let event: HookEvent
    let question: QuestionPayload
    let continuation: CheckedContinuation<Data, Never>
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool

    init(sessionKey: String, event: HookEvent, question: QuestionPayload, continuation: CheckedContinuation<Data, Never>, isFromPermission: Bool = false) {
        self.sessionKey = sessionKey
        self.event = event
        self.question = question
        self.continuation = continuation
        self.isFromPermission = isFromPermission
    }
}
