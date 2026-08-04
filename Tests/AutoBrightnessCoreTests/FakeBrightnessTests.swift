import Testing
@testable import AutoBrightnessCore

@Test("The fake records writes and reads them back")
func fakeRoundTrips() {
    let fake = FakeBrightness(value: 0.5)
    #expect(fake.read() == 0.5)
    fake.write(0.7)
    #expect(fake.read() == 0.7)
    #expect(fake.writes == [0.7])
}

@Test("The fake clamps writes to the valid range")
func fakeClamps() {
    let fake = FakeBrightness(value: 0.5)
    fake.write(1.5)
    #expect(fake.read() == 1.0)
    fake.write(-0.5)
    #expect(fake.read() == 0.0)
}

@Test("An uncontrollable fake reports so and ignores writes")
func fakeCanBeUnavailable() {
    let fake = FakeBrightness(value: 0.5, canControl: false)
    #expect(fake.canControl == false)
    fake.write(0.9)
    #expect(fake.read() == 0.5)
    #expect(fake.writes.isEmpty)
}
