//
//  CPU.swift
//  Tests
//

import XCTest
@testable import CPU

final class CPULoadTests: XCTestCase {
    func testCalculateCPUUsageIncludesNiceInUserLoad() {
        let previous = CPUTicks(user: 100, system: 100, nice: 100, idle: 100)
        let current = CPUTicks(user: 120, system: 110, nice: 105, idle: 165)

        let usage = calculateCPUUsage(current: current, previous: previous)

        XCTAssertEqual(usage.system, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(usage.user, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.idle, 0.65, accuracy: 0.000_001)
        XCTAssertEqual(usage.total, 0.35, accuracy: 0.000_001)
    }

    func testCalculateCPUUsageHandlesTickRollover() {
        let previous = CPUTicks(user: UInt32.max - 2, system: 10, nice: 20, idle: 30)
        let current = CPUTicks(user: 3, system: 12, nice: 21, idle: 31)

        let usage = calculateCPUUsage(current: current, previous: previous)

        XCTAssertEqual(usage.system, 0.20, accuracy: 0.000_001)
        XCTAssertEqual(usage.user, 0.70, accuracy: 0.000_001)
        XCTAssertEqual(usage.idle, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(usage.total, 0.90, accuracy: 0.000_001)
    }

    func testCalculateCPUUsageReturnsZeroForNoTickChange() {
        let ticks = CPUTicks(user: 10, system: 20, nice: 30, idle: 40)

        XCTAssertEqual(calculateCPUUsage(current: ticks, previous: ticks), .zero)
    }

    func testMergeHyperthreadedCPUUsageAveragesComponents() {
        let first = CPUUsageBreakdown(system: 0.20, user: 0.40, idle: 0.40, total: 0.60)
        let second = CPUUsageBreakdown(system: 0.40, user: 0.20, idle: 0.40, total: 0.60)

        let merged = mergeHyperthreadedCPUUsage([first, second])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].system, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(merged[0].user, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(merged[0].idle, 0.40, accuracy: 0.000_001)
        XCTAssertEqual(merged[0].total, 0.60, accuracy: 0.000_001)
    }

    func testCPUUsageDecodesLegacyPayloadWithoutPerCoreBreakdown() throws {
        let data = Data("""
        {
          "totalUsage": 0.5,
          "usagePerCore": [0.5],
          "systemLoad": 0.2,
          "userLoad": 0.3,
          "idleLoad": 0.5
        }
        """.utf8)

        let value = try JSONDecoder().decode(CPU_Load.self, from: data)

        XCTAssertNil(value.usagePerCoreSystem)
        XCTAssertNil(value.usagePerCoreUser)
        XCTAssertEqual(value.totalUsage, 0.5)
    }
}
