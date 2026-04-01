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
    @Published var lastError: String? = nil      // 记录最近的错误

    private var timer: Timer?
    private var prevNetBytes: (up: UInt64, down: UInt64) = (0, 0)
    private var prevNetTime: Date = Date()
    private var retryCount: Int = 0
    private let maxRetries = 3

    // CPU 上一次的 ticks
    private var prevCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)

    // 支持的网络接口前缀（物理网卡和常用虚拟接口）
    private let validNetworkPrefixes = ["en", "pdp_ip", "utun", "bridge"]

    init() {
        totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        // 初始化网络基准
        if let (up, down) = readNetBytes() {
            prevNetBytes = (up, down)
            prevNetTime = Date()
        }
        // 初始化 CPU 基准
        prevCPUTicks = readCPUTicks()

        // 使用 common mode 保证在所有 RunLoop 模式下都能触发
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    deinit {
        timer?.invalidate()
    }

    private func update() {
        // 失败时重试
        do {
            try updateCPUWithRetry()
            updateMemory()
            updateNetworkWithRetry()
            retryCount = 0  //成功后重置
            lastError = nil
        } catch {
            retryCount += 1
            if retryCount <= maxRetries {
                print("SystemMonitor update failed (retry \(retryCount)/\(maxRetries)): \(error)")
            } else {
                lastError = "监控数据获取失败: \(error.localizedDescription)"
                retryCount = 0
            }
        }
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

    private func updateCPUWithRetry() throws {
        let cur = readCPUTicks()
        guard cur.user > 0 || cur.sys > 0 || cur.idle > 0 else {
            throw NSError(domain: "SystemMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "CPU 数据读取失败"])
        }

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

        // 使用更准确的内存压力计算：
        // memory pressure = (wired + compressed + internal) / total
        let wiredPages     = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let internalPages  = UInt64(stats.internal_page_count)

        let totalPages     = UInt64(ProcessInfo.processInfo.physicalMemory) / pageSize

        // 内存压力：已使用内存 / 总内存
        let usedPages = wiredPages + compressedPages + internalPages
        let pressure = totalPages > 0 ? Double(usedPages) / Double(totalPages) : 0
        let used = usedPages * pageSize
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)

        DispatchQueue.main.async {
            self.usedMemoryGB   = Double(used) / gib
            self.totalMemoryGB  = Double(total) / gib
            self.memoryPressure = min(pressure, 1.0)
        }
    }

    // MARK: - Network

    private func readNetBytes() -> (up: UInt64, down: UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        var up: UInt64 = 0
        var down: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = ptr {
            let addr = current.pointee
            if addr.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: addr.ifa_name)
                // 过滤有效的网络接口
                if validNetworkPrefixes.contains(where: { name.hasPrefix($0) }) {
                    // 排除虚拟接口中的一些特殊情况
                    if !isExcludedInterface(name) {
                        if let data = addr.ifa_data {
                            let netData = data.assumingMemoryBound(to: if_data.self).pointee
                            up   += UInt64(netData.ifi_obytes)
                            down += UInt64(netData.ifi_ibytes)
                        }
                    }
                }
            }
            ptr = addr.ifa_next
        }
        return (up, down)
    }

    /// 检查是否需要排除的接口
    private func isExcludedInterface(_ name: String) -> Bool {
        // 排除 utun 编号较高的虚拟接口（VPN 等）
        if name.hasPrefix("utun") {
            let suffix = name.dropFirst(4)
            if let num = Int(suffix), num >= 10 {
                return true  // 排除 utun10+
            }
        }
        return false
    }

    private func updateNetworkWithRetry() {
        guard let cur = readNetBytes() else { return }

        let now = Date()
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
