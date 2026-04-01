import CoreGraphics
import Foundation
import CPrivateAPI

struct DisplayTarget {
    let displayID: CGDirectDisplayID
    let width: UInt32
    let height: UInt32
    let vendorID: UInt32
    let productID: UInt32
    let refreshRate: Double
}

// SkyLight function pointers resolved at runtime via dlopen
private let skylight: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

private func slFunc<T>(_ name: String) -> T? {
    guard let sl = skylight, let sym = dlsym(sl, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

private let slBitsPerSample: (@convention(c) (CGDirectDisplayID) -> UInt32)? =
    slFunc("SLDisplayBitsPerSample")
private let slBitsPerPixel: (@convention(c) (CGDirectDisplayID) -> UInt32)? =
    slFunc("SLDisplayBitsPerPixel")
private let slIsHDR: (@convention(c) (CGDirectDisplayID) -> Bool)? =
    slFunc("SLSDisplayIsHDRModeEnabled")
private let slSupportsHDR: (@convention(c) (CGDirectDisplayID) -> Bool)? =
    slFunc("SLSDisplaySupportsHDRMode")
private let slSetDisplayColorSpace: (@convention(c) (CGDirectDisplayID, CGColorSpace) -> CGError)? =
    slFunc("SLSSetDisplayColorSpace")

/// Whether stdout is a terminal (controls verbose diagnostic output)
private let isTTY = isatty(STDOUT_FILENO) != 0

class DisplayManager {
    private var virtualDisplay: CGVirtualDisplay?
    private(set) var targetDisplay: DisplayTarget?
    private(set) var lastError: String?

    /// Activate HiDPI. Creates virtual display immediately, then calls completion
    /// on the main queue after mirror setup (non-blocking).
    func activate(hdrMode: Bool, scaleFactor: Double = 2.0, completion: @escaping (Bool) -> Void) {
        lastError = nil

        guard let target = findTarget() else {
            lastError = "No 4K external display found"
            log("error: \(lastError!)")
            completion(false)
            return
        }
        targetDisplay = target
        log("Target: 0x\(String(target.displayID, radix: 16)) " +
            "(0x\(String(target.vendorID, radix: 16)):0x\(String(target.productID, radix: 16))) " +
            "\(target.width)x\(target.height) @ \(Int(target.refreshRate))Hz")

        guard let vd = createVirtualDisplay(target: target, hdrMode: hdrMode, scaleFactor: scaleFactor) else {
            lastError = "Virtual display creation failed"
            completion(false)
            return
        }
        virtualDisplay = vd

        let vdID = CGDirectDisplayID(vd.displayID)
        log("Virtual display 0x\(String(vdID, radix: 16)) -> mirror of 0x\(String(target.displayID, radix: 16))")

        // Wait briefly for the virtual display to register, then configure mirror
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { completion(false); return }
            guard configureMirror(source: vdID, target: target.displayID) else {
                lastError = "Mirror configuration failed"
                log("error: \(lastError!)")
                deactivate()
                completion(false)
                return
            }

            if hdrMode {
                log("  HDR mode: 16-bit compositing with PQ gamma correction")
                applyPQGammaCorrection(displayID: vdID)
            }

            matchColourProfile(physicalID: target.displayID, virtualID: vdID)

            if isTTY {
                printQualityInfo(label: "Virtual", displayID: vdID)
                printQualityInfo(label: "Physical", displayID: target.displayID)
                printColourDiagnostics(virtualID: vdID, physicalID: target.displayID)
            }

            log("force-hidpi: active (\(target.width)x\(target.height) HiDPI\(hdrMode ? " 16-bit" : ""))")
            completion(true)
        }
    }

    func rematchColourProfile() {
        guard let target = targetDisplay, let vd = virtualDisplay else { return }
        matchColourProfile(physicalID: target.displayID, virtualID: CGDirectDisplayID(vd.displayID))
    }

    func deactivate() {
        if let target = targetDisplay {
            unconfigureMirror(target: target.displayID)
        }
        targetDisplay = nil
        lastError = nil
        // Release the virtual display last so the mirror config transaction
        // commits before the backing display object is deallocated.
        virtualDisplay = nil
    }

    // MARK: - Display enumeration

    func findTarget() -> DisplayTarget? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }

        for i in 0..<Int(count) {
            let did = ids[i]
            guard CGDisplayIsBuiltin(did) == 0 else { continue }

            let w = UInt32(CGDisplayPixelsWide(did))
            let h = UInt32(CGDisplayPixelsHigh(did))
            guard w >= 3840 else { continue }

            let hz = CGDisplayCopyDisplayMode(did).map { $0.refreshRate } ?? 60.0

            return DisplayTarget(
                displayID: did, width: w, height: h,
                vendorID: CGDisplayVendorNumber(did),
                productID: CGDisplayModelNumber(did),
                refreshRate: hz
            )
        }
        return nil
    }

    // MARK: - Virtual display

    private func createVirtualDisplay(target: DisplayTarget, hdrMode: Bool, scaleFactor: Double = 2.0) -> CGVirtualDisplay? {
        // Mode dimensions determine the virtual display's pixel resolution.
        // With hiDPI=1 the compositor offers a 2x mode (half the mode pixels
        // as logical points). For super-sampling (scaleFactor > 2) we increase
        // the mode so the compositor renders at a higher resolution than the
        // physical display, and the mirror hardware-downscales to native.
        //
        //   scaleFactor 2.0:  mode 3840x2160 -> 1920x1080@2x -> 1:1 to physical
        //   scaleFactor 2.5:  mode 4800x2700 -> 2400x1350@2x -> 1.25:1 downscale
        //   scaleFactor 4.0:  mode 7680x4320 -> 3840x2160@2x -> 2:1 downscale
        let modeW = UInt32((Double(target.width) * scaleFactor / 2.0).rounded())
        let modeH = UInt32((Double(target.height) * scaleFactor / 2.0).rounded())
        let maxPxW = modeW * 2  // 2x backing for HiDPI
        let maxPxH = modeH * 2
        let hz = target.refreshRate > 0 ? target.refreshRate : 60.0

        log("  Virtual display mode: \(modeW)x\(modeH) (maxPx \(maxPxW)x\(maxPxH), scale \(scaleFactor)x)")

        let mode: CGVirtualDisplayMode
        if hdrMode {
            mode = CGVirtualDisplayMode(width: modeW, height: modeH,
                                        refreshRate: hz, transferFunction: 1)
        } else {
            mode = CGVirtualDisplayMode(width: modeW, height: modeH, refreshRate: hz)
        }

        let desc = CGVirtualDisplayDescriptor()
        desc.vendorID = target.vendorID
        desc.productID = target.productID
        desc.serialNumber = 1
        desc.name = "force-hidpi"
        desc.sizeInMillimeters = CGSize(width: 698, height: 392)
        desc.maxPixelsWide = maxPxW
        desc.maxPixelsHigh = maxPxH
        desc.redPrimary = CGPoint(x: 0.64, y: 0.33)
        desc.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        desc.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        desc.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        desc.queue = DispatchQueue(label: "com.force-hidpi.vd")

        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode]
        settings.hiDPI = 1

        guard let vd = CGVirtualDisplay(descriptor: desc) else {
            log("error: CGVirtualDisplay creation failed")
            return nil
        }

        if !vd.apply(settings) {
            log("warning: applySettings failed, using defaults")
        }

        return vd
    }

    // MARK: - Mirror

    private func configureMirror(source: CGDirectDisplayID, target: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayMirrorOfDisplay(config, target, source)
        CGConfigureDisplayOrigin(config, source, 0, 0)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    private func unconfigureMirror(target: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, target, CGDirectDisplayID(0))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success {
            log("warning: unconfigureMirror failed (CGError \(result.rawValue))")
        }
    }

    // MARK: - Colour profile matching

    private func matchColourProfile(physicalID: CGDirectDisplayID, virtualID: CGDirectDisplayID) {
        let physCS = CGDisplayCopyColorSpace(physicalID)
        let vdCS = CGDisplayCopyColorSpace(virtualID)

        let physICC = physCS.copyICCData() as Data?
        let vdICC = vdCS.copyICCData() as Data?
        if let p = physICC, let v = vdICC, p == v {
            log("  Colour profiles already match")
            return
        }

        if let setCS = slSetDisplayColorSpace {
            let err = setCS(virtualID, physCS)
            if err == .success {
                log("  Matched colour profile via SLSSetDisplayColorSpace")
                return
            }
        }

        log("  warning: could not match colour profiles")
    }

    // MARK: - Diagnostics (TTY only)

    private func log(_ msg: String) {
        print(msg)
    }

    private func printQualityInfo(label: String, displayID: CGDirectDisplayID) {
        let bps = slBitsPerSample?(displayID) ?? 0
        let bpp = slBitsPerPixel?(displayID) ?? 0
        let hdr = slIsHDR?(displayID) ?? false
        let hdrCap = slSupportsHDR?(displayID) ?? false
        log("  \(label) (0x\(String(displayID, radix: 16))): " +
            "\(bps)-bit/sample, \(bpp)-bit/pixel, " +
            "HDR: \(hdr ? "on" : "off")\(hdrCap ? " (supported)" : "")")
    }

    private func printColourDiagnostics(virtualID: CGDirectDisplayID, physicalID: CGDirectDisplayID) {
        let vdCS = CGDisplayCopyColorSpace(virtualID)
        let physCS = CGDisplayCopyColorSpace(physicalID)

        let vdICC = vdCS.copyICCData() as Data?
        let physICC = physCS.copyICCData() as Data?
        let match = vdICC != nil && physICC != nil && vdICC == physICC
        log("  ICC profiles match: \(match ? "YES" : "NO")")

        let vdSize = CGDisplayScreenSize(virtualID)
        let physSize = CGDisplayScreenSize(physicalID)
        let vdPx = (CGDisplayPixelsWide(virtualID), CGDisplayPixelsHigh(virtualID))
        let physPx = (CGDisplayPixelsWide(physicalID), CGDisplayPixelsHigh(physicalID))

        log("  Virtual:  \(Int(vdSize.width))x\(Int(vdSize.height))mm " +
            "(\(vdPx.0)x\(vdPx.1)px" +
            (vdSize.width > 0 ? ", \(String(format: "%.0f", Double(vdPx.0) / (vdSize.width / 25.4))) PPI" : "") + ")")
        log("  Physical: \(Int(physSize.width))x\(Int(physSize.height))mm " +
            "(\(physPx.0)x\(physPx.1)px" +
            (physSize.width > 0 ? ", \(String(format: "%.0f", Double(physPx.0) / (physSize.width / 25.4))) PPI" : "") + ")")
    }

    // MARK: - PQ gamma correction

    private func applyPQGammaCorrection(displayID: CGDirectDisplayID) {
        let size: UInt32 = 256
        var table = [CGGammaValue](repeating: 0, count: Int(size))

        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875

        for i in 0..<Int(size) {
            let pq = Double(i) / Double(size - 1)
            let t = pow(pq, 1.0 / m2)
            let den = c2 - c3 * t
            var linear = 0.0
            if den > 0 && t > c1 {
                linear = pow((t - c1) / den, 1.0 / m1)
            }
            linear = min(max(linear * 100.0, 0), 1)
            table[i] = CGGammaValue(pow(linear, 1.0 / 2.2))
        }

        CGSetDisplayTransferByTable(displayID, size, table, table, table)
    }
}
