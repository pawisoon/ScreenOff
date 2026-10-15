import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over the Apple Silicon display pipeline (IOAVService, private IOKit API).
/// Used for monitor speaker volume, which macOS can't control for HDMI/DisplayPort audio.
public final class DDC: @unchecked Sendable {
    public static let shared = DDC()

    public struct Volume: Sendable, Equatable {
        public let current: Int
        public let max: Int

        public init(current: Int, max: Int) {
            self.current = current
            self.max = max
        }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct API {
        let create: CreateFn
        let read: I2CFn
        let write: I2CFn
    }

    private static let api: API? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(h, "IOAVServiceCreateWithService"),
              let r = dlsym(h, "IOAVServiceReadI2C"),
              let w = dlsym(h, "IOAVServiceWriteI2C") else { return nil }
        return API(create: unsafeBitCast(c, to: CreateFn.self),
                   read: unsafeBitCast(r, to: I2CFn.self),
                   write: unsafeBitCast(w, to: I2CFn.self))
    }()

    private static let vcpVolume: UInt8 = 0x62
    private static let ddcAddress: UInt32 = 0x37
    private static let ddcSubaddress: UInt32 = 0x51
    private static let edidAddress: UInt32 = 0x50

    /// All DDC traffic is serialized here; monitors misbehave on concurrent or rapid-fire requests.
    private let queue = DispatchQueue(label: "ScreenOff.DDC")
    // Queue-confined.
    private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    private var lastWritten: [CGDirectDisplayID: Int] = [:]
    // Written from the caller, read on the queue.
    private let lock = NSLock()
    private var requested: [CGDirectDisplayID: Int] = [:]

    // MARK: Public API

    /// Current speaker volume, or nil if the display doesn't answer DDC volume queries.
    public func volume(for display: CGDirectDisplayID) async -> Volume? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.readVolume(display)) }
        }
    }

    /// Synchronous variant for the CLI.
    public func volumeAndWait(for display: CGDirectDisplayID) -> Volume? {
        queue.sync { readVolume(display) }
    }

    /// Fire-and-forget; rapid calls (slider drags) collapse to the latest value.
    public func setVolume(_ value: Int, for display: CGDirectDisplayID) {
        lock.withLock { requested[display] = value }
        queue.async {
            guard let target = self.lock.withLock({ self.requested[display] }),
                  target != self.lastWritten[display],
                  let svc = self.service(for: display) else { return }
            if Self.write(svc, vcp: Self.vcpVolume, value: UInt16(clamping: target)) {
                self.lastWritten[display] = target
            }
        }
    }

    /// Synchronous variant for the CLI.
    public func setVolumeAndWait(_ value: Int, for display: CGDirectDisplayID) -> Bool {
        queue.sync {
            guard let svc = service(for: display) else { return false }
            let ok = Self.write(svc, vcp: Self.vcpVolume, value: UInt16(clamping: value))
            if ok { lastWritten[display] = value }
            return ok
        }
    }

    /// Forget cached services; call when displays are plugged, unplugged, or toggled.
    public func invalidate() {
        queue.async {
            self.services.removeAll()
            self.lastWritten.removeAll()
        }
    }

    // MARK: On queue

    private func readVolume(_ display: CGDirectDisplayID) -> Volume? {
        guard let svc = service(for: display),
              let (cur, max) = Self.read(svc, vcp: Self.vcpVolume), max > 0 else { return nil }
        lastWritten[display] = Int(cur)
        return Volume(current: Int(cur), max: Int(max))
    }


    private func service(for display: CGDirectDisplayID) -> CFTypeRef? {
        if let svc = services[display] { return svc }
        guard let api = Self.api else { return nil }

        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let svc = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue(),
                  let edid = Self.readEDIDHeader(svc) else { continue }
            // Match the monitor on this port to the CoreGraphics display by EDID identity.
            if edid.vendor == vendor, edid.model == model, serial == 0 || edid.serial == 0 || edid.serial == serial {
                services[display] = svc
                return svc
            }
        }
        return nil
    }

    private static func readEDIDHeader(_ svc: CFTypeRef) -> (vendor: UInt32, model: UInt32, serial: UInt32)? {
        guard let api else { return nil }
        var buf = [UInt8](repeating: 0, count: 32)
        usleep(10_000)
        guard api.read(svc, edidAddress, 0, &buf, 32) == kIOReturnSuccess,
              buf[0] == 0x00, buf[1] == 0xFF, buf[7] == 0x00 else { return nil }
        let vendor = UInt32(buf[8]) << 8 | UInt32(buf[9])
        let model = UInt32(buf[10]) | UInt32(buf[11]) << 8
        let serial = UInt32(buf[12]) | UInt32(buf[13]) << 8 | UInt32(buf[14]) << 16 | UInt32(buf[15]) << 24
        return (vendor, model, serial)
    }

    // MARK: DDC/CI (on queue)

    private static func write(_ svc: CFTypeRef, vcp: UInt8, value: UInt16) -> Bool {
        guard let api else { return false }
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ UInt8(ddcSubaddress), ^)
        var result = kIOReturnError
        // Sent twice: some monitors drop the first packet.
        for _ in 0..<2 {
            usleep(10_000)
            result = api.write(svc, ddcAddress, ddcSubaddress, &packet, UInt32(packet.count))
        }
        return result == kIOReturnSuccess
    }

    private static func read(_ svc: CFTypeRef, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let api else { return nil }
        var request: [UInt8] = [0x82, 0x01, vcp, 0]
        request[3] = request[0..<3].reduce(0x6E ^ UInt8(ddcSubaddress), ^)
        for attempt in 0..<3 {
            var sent = kIOReturnError
            for _ in 0..<2 {
                usleep(10_000)
                sent = api.write(svc, ddcAddress, ddcSubaddress, &request, UInt32(request.count))
            }
            guard sent == kIOReturnSuccess else { continue }
            usleep(UInt32(40_000 + attempt * 30_000))
            var reply = [UInt8](repeating: 0, count: 12)
            guard api.read(svc, ddcAddress, ddcSubaddress, &reply, 12) == kIOReturnSuccess else { continue }
            // Payload only: some panels (LG) send a non-standard length byte and checksum.
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { continue }
            return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
        }
        return nil
    }
}
