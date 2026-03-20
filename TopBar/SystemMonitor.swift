//
//  SystemMonitor.swift
//  TopBar
//
//  Created by ER on 2026/3/20.
//

import Foundation
import Combine
import Darwin

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0        // 0.0 ~ 1.0
    @Published var usedMemoryGB: Double = 0.0
    @Published var totalMemoryGB: Double = 0.0
    @Published var memoryPressure: Double = 0.0  // 0.0 ~ 1.0
    @Published var uploadSpeed: Double = 0.0     // KB/s
    @Published var downloadSpeed: Double = 0.0   // KB/s

    private var timer: Timer?
    private var prevNetBytes: (up: UInt64, down: UInt64) = (0, 0)
    private var prevNetTime: Date = Date()

    // CPU 上一次的 ticks
    private var prevCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)

    init() {
        totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        // 初始化网络基准
        prevNetBytes = readNetBytes()
        prevNetTime = Date()
        // 初始化 CPU 基准
        prevCPUTicks = readCPUTicks()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func update() {
        updateCPU()
        updateMemory()
        updateNetwork()
    }

    // MARK: - CPU

    private func readCPUTicks() -> (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64) {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs,
                                         &cpuInfo,
                                         &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return (0, 0, 0, 0)
        }

        var user: UInt64 = 0
        var sys:  UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(numCPUs) {
            user += UInt64(info[i * stride + Int(CPU_STATE_USER)])
            sys  += UInt64(info[i * stride + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(info[i * stride + Int(CPU_STATE_IDLE)])
            nice += UInt64(info[i * stride + Int(CPU_STATE_NICE)])
        }

        // 释放 mach 分配的内存
        let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)

        return (user, sys, idle, nice)
    }

    private func updateCPU() {
        let cur = readCPUTicks()
        let prev = prevCPUTicks

        let dUser = cur.user > prev.user ? cur.user - prev.user : 0
        let dSys  = cur.sys  > prev.sys  ? cur.sys  - prev.sys  : 0
        let dIdle = cur.idle > prev.idle ? cur.idle - prev.idle : 0
        let dNice = cur.nice > prev.nice ? cur.nice - prev.nice : 0
        let total = dUser + dSys + dIdle + dNice

        prevCPUTicks = cur
        DispatchQueue.main.async {
            self.cpuUsage = total > 0 ? Double(dUser + dSys + dNice) / Double(total) : 0
        }
    }

    // MARK: - Memory

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        let gib      = Double(1024 * 1024 * 1024)

        // 已确认公式：internal + wired + compressor
        let usedPages = UInt64(stats.internal_page_count)
                      + UInt64(stats.wire_count)
                      + UInt64(stats.compressor_page_count)
        let used  = usedPages * pageSize
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)
        let pressure = total > 0 ? Double(used) / Double(total) : 0

        DispatchQueue.main.async {
            self.usedMemoryGB   = Double(used) / gib
            self.totalMemoryGB  = Double(total) / gib
            self.memoryPressure = min(pressure, 1.0)
        }
    }

    // MARK: - Network

    private func readNetBytes() -> (up: UInt64, down: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(firstAddr) }

        var up: UInt64 = 0
        var down: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let addr = current.pointee
            if addr.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: addr.ifa_name)
                // 只统计物理网卡，排除 lo/utun/bridge 等虚拟接口
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    if let data = addr.ifa_data {
                        let netData = data.assumingMemoryBound(to: if_data.self).pointee
                        up   += UInt64(netData.ifi_obytes)
                        down += UInt64(netData.ifi_ibytes)
                    }
                }
            }
            ptr = addr.ifa_next
        }
        return (up, down)
    }

    private func updateNetwork() {
        let now = Date()
        let cur = readNetBytes()
        let elapsed = now.timeIntervalSince(prevNetTime)

        guard elapsed > 0 else { return }

        let upDiff   = cur.up   >= prevNetBytes.up   ? cur.up   - prevNetBytes.up   : 0
        let downDiff = cur.down >= prevNetBytes.down ? cur.down - prevNetBytes.down : 0

        let upKBs   = Double(upDiff)   / elapsed / 1024
        let downKBs = Double(downDiff) / elapsed / 1024

        prevNetBytes = cur
        prevNetTime  = now

        DispatchQueue.main.async {
            self.uploadSpeed   = upKBs
            self.downloadSpeed = downKBs
        }
    }
}
