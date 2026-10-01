import ArcKitMouse
import ApplicationServices
import AppKit

/// 字段封装的历史参考为 LinearMouse ef541a5 的同名文件（MIT，Copyright (c) 2021-2026 LinearMouse）。
/// 当前只读解析已改写，来源边界见 Licenses/README.md；PointDelta 是整数像素，FixedPtDelta 是定点行数。
struct ScrollWheelEventView {
    let event: CGEvent

    var isSyntheticFromArcKit: Bool {
        event.getIntegerValueField(.eventSourceUserData) == MouseScrollEventOrigin.syntheticMarker
    }

    var inputKind: MouseScrollInputKind {
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return .nativeGesture }
        // 这是事件语义分类，不冒充 USB/蓝牙设备识别。带原生 phase 的输入始终交给系统。
        return event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? .highResolutionWheel : .discreteWheel
    }

    var target: MouseScrollTarget {
        let pid = event.getIntegerValueField(.eventTargetUnixProcessID)
        return MouseScrollTarget(
            processIdentifier: pid > 0 && pid <= Int64(pid_t.max) ? pid_t(pid) : 0,
            windowNumber: NSEvent(cgEvent: event)?.windowNumber ?? 0,
            location: event.location
        )
    }

    var modifierState: MouseScrollModifierState {
        var state: MouseScrollModifierState = []
        if event.flags.contains(.maskShift) { state.insert(.shift) }
        if event.flags.contains(.maskAlternate) { state.insert(.option) }
        if event.flags.contains(.maskControl) { state.insert(.control) }
        if event.flags.contains(.maskCommand) { state.insert(.command) }
        return state
    }

    var input: MouseScrollInput {
        MouseScrollInput(
            verticalDelta: pixels(point: .scrollWheelEventPointDeltaAxis1, fixed: .scrollWheelEventFixedPtDeltaAxis1, line: .scrollWheelEventDeltaAxis1),
            horizontalDelta: pixels(point: .scrollWheelEventPointDeltaAxis2, fixed: .scrollWheelEventFixedPtDeltaAxis2, line: .scrollWheelEventDeltaAxis2),
            kind: inputKind, modifiers: modifierState
        )
    }

    private func pixels(point: CGEventField, fixed: CGEventField, line: CGEventField) -> Double {
        let pixels = Double(event.getIntegerValueField(point))
        // 连续事件的 0 像素是有效值，不能从 line 字段凭空补出移动。
        if inputKind != .discreteWheel || pixels != 0 { return pixels }
        let sourceScale = CGEventSource(event: event)?.pixelsPerLine ?? 10
        let scale = sourceScale.isFinite && sourceScale > 0 ? sourceScale : 10
        let lines = event.getDoubleValueField(fixed)
        return (lines.isFinite && lines != 0 ? lines : Double(event.getIntegerValueField(line))) * scale
    }
}

struct MouseScrollTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    // 滚轮的 mouseEventWindow 字段不可写。通过 AppKit 读取系统标注，不能用 PID 代替窗口。
    let windowNumber: Int
    let location: CGPoint

    var canReceivePostedScroll: Bool { processIdentifier > 0 && windowNumber > 0 }
}
