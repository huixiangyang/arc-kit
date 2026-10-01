import ApplicationServices
import Foundation

// 生命周期与回调结构参考 LinearMouse ef541a5 的 EventTap.swift（MIT），本地线程管理与状态上报已改写。
// 上游源文件声明：Copyright (c) 2021-2026 LinearMouse；许可见 Licenses/README.md。

public enum EventTapStateChange: Equatable, Sendable {
    case enabled, disabledByTimeoutRecovered, disabledByUserInput, invalidated, recovered
}

public protocol EventTapping: AnyObject {
    var onStateChange: ((EventTapStateChange) -> Void)? { get set }
    var isEnabled: Bool { get }
    @discardableResult func enable() -> Bool
    func invalidate()
}

/// 每个监听拥有专用 RunLoop。输入回调不会等待 MainActor；创建、恢复和回收在同一线程串行执行。
public final class EventTap: EventTapping, @unchecked Sendable {
    public typealias Handler = (_ proxy: CGEventTapProxy, _ event: CGEvent) -> CGEvent?
    public enum Failure: Error, LocalizedError {
        case failedToCreate
        public var errorDescription: String? { L10n.string(.Platform.monitorCreationFailed) }
    }
    private let loop = InputEventLoop()
    private let callbackLock = NSLock()
    private var stateHandler: ((EventTapStateChange) -> Void)?
    private var context: Context?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    public var onStateChange: ((EventTapStateChange) -> Void)? {
        get { callbackLock.withLock { stateHandler } }
        set { callbackLock.withLock { stateHandler = newValue } }
    }

    private final class Context {
        let handler: Handler
        var tap: CFMachPort?
        var report: ((EventTapStateChange) -> Void)?
        init(handler: @escaping Handler) { self.handler = handler }
    }

    public init(events: [CGEventType], tapLocation: CGEventTapLocation,
                placement: CGEventTapPlacement = .headInsertEventTap,
                options: CGEventTapOptions = .defaultTap, handler: @escaping Handler) throws {
        let context = Context(handler: handler)
        let created = loop.sync { [self] () -> Bool in
            let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            guard let tap = CGEvent.tapCreate(tap: tapLocation, place: placement, options: options,
                                             eventsOfInterest: mask, callback: Self.callback,
                                             userInfo: Unmanaged.passUnretained(context).toOpaque()) else { return false }
            context.tap = tap
            context.report = { [weak self] state in self?.onStateChange?(state) }
            self.context = context
            self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), self.source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.recoverIfNeeded() }
            self.timer = timer
            RunLoop.current.add(timer, forMode: .common)
            return true
        }
        guard created else { throw Failure.failedToCreate }
    }

    deinit { invalidate() }

    public var isEnabled: Bool {
        loop.sync { [self] in context?.tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false }
    }

    @discardableResult public func enable() -> Bool {
        loop.sync { [self] in
            guard let tap = context?.tap, CFMachPortIsValid(tap) else { return false }
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
    }

    public func invalidate() {
        // 同线程撤销 source 后才释放 callback context，防止其他线程回收仍在使用的裸指针。
        loop.sync { [self] in
            guard let context else { return }
            timer?.invalidate(); timer = nil
            if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
            if let tap = context.tap { CFMachPortInvalidate(tap) }
            self.source = nil
            self.context = nil
            onStateChange?(.invalidated)
        }
    }

    private func recoverIfNeeded() {
        guard let tap = context?.tap else { return }
        guard CFMachPortIsValid(tap) else { invalidate(); return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            onStateChange?(enable() ? .recovered : .invalidated)
        }
    }

    private static let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout:
            if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            context.report?(.disabledByTimeoutRecovered)
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            context.report?(.disabledByUserInput)
            return Unmanaged.passUnretained(event)
        default:
            guard let output = context.handler(proxy, event) else { return nil }
            return output === event ? Unmanaged.passUnretained(event) : Unmanaged.passRetained(output)
        }
    }
}

/// 控制操作可同步投递到输入线程，但输入线程绝不反向同步调用主线程。
final class InputEventLoop: @unchecked Sendable {
    private final class State: @unchecked Sendable { var runLoop: CFRunLoop? }
    private final class Invocation<Result> {
        private var body: (() -> Result)?
        var result: Result?
        init(_ body: @escaping () -> Result) { self.body = body }
        func execute() {
            result = body!()
            // 先释放业务闭包，再通知调用方；deinit 中的 invalidate 不能被 RunLoop block 继续持有。
            body = nil
        }
    }
    private let state = State()
    private let thread: Thread

    init() {
        let state = state
        let ready = DispatchSemaphore(value: 0)
        thread = Thread {
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            state.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
            port.invalidate()
        }
        thread.name = "Arc Kit Input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    deinit { if let loop = state.runLoop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) } }

    func sync<T>(_ body: @escaping () -> T) -> T {
        if Thread.current === thread { return body() }
        let done = DispatchSemaphore(value: 0)
        let invocation = Invocation(body)
        // signal 只保证结果已写入，不保证 RunLoop 已释放 block。
        // 闭包必须允许逃逸，否则调用线程抢先返回时会触发 Swift 运行时崩溃。
        CFRunLoopPerformBlock(state.runLoop, CFRunLoopMode.commonModes.rawValue) {
            invocation.execute()
            done.signal()
        }
        CFRunLoopWakeUp(state.runLoop)
        done.wait()
        return invocation.result!
    }
}
