import Testing
@testable import AutoBrightnessCore

// Recorded on the development machine (M2, P24h-30).
private let realLocation =
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dispext0@70000000/AppleCLCD2"
private let realServicePath =
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/AppleASCWrapV4/iop-dcpext-nub/RTBuddy(DCPEXT)/DCPEXTEndpoint9/AFKDCPEXTEndpoint9/AFKEPInterfaceServiceKextV2/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"

private func servicePath(node: String) -> String {
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/AFKEPInterfaceServiceKextV2/\(node):dcpav-service-epic:0/DCPAVServiceProxy"
}

private func location(node: String) -> String {
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/\(node)@70000000/AppleCLCD2"
}

@Test("The framebuffer node comes from the component before the last")
func nodeFromLocation() {
    #expect(AVServiceMatcher.framebufferNode(displayLocation: realLocation) == "dispext0")
    #expect(AVServiceMatcher.framebufferNode(displayLocation: "") == nil)
    #expect(AVServiceMatcher.framebufferNode(displayLocation: "IOService:/@1/AppleCLCD2") == nil)
}

@Test("Service paths yield the nodes of their dcpav-service components")
func nodesFromServicePath() {
    #expect(AVServiceMatcher.framebufferNodes(servicePath: realServicePath) == ["dispext0"])
    #expect(AVServiceMatcher.framebufferNodes(servicePath: "IOService:/dcpext@71C00000/Foo").isEmpty)
}

@Test("The real display matches the real service")
func realPathsMatch() {
    let result = AVServiceMatcher.match(displayLocations: [2: realLocation], servicePaths: [realServicePath])
    #expect(result == [2: .matched(serviceIndex: 0)])
}

@Test("Two identical monitors each match their own service by node")
func twoMonitorsMatchByNode() {
    let result = AVServiceMatcher.match(
        displayLocations: [5: location(node: "dispext0"), 6: location(node: "dispext1")],
        servicePaths: [servicePath(node: "dispext1"), servicePath(node: "dispext0")]
    )
    #expect(result == [5: .matched(serviceIndex: 1), 6: .matched(serviceIndex: 0)])
}

@Test("A display with no service carrying its node has no DDC connection")
func noServiceForNode() {
    let result = AVServiceMatcher.match(
        displayLocations: [7: location(node: "dispext2")],
        servicePaths: [servicePath(node: "dispext0")]
    )
    #expect(result == [7: .noService])
}

@Test("Two services claiming one node make that display ambiguous")
func duplicateServicesAreAmbiguous() {
    let result = AVServiceMatcher.match(
        displayLocations: [8: location(node: "dispext0")],
        servicePaths: [servicePath(node: "dispext0"), servicePath(node: "dispext0")]
    )
    #expect(result == [8: .ambiguous])
}

@Test("Two displays claiming one node are both ambiguous")
func crossClaimedNodeIsAmbiguous() {
    let result = AVServiceMatcher.match(
        displayLocations: [9: location(node: "dispext0"), 10: location(node: "dispext0")],
        servicePaths: [servicePath(node: "dispext0")]
    )
    #expect(result == [9: .ambiguous, 10: .ambiguous])
}

@Test("An unparseable location has no DDC connection")
func garbageLocation() {
    let result = AVServiceMatcher.match(displayLocations: [11: ""], servicePaths: [realServicePath])
    #expect(result == [11: .noService])
}
