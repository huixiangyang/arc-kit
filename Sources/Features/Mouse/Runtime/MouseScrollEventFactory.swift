import ArcKitMouse
import ApplicationServices
import Foundation

/// 用系统像素事件构造器生成全部单位字段，禁止把像素同时写进行数。
enum MouseScrollEventFactory {
    static func make(vertical: Int32, horizontal: Int32, context: CGEvent) -> CGEvent? {
        guard vertical != 0 || horizontal != 0,
              let pixelEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: vertical, wheel2: horizontal, wheel3: 0),
              let event = context.copy() else { return nil }
        // 保留系统路由上下文，数值字段完全来自原生像素构造器。窗口字段对滚轮不可写，
        // 重新构造后手动写入这些字段会静默失败，不能据此声称保留了目标窗口。
        for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                                    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                                    .scrollWheelEventIsContinuous] {
            event.setIntegerValueField(field, value: pixelEvent.getIntegerValueField(field))
        }
        for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3] {
            event.setDoubleValueField(field, value: pixelEvent.getDoubleValueField(field))
        }
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: MouseScrollEventOrigin.syntheticMarker)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)

        return event
    }
}

/// 像素余数属于滚动目标会话。应用只消费整数像素，余数留给同一目标下一帧/下一脉冲。
struct MouseScrollPixelAccumulator {
    private var vertical = 0.0
    private var horizontal = 0.0

    mutating func take(vertical deltaY: Double, horizontal deltaX: Double) -> (vertical: Int32, horizontal: Int32) {
        (Self.take(deltaY, remainder: &vertical), Self.take(deltaX, remainder: &horizontal))
    }

    mutating func discardOpposite(to impulse: (vertical: Double, horizontal: Double)) {
        if impulse.vertical != 0, vertical.sign != impulse.vertical.sign { vertical = 0 }
        if impulse.horizontal != 0, horizontal.sign != impulse.horizontal.sign { horizontal = 0 }
    }

    private static func take(_ delta: Double, remainder: inout Double) -> Int32 {
        guard delta.isFinite else { return 0 }
        remainder += delta
        let integral = remainder.rounded(.towardZero)
        let bounded = max(Double(Int32.min), min(Double(Int32.max), integral))
        remainder -= bounded
        return Int32(bounded)
    }
}
