import QuartzCore

extension CALayer {
    @MainActor
    func animateDesktopEffect(
        _ keyPath: String, to value: NSObject, duration: CFTimeInterval, timing: CAMediaTimingFunction
    ) {
        guard let previous = self.value(forKeyPath: keyPath) as? NSObject,
              !previous.isEqual(value) else { return }

        let animation = CABasicAnimation(keyPath: keyPath)
        // Several pointer events can arrive before the first frame is presented.
        animation.fromValue = presentation()?.value(forKeyPath: keyPath)
            ?? (self.animation(forKey: keyPath) as? CABasicAnimation)?.fromValue ?? previous
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        setValue(value, forKeyPath: keyPath)
        add(animation, forKey: keyPath)
    }
}
