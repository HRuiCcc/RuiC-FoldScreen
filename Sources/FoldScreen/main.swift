import AppKit
import Foundation

// Entry point. The command line flags exist so every interesting part of the app
// can be exercised without a person watching: the fold maths, the shader, the
// sensor, and the live capture path each have a headless route.

let arguments = CommandLine.arguments

func flag(_ name: String) -> Bool { arguments.contains(name) }

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.count > index + 1 else { return nil }
    let candidate = arguments[index + 1]
    return candidate.hasPrefix("--") ? nil : candidate
}

if flag("--help") || flag("-h") {
    print(
        """
        RuiC-FoldScreen — 合盖弯屏

        用法:
          RuiC-FoldScreen                     以菜单栏程序启动
          RuiC-FoldScreen --selftest          跑无界面自检（数学、着色器、传感器、离屏渲染）
          RuiC-FoldScreen --sensor            读一次翻盖角度
          RuiC-FoldScreen --render-frames DIR 用真实渲染管线输出折角序列，供人工查看
              [--size 960x600] [--steps 7] [--preset 0|1|2] [--hold 0.8]
          RuiC-FoldScreen --scripted-lid       用脚本化的翻盖角度启动（无需真实盖子）
          RuiC-FoldScreen --smoke              启用效果并在 3 秒后写出自检报告到 /tmp

        自检退出码 0 表示通过。
        """)
    exit(0)
}

if flag("--selftest") {
    let failures = Harness.runSelfTest()
    print(failures == 0 ? "\n自检通过。" : "\n自检失败：\(failures) 项。")
    exit(failures == 0 ? 0 : 1)
}

if flag("--render-frames") {
    exit(Int32(Harness.renderFrames(arguments)))
}

if flag("--sensor") {
    let sensor = HIDLidAngleSource()
    if let angle = sensor.read() {
        print(String(format: "翻盖角度：%.0f°", angle))
    } else {
        print("这台机器没有读到翻盖角度传感器。")
        exit(2)
    }
    exit(0)
}

// AppKit must be driven from the main actor. Top level code is nonisolated, so
// the entry into the run loop is spelled out here rather than assumed.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
