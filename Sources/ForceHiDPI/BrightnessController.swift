// BrightnessController.swift
//
// DDC/CI brightness control for the external display over I2C via
// IOAVService (the Apple-Silicon replacement for IOFramebufferService).
//
// The IORegistry walk, service-scoring heuristic, and DDC packet format are
// ported from MonitorControl's Arm64DDC.swift (© MonitorControl contributors
// @JoniVR, @theOneyouseek, @waydabber, and others; MIT licence — see
// https://github.com/MonitorControl/MonitorControl).
//
// Trimmed for a single target display: no polling, no read-back, no smoothing,
// just VCP 0x10 writes dispatched on a background queue.

import CoreGraphics
import Foundation
import IOKit
import CPrivateAPI

final class BrightnessController {
    // DDC/CI 7-bit addresses for DisplayPort/HDMI.
    private static let ddcAddress: UInt8 = 0x37
    private static let ddcDataAddress: UInt8 = 0x51
    // VCP opcode for luminance / backlight brightness.
    private static let vcpBrightness: UInt8 = 0x10
    // MC uses this as a ceiling on sensible match scores.
    private static let maxMatchScore = 20

    private struct IORegEntry {
        var edidUUID = ""
        var productName = ""
        var serialNumber: Int64 = 0
        var ioDisplayLocation = ""
        var location = ""
        var service: IOAVService?
        var serviceLocation = 0
    }

    private var service: IOAVService?
    private let writeQueue = DispatchQueue(label: "com.force-hidpi.brightness", qos: .userInitiated)
    private let stateLock = NSLock()
    private var pendingValue: UInt16?
    private var writerActive = false
    private var lastWrittenValue: UInt16?

    var isAvailable: Bool { service != nil }

    // MARK: - Public API

    /// Locate and cache the IOAVService corresponding to the given physical
    /// display. Returns true on success.
    @discardableResult
    func resolve(displayID: CGDirectDisplayID) -> Bool {
        invalidate()
        let candidates = Self.enumerateIORegistry()
        var best: (entry: IORegEntry, score: Int)?
        for candidate in candidates where candidate.service != nil {
            let score = Self.matchScore(displayID: displayID, entry: candidate)
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        guard let match = best, match.score > 0 else { return false }
        service = match.entry.service
        return true
    }

    func invalidate() {
        stateLock.lock()
        service = nil
        pendingValue = nil
        lastWrittenValue = nil
        stateLock.unlock()
    }

    /// Set brightness as a 0.0...1.0 float. Rapid calls (slider drags) coalesce
    /// to the most recent value: only one writer runs at a time, and when it
    /// finishes it picks up whatever the latest target is. UI thread never
    /// blocks on I2C latency.
    func setBrightness(_ value: Float) {
        guard let service else { return }
        let clamped = max(0, min(1, value))
        let raw = UInt16(Float(100) * clamped)

        stateLock.lock()
        pendingValue = raw
        let shouldStartWriter = !writerActive
        if shouldStartWriter { writerActive = true }
        stateLock.unlock()

        guard shouldStartWriter else { return }
        writeQueue.async { [weak self] in
            self?.drainWrites(service: service)
        }
    }

    private func drainWrites(service: IOAVService) {
        while true {
            stateLock.lock()
            guard let target = pendingValue else {
                writerActive = false
                stateLock.unlock()
                return
            }
            pendingValue = nil
            let last = lastWrittenValue
            stateLock.unlock()

            if target == last { continue }
            if Self.writeVCP(service: service, code: Self.vcpBrightness, value: target) {
                stateLock.lock()
                lastWrittenValue = target
                stateLock.unlock()
            }
        }
    }

    // MARK: - DDC packet

    private static func writeVCP(service: IOAVService, code: UInt8, value: UInt16) -> Bool {
        // Packet layout:  [sync, length, opcode, valueHi, valueLo, checksum]
        //   sync     = 0x80 | (data length + 1)   = 0x84 for a 3-byte payload
        //   length   = payload byte count         = 0x03
        //   opcode   = VCP code                    (0x10 for brightness)
        //   valueHi  = (value >> 8) & 0xFF
        //   valueLo  = value & 0xFF
        //   checksum = XOR of seed and all preceding packet bytes
        //
        // Seed depends on whether the payload is multi-byte (write) or single
        // (read). For writes: seed = (address << 1) XOR dataAddress.
        let payload: [UInt8] = [code, UInt8(value >> 8), UInt8(value & 0xFF)]
        var packet: [UInt8] = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)]
        packet.append(contentsOf: payload)
        packet.append(0)

        var chk: UInt8 = (ddcAddress << 1) ^ ddcDataAddress
        for i in 0..<(packet.count - 1) { chk ^= packet[i] }
        packet[packet.count - 1] = chk

        // Retry loop mirrors MonitorControl's defaults for stubborn displays.
        // Write succeeds reliably on first attempt for most panels; the retries
        // are a safety net for HDMI TMDS glitches and USB-C dock pass-through.
        for _ in 0..<5 {
            for _ in 0..<2 {
                usleep(10_000)
                let rc = packet.withUnsafeMutableBufferPointer { buf -> IOReturn in
                    IOAVServiceWriteI2C(service,
                                        UInt32(ddcAddress),
                                        UInt32(ddcDataAddress),
                                        buf.baseAddress,
                                        UInt32(buf.count))
                }
                if rc == 0 { return true }
            }
            usleep(20_000)
        }
        return false
    }

    // MARK: - IORegistry enumeration

    private static func enumerateIORegistry() -> [IORegEntry] {
        var results: [IORegEntry] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root,
                                            "IOService",
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else {
            return results
        }
        defer { IOObjectRelease(iterator) }

        let framebufferNames = ["AppleCLCD2", "IOMobileFramebufferShim"]
        let proxyName = "DCPAVServiceProxy"

        var pending = IORegEntry()
        var serviceLocation = 0

        while let next = iterateToNext(interests: framebufferNames + [proxyName],
                                        iterator: &iterator) {
            if framebufferNames.contains(next.name) {
                pending = framebufferProperties(entry: next.entry)
                serviceLocation += 1
                pending.serviceLocation = serviceLocation
            } else if next.name == proxyName {
                attachAVService(entry: next.entry, into: &pending)
                results.append(pending)
            }
            IOObjectRelease(next.entry)
        }
        return results
    }

    private static func iterateToNext(interests: [String],
                                      iterator: inout io_iterator_t) -> (name: String, entry: io_service_t)? {
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { nameBuf.deallocate() }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != MACH_PORT_NULL else { return nil }
            guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                continue
            }
            let name = String(cString: nameBuf)
            if interests.contains(where: { name.contains($0) }) {
                return (name, entry)
            }
            IOObjectRelease(entry)
        }
    }

    private static func framebufferProperties(entry: io_service_t) -> IORegEntry {
        var e = IORegEntry()

        if let raw = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString,
                                                     kCFAllocatorDefault,
                                                     IOOptionBits(kIORegistryIterateRecursively)),
           let uuid = raw.takeRetainedValue() as? String {
            e.edidUUID = uuid
        }

        let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { pathBuf.deallocate() }
        if IORegistryEntryGetPath(entry, kIOServicePlane, pathBuf) == KERN_SUCCESS {
            e.ioDisplayLocation = String(cString: pathBuf)
        }

        if let raw = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                     kCFAllocatorDefault,
                                                     IOOptionBits(kIORegistryIterateRecursively)),
           let attrs = raw.takeRetainedValue() as? NSDictionary,
           let product = attrs["ProductAttributes"] as? NSDictionary {
            e.productName = (product["ProductName"] as? String) ?? ""
            e.serialNumber = (product["SerialNumber"] as? Int64) ?? 0
        }
        return e
    }

    private static func attachAVService(entry: io_service_t, into e: inout IORegEntry) {
        guard let raw = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                        kCFAllocatorDefault,
                                                        IOOptionBits(kIORegistryIterateRecursively)),
              let location = raw.takeRetainedValue() as? String else {
            return
        }
        e.location = location
        // DCPAVServiceProxy entries for internal panels return "Embedded"; we
        // only want external DDC-capable links.
        if location == "External" {
            e.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
        }
    }

    // MARK: - Scoring
    //
    // Correlates an IORegistry framebuffer entry with a CGDirectDisplayID by
    // looking for known EDID substrings (vendor, product, manufacture date,
    // image size) inside the IORegistry's "EDID UUID" string. Each match adds
    // a point; the IODisplayLocation match is worth 10 because it's unique
    // per port.

    private static func matchScore(displayID: CGDirectDisplayID, entry: IORegEntry) -> Int {
        var score = 0
        guard let infoRef = CoreDisplay_DisplayCreateInfoDictionary(displayID) else { return score }
        let info = infoRef.takeRetainedValue() as NSDictionary

        if let year = info[kDisplayYearOfManufacture] as? Int64,
           let week = info[kDisplayWeekOfManufacture] as? Int64,
           let vendor = info[kDisplayVendorID] as? Int64,
           let product = info[kDisplayProductID] as? Int64,
           let hImg = info[kDisplayHorizontalImageSize] as? Int64,
           let vImg = info[kDisplayVerticalImageSize] as? Int64 {

            let vendorKey = String(format: "%04X", UInt16(clamping: vendor))
            let productLE = UInt16(clamping: product)
            let productKey = String(format: "%02X%02X", UInt8(productLE & 0xFF), UInt8((productLE >> 8) & 0xFF))
            let dateKey = String(format: "%02X%02X",
                                 UInt8(clamping: week),
                                 UInt8(clamping: max(0, year - 1990)))
            let sizeKey = String(format: "%02X%02X",
                                 UInt8(clamping: hImg / 10),
                                 UInt8(clamping: vImg / 10))

            let candidates: [(key: String, loc: Int)] = [
                (vendorKey, 0),
                (productKey, 4),
                (dateKey, 19),
                (sizeKey, 30),
            ]
            for candidate in candidates where candidate.key != "0000" {
                let start = candidate.loc
                let end = start + 4
                guard entry.edidUUID.count >= end else { continue }
                let startIdx = entry.edidUUID.index(entry.edidUUID.startIndex, offsetBy: start)
                let endIdx = entry.edidUUID.index(entry.edidUUID.startIndex, offsetBy: end)
                if String(entry.edidUUID[startIdx..<endIdx]).uppercased() == candidate.key {
                    score += 1
                }
            }
        }

        if !entry.ioDisplayLocation.isEmpty,
           let dispLoc = info[kIODisplayLocationKey] as? String,
           dispLoc == entry.ioDisplayLocation {
            score += 10
        }
        if !entry.productName.isEmpty,
           let names = info["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.first?.value,
           name.lowercased() == entry.productName.lowercased() {
            score += 1
        }
        if entry.serialNumber != 0,
           let serial = info[kDisplaySerialNumber] as? Int64,
           serial == entry.serialNumber {
            score += 1
        }
        return min(score, maxMatchScore)
    }
}
