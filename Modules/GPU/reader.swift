//
//  reader.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct device {
    public let vendor: String?
    public let model: String
    public let pci: String
    public var used: Bool
}

let vendors: [Data: String] = [
    Data.init([0x86, 0x80, 0x00, 0x00]): "Intel",
    Data.init([0x02, 0x10, 0x00, 0x00]): "AMD"
]

internal class InfoReader: Reader<GPUs> {
    private var gpus: GPUs = GPUs()
    private var displays: [gpu_s] = []
    private var devices: [device] = []
    private var channels: CFMutableDictionary? = nil
    private var subscription: IOReportSubscriptionRef? = nil
    private var previousGPUPower: Double = 0
    private var previousThrottleCounter: Double = 0
    private var hasThrottleData: Bool = false
    
    public override func setup() {
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        self.channels = self.getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
        dict?.release()
        
        guard let PCIdevices = fetchIOService("IOPCIDevice") else {
            return
        }
        let devices = PCIdevices.filter{ $0.object(forKey: "IOName") as? String == "display" }
        
        devices.forEach { (dict: NSDictionary) in
            guard let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data else {
                error("device-id or vendor-id not found", log: self.log)
                return
            }
            let pci = "0x" + Data([deviceID[1], deviceID[0], vendorID[1], vendorID[0]]).map { String(format: "%02hhX", $0) }.joined().lowercased()
            
            guard let modelData = dict["model"] as? Data, let modelName = String(data: modelData, encoding: .ascii) else {
                error("GPU model not found", log: self.log)
                return
            }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            
            var vendor: String? = nil
            if let v = vendors.first(where: { $0.key == vendorID }) {
                vendor = v.value
            }
            
            self.devices.append(device(
                vendor: vendor,
                model: model,
                pci: pci,
                used: false
            ))
        }
    }

    public override func terminate() {
        self.subscription = nil
        self.channels = nil
    }
    
    public override func read() {
        guard let accelerators = fetchIOService(kIOAcceleratorClassName) else {
            return
        }
        let (gpuPower, throttleFromIOReport) = self.readPowerAndThrottle()
        var devices = self.devices
        
        for (index, accelerator) in accelerators.enumerated() {
            guard let IOClass = accelerator.object(forKey: "IOClass") as? String else {
                error("IOClass not found", log: self.log)
                return
            }
            
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else {
                error("PerformanceStatistics not found", log: self.log)
                return
            }
            
            var id: String = ""
            var vendor: String? = nil
            var model: String = ""
            var cores: Int? = nil
            var memoryTotal: Int64? = nil
            let accMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? "").lowercased()
            
            for (i, device) in devices.enumerated() {
                if accMatch.range(of: device.pci) != nil && !device.used {
                    model = device.model
                    vendor = device.vendor
                    id = "\(model) #\(index)"
                    devices[i].used = true
                    break
                }
            }
            
            let ioClass = IOClass.lowercased()
            var predictModel = ""
            var type: GPU_types = .unknown
            
            let utilization = self.readUtilization(stats: stats, keys: ["Device Utilization %", "GPU Activity(%)"])
            let renderUtilization = self.readUtilization(stats: stats, keys: ["Renderer Utilization %", "Render Utilization %"])
            let tilerUtilization = self.readUtilization(stats: stats, keys: ["Tiler Utilization %"])
            let encodeUtilization = self.readUtilization(
                stats: stats,
                keys: ["Video Encoder Utilization %", "Encoder Utilization %"]
            ) ?? self.readUtilizationMatching(tokens: ["encoder"], in: stats)
            let decodeUtilization = self.readUtilization(
                stats: stats,
                keys: ["Video Decoder Utilization %", "Decoder Utilization %"]
            ) ?? self.readUtilizationMatching(tokens: ["decoder"], in: stats)
            let blitUtilization = self.readUtilization(
                stats: stats,
                keys: ["Blitter Utilization %", "Blit Utilization %", "Blit Engine Utilization %"]
            ) ?? self.readUtilizationMatching(tokens: ["blit"], in: stats)
            let computeUtilization = self.readUtilization(
                stats: stats,
                keys: ["Compute Utilization %", "Compute Engine Utilization %"]
            ) ?? self.readUtilizationMatching(tokens: ["compute"], in: stats)
            var temperature: Int? = self.readInt(stats["Temperature(C)"])
            let fanSpeed: Int? = self.readInt(stats["Fan Speed(%)"])
            let coreClock: Int? = self.readInt(stats["Core Clock(MHz)"])
            let memoryClock: Int? = self.readInt(stats["Memory Clock(MHz)"])
            let memoryAllocated = self.readInt64(stats["Alloc system memory"])
            let memoryUsed = self.readInt64(stats["In use system memory"]) ?? self.readInt64(stats["In use system memory (driver)"])
            let throttling = self.readThrottling(stats: stats) ?? throttleFromIOReport
            
            if ioClass == "nvaccelerator" || ioClass.contains("nvidia") { // nvidia
                predictModel = "Nvidia Graphics"
                type = .discrete
            } else if ioClass.contains("amd") { // amd
                predictModel = "AMD Graphics"
                type = .discrete
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TGDD"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("intel") { // intel
                predictModel = "Intel Graphics"
                type = .integrated
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TCGC"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("agx") { // apple
                predictModel = stats["model"] as? String ?? "Apple Graphics"
                if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                    if let name = display.name {
                        predictModel = name
                    }
                    if let num = display.cores {
                        cores = num
                    }
                    if let memory = display.vram {
                        memoryTotal = self.parseMemoryString(memory)
                    }
                }
                type = .integrated
            } else {
                predictModel = "Unknown"
                type = .unknown
            }
            
            if model == "" {
                model = predictModel
            }
            if let v = vendor {
                model = model.removedRegexMatches(pattern: v, replaceWith: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if id.isEmpty {
                id = "\(model) #\(index)"
            }
            if let display = self.findDisplay(model: model, vendor: vendor, isApple: ioClass.contains("agx")) {
                if cores == nil {
                    cores = display.cores
                }
                if memoryTotal == nil, let memory = display.vram {
                    memoryTotal = self.parseMemoryString(memory)
                }
            }
            
            if self.gpus.list.first(where: { $0.id == id }) == nil {
                self.gpus.list.append(GPU_Info(
                    id: id,
                    type: type.rawValue,
                    IOClass: IOClass,
                    vendor: vendor,
                    model: model,
                    cores: cores
                ))
            }
            guard let idx = self.gpus.list.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            if let agcInfo = accelerator["AGCInfo"] as? [String: Int], let state = agcInfo["poweredOffByAGC"] {
                self.gpus.list[idx].state = state == 0
            }
            
            self.gpus.list[idx].utilization = utilization
            self.gpus.list[idx].renderUtilization = renderUtilization
            self.gpus.list[idx].tilerUtilization = tilerUtilization
            self.gpus.list[idx].encodeUtilization = encodeUtilization
            self.gpus.list[idx].decodeUtilization = decodeUtilization
            self.gpus.list[idx].blitUtilization = blitUtilization
            self.gpus.list[idx].computeUtilization = computeUtilization
            self.gpus.list[idx].memoryAllocated = memoryAllocated
            self.gpus.list[idx].memoryUsed = memoryUsed
            if let total = memoryTotal {
                self.gpus.list[idx].memoryTotal = total
            }
            self.gpus.list[idx].throttling = throttling

            if let value = temperature {
                self.gpus.list[idx].temperature = Double(value)
            }
            if let value = gpuPower {
                self.gpus.list[idx].power = value
            }
            if let value = fanSpeed {
                self.gpus.list[idx].fanSpeed = value
            }
            if let value = coreClock {
                self.gpus.list[idx].coreClock = value
            }
            if let value = memoryClock {
                self.gpus.list[idx].memoryClock = value
            }
        }
        
        self.gpus.list.sort{ !$0.state && $1.state }
        self.callback(self.gpus)
    }

    private func readNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as UInt64:
            return Double(value)
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as String:
            let normalized = value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(normalized)
        default:
            return nil
        }
    }

    private func readInt(_ value: Any?) -> Int? {
        if let n = self.readNumber(value) {
            return Int(n)
        }
        return nil
    }

    private func readInt64(_ value: Any?) -> Int64? {
        if let n = self.readNumber(value) {
            return Int64(n)
        }
        return nil
    }

    private func normalizeUtilization(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value.isNaN || value.isInfinite {
            return nil
        }
        return min(max(value, 0), 100) / 100
    }

    private func readUtilization(stats: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = self.normalizeUtilization(self.readNumber(stats[key])) {
                return value
            }
        }
        return nil
    }

    private func readUtilizationMatching(tokens: [String], in stats: [String: Any]) -> Double? {
        for key in stats.keys.sorted() {
            let normalizedKey = key.lowercased()
            if !normalizedKey.contains("utilization") {
                continue
            }
            if !tokens.allSatisfy({ normalizedKey.contains($0.lowercased()) }) {
                continue
            }
            if let value = self.normalizeUtilization(self.readNumber(stats[key])) {
                return value
            }
        }
        return nil
    }

    private func readThrottling(stats: [String: Any]) -> Bool? {
        for (key, value) in stats {
            let normalizedKey = key.lowercased()
            if normalizedKey.contains("throttle") || normalizedKey.contains("cltm") {
                if let v = self.readNumber(value) {
                    return v > 0
                }
            }
        }
        return nil
    }

    private func findDisplay(model: String, vendor: String?, isApple: Bool) -> gpu_s? {
        if isApple {
            return self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) ?? self.displays.first
        }
        return self.displays.first(where: { display in
            let name = display.name?.lowercased() ?? ""
            let modelName = model.lowercased()
            if !name.isEmpty && (!modelName.isEmpty && (name.contains(modelName) || modelName.contains(name))) {
                return true
            }
            if let vendor, let displayVendor = display.vendor {
                return displayVendor.lowercased().contains(vendor.lowercased())
            }
            return false
        })
    }

    private func parseMemoryString(_ raw: String) -> Int64? {
        let value = raw.uppercased().replacingOccurrences(of: ",", with: ".")
        let pattern = "([0-9]+(?:\\.[0-9]+)?)\\s*([KMGT])B"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: value, options: [], range: NSRange(location: 0, length: value.utf16.count)),
              let numberRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let number = Double(String(value[numberRange])) else {
            return nil
        }
        let unit = String(value[unitRange])
        let multiplier: Double
        switch unit {
        case "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        case "G": multiplier = 1_000_000_000
        case "T": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }

    private func getChannels() -> CFMutableDictionary? {
        let channelNames: [(String, String?)] = [("Energy Model", nil), ("GPU Stats", nil)]

        var channels: [CFDictionary] = []
        for (gname, sname) in channelNames {
            let channel = IOReportCopyChannelsInGroup(gname as CFString?, sname as CFString?, 0, 0, 0)
            guard let channel = channel?.takeRetainedValue() else { continue }
            channels.append(channel)
        }
        guard let first = channels.first else { return nil }

        for i in 1..<channels.count {
            IOReportMergeChannels(first, channels[i], nil)
        }

        let size = CFDictionaryGetCount(first)
        guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, first),
              let chan = channel as? [String: Any], chan["IOReportChannels"] != nil else {
            return nil
        }
        return channel
    }

    private func readPowerAndThrottle() -> (Double?, Bool?) {
        guard let sample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue(),
              let dict = sample as? [String: Any] else {
            return (nil, nil)
        }
        let items = dict["IOReportChannels"] as! CFArray

        var powerValue: Double? = nil
        var throttleCounter: Double? = nil

        for i in 0..<CFArrayGetCount(items) {
            let dict = CFArrayGetValueAtIndex(items, i)
            let item = unsafeBitCast(dict, to: CFDictionary.self)

            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String else {
                continue
            }

            if group == "Energy Model" && channel.hasSuffix("GPU Energy") {
                if let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String {
                    powerValue = Double(IOReportSimpleGetIntegerValue(item, 0)).power(unit)
                }
            } else if group == "GPU Stats" && channel.lowercased().contains("throttle counter total") {
                throttleCounter = Double(IOReportSimpleGetIntegerValue(item, 0))
            }
        }

        var power: Double? = nil
        if let current = powerValue {
            if self.previousGPUPower != 0 {
                power = max(current - self.previousGPUPower, 0)
            }
            self.previousGPUPower = current
        }

        var throttling: Bool? = nil
        if let counter = throttleCounter {
            if self.previousThrottleCounter != 0 {
                throttling = (counter - self.previousThrottleCounter) > 0
            } else {
                throttling = false
            }
            self.previousThrottleCounter = counter
            self.hasThrottleData = true
        }

        return (power, self.hasThrottleData ? throttling : nil)
    }
}

public class ProcessReader: Reader<[TopProcess]> {
    private let title: String = "GPU"
    private var previousTimes: [Int: Int64] = [:]
    private var processNames: [Int: String] = [:]
    private var lastRead: Date = Date()

    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 8)
    }

    public override func setup() {
        self.popup = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 1))
    }

    public override func read() {
        if self.numberOfProcesses == 0 {
            self.callback([])
            return
        }

        guard let clients = fetchIOService("AGXDeviceUserClient") else {
            self.callback([])
            return
        }

        var currentTimes: [Int: Int64] = [:]
        var currentNames: [Int: String] = [:]

        clients.forEach { (dict: NSDictionary) in
            guard let creator = dict["IOUserClientCreator"] as? String,
                  let (pid, name) = self.parseCreator(creator) else {
                return
            }

            let usageTime = self.totalGPUTime(dict["AppUsage"])
            guard usageTime > 0 else {
                return
            }

            currentTimes[pid, default: 0] += usageTime
            if currentNames[pid] == nil {
                currentNames[pid] = name
            }
        }

        let now = Date()
        let elapsed = max(now.timeIntervalSince(self.lastRead), 0.2)
        var list: [TopProcess] = []

        for (pid, totalGPUTime) in currentTimes {
            let previous = self.previousTimes[pid] ?? totalGPUTime
            let delta = max(totalGPUTime - previous, 0)
            guard delta > 0 else { continue }

            var usage = (Double(delta) / 1_000_000_000.0) / elapsed * 100
            if usage.isNaN || usage.isInfinite || usage <= 0 {
                continue
            }
            usage = min(usage, 999)

            var processName = currentNames[pid] ?? self.processNames[pid] ?? "\(pid)"
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let localizedName = app.localizedName {
                processName = localizedName
            }

            list.append(TopProcess(pid: pid, name: processName, usage: usage))
        }

        list.sort { $0.usage > $1.usage }
        self.callback(Array(list.prefix(self.numberOfProcesses)))

        self.previousTimes = currentTimes
        self.processNames = currentNames.merging(self.processNames) { current, _ in current }
        self.lastRead = now
    }

    private func parseCreator(_ raw: String) -> (Int, String)? {
        let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let pidString = String(first).replacingOccurrences(of: "pid", with: "").trimmingCharacters(in: .whitespaces)
        guard let pid = Int(pidString) else { return nil }
        let name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "\(pid)"
        return (pid, name.isEmpty ? "\(pid)" : name)
    }

    private func totalGPUTime(_ raw: Any?) -> Int64 {
        var total: Int64 = 0

        if let usage = raw as? [NSDictionary] {
            usage.forEach { item in
                if let value = item["accumulatedGPUTime"] as? NSNumber {
                    total += value.int64Value
                } else if let value = item["accumulatedGPUTime"] as? Int64 {
                    total += value
                } else if let value = item["accumulatedGPUTime"] as? Int {
                    total += Int64(value)
                }
            }
            return total
        }

        if let usage = raw as? [[String: Any]] {
            usage.forEach { item in
                if let value = item["accumulatedGPUTime"] as? NSNumber {
                    total += value.int64Value
                } else if let value = item["accumulatedGPUTime"] as? Int64 {
                    total += value
                } else if let value = item["accumulatedGPUTime"] as? Int {
                    total += Int64(value)
                }
            }
        }

        return total
    }
}
