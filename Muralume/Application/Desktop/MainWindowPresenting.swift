@MainActor
protocol MainWindowPresenting: AnyObject {
    func hide()
    func prepareForReturn()
    func show()
    func hideAfterFailedReturn()
    func close()
    func minimize()
    func toggleFullScreen()
}
