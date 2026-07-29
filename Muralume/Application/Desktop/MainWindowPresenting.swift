@MainActor
protocol MainWindowPresenting: AnyObject {
    func hide()
    func prepareForReturn()
    func show()
    func hideAfterFailedReturn()
    func toggleFullScreen()
}
