import AppKit
import BackglowCore
import CoreGraphics

/// Reads the connected displays through Core Graphics. Unlike ScreenCaptureKit this needs no
/// Screen Recording permission, so it can watch for a remembered monitor at any time.
enum DisplayDiscovery {
    static func active() -> [DisplayIdentity] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(identity)
    }

    static func identity(_ id: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                        serial: CGDisplaySerialNumber(id), displayID: id)
    }

    /// The monitor's name as System Settings shows it, such as "DELL U2720Q".
    @MainActor
    static func name(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }
}
