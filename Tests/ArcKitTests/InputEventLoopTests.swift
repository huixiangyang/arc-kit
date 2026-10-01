@testable import ArcKitPlatform
import Foundation
import Testing

struct InputEventLoopTests {
    private final class Owner {
        let loop: InputEventLoop
        private var stopped = false
        init(loop: InputEventLoop) { self.loop = loop }
        deinit { loop.sync { [self] in stopped = true } }
    }

    @Test("输入线程同步调用允许 RunLoop 在返回后释放闭包")
    func repeatedSynchronousCalls() {
        let loop = InputEventLoop()
        // 使用真实专用 RunLoop，不创建 EventTap、不请求权限或发送输入。
        // 旧实现的 withoutActuallyEscaping 会在 signal 与 block 释放之间触发运行时陷阱。
        for index in 0..<2_000 {
            let value = loop.sync {
                loop.sync { (index, Thread.current.name) }
            }
            #expect(value.0 == index)
            #expect(value.1 == "Arc Kit Input")
            // 模拟 EventTap 析构时同步撤销资源，返回后不得留下对析构对象的引用。
            var owner: Owner? = Owner(loop: loop)
            weak let released = owner
            owner = nil
            #expect(released == nil)
        }
    }
}
