/// 只允许较新的 Agent 请求结果推进主进程状态，阻断迟到失败覆盖已恢复状态。
struct RuntimeReplySequence {
    private var nextSequence: UInt64 = 0
    private var latestAppliedSequence: UInt64 = 0

    mutating func beginRequest() -> UInt64 {
        nextSequence &+= 1
        return nextSequence
    }

    mutating func acceptReply(sequence: UInt64) -> Bool {
        guard sequence > latestAppliedSequence else { return false }
        latestAppliedSequence = sequence
        return true
    }

    mutating func invalidatePendingReplies() {
        nextSequence &+= 1
        latestAppliedSequence = nextSequence
    }
}
