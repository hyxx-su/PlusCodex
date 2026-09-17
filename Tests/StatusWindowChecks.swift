import AppKit

@main struct StatusWindowChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusWindow()
        controller.update(quota: nil, fetching: true, failure: nil)
        precondition(controller.statusText.contains("조회 중"))
        controller.present()
        precondition(controller.window?.isVisible == true)
        controller.window?.performClose(nil)
        precondition(controller.window?.isVisible == false)
        controller.present()
        precondition(controller.window?.isVisible == true)
        controller.update(quota: nil, fetching: false, failure: "테스트 연결 오류")
        precondition(controller.statusText.contains("테스트 연결 오류"))
        let quota = Quota(primary: QuotaWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: nil), secondary: nil)
        controller.update(quota: quota, fetching: false, failure: nil)
        precondition(controller.statusText.contains("75% 남음"))
        controller.close()
        print("PASS: show, close, reopen, loading, error, success")
    }
}
