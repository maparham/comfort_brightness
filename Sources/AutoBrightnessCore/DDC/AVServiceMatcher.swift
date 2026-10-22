/// The outcome of looking for a display's DDC connection.
public enum AVServiceMatch: Equatable, Sendable {
    case matched(serviceIndex: Int)
    case noService
    /// More than one candidate, either way round. Driving a guess could take
    /// the content of one monitor and set the brightness of another.
    case ambiguous
}

/// Pairs displays with their `DCPAVServiceProxy` by framebuffer node name.
///
/// The display's `IODisplayLocation` ends `…/dispext0@70000000/AppleCLCD2`,
/// and its DDC service lives under a component `dispext0:dcpav-service-…`.
/// The node name is what links them. EDID serials cannot do it: the monitor
/// this was designed on reports serial 0, as do many others, so two identical
/// monitors would be indistinguishable.
///
/// Pure string work, with no regular expressions, so it can be tested on
/// recorded paths without the hardware.
public enum AVServiceMatcher {
    /// `…/dispext0@70000000/AppleCLCD2` → `dispext0`. The last component is
    /// not inspected; `AppleCLCD2` is what one machine shows, not a promise.
    public static func framebufferNode(displayLocation: String) -> String? {
        let components = displayLocation.split(separator: "/")
        guard components.count >= 2 else { return nil }
        let parent = components[components.count - 2]
        let node = parent.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return node.isEmpty ? nil : String(node)
    }

    /// The node names of every `<node>:…dcpav-service…` component in a
    /// service-plane path.
    public static func framebufferNodes(servicePath: String) -> Set<String> {
        Set(servicePath.split(separator: "/").compactMap { component -> String? in
            guard component.contains("dcpav-service") else { return nil }
            let parts = component.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && !parts[0].isEmpty ? String(parts[0]) : nil
        })
    }

    /// A result for every display in `displayLocations`.
    public static func match(
        displayLocations: [UInt32: String],
        servicePaths: [String]
    ) -> [UInt32: AVServiceMatch] {
        let serviceNodes = servicePaths.map { framebufferNodes(servicePath: $0) }
        let displayNodes = displayLocations.mapValues { framebufferNode(displayLocation: $0) }
        var result: [UInt32: AVServiceMatch] = [:]
        for (display, node) in displayNodes {
            guard let node else {
                result[display] = .noService
                continue
            }
            let sharers = displayNodes.values.filter { $0 == node }.count
            let candidates = serviceNodes.indices.filter { serviceNodes[$0].contains(node) }
            switch (candidates.count, sharers) {
            case (0, _): result[display] = .noService
            case (1, 1): result[display] = .matched(serviceIndex: candidates[0])
            default: result[display] = .ambiguous
            }
        }
        return result
    }
}
