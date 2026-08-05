/// Pure math for gliding between two brightness levels.
public enum BrightnessRamp {
    /// Below this distance a direct write is already imperceptible, so no
    /// ramp is worth its writes.
    public static let minimumRampDistance = 0.01

    /// `count` eased values from `start` to `target`: the start itself is
    /// excluded, the last value is `target` bit-exactly. Smoothstep easing,
    /// so the glide begins and ends gently rather than at constant velocity.
    public static func steps(from start: Double, to target: Double, count: Int) -> [Double] {
        guard count > 1 else { return [target] }
        return (1...count).map { i in
            guard i < count else { return target }
            let t = Double(i) / Double(count)
            let eased = t * t * (3 - 2 * t)
            return start + (target - start) * eased
        }
    }
}
