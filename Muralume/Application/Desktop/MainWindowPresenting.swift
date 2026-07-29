@MainActor
protocol MainWindowPresenting: AnyObject {
    func hide()
    func prepareForReturn()
    func show()
    func hideAfterFailedReturn()
    func dismiss()
    func minimize()
    func toggleFullScreen()
}
