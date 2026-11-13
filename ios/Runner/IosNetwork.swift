import Darwin
import Flutter
import Network
import UIKit

final class IosNetwork: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var monitor: NWPathMonitor?
  private var browser: NWBrowser?
  private var serviceType = ""
  private var subnet: String?
  private var lastEvent: String?
  private var foreground = false

  func onListen(
    withArguments arguments: Any?, eventSink: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard let type = arguments as? String else {
      return FlutterError(code: "discovery_failed", message: nil, details: nil)
    }
    sink = eventSink
    serviceType = type
    foreground = UIApplication.shared.applicationState != .background
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(enterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(self, selector: #selector(enterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self, weak monitor] path in
      guard let self, self.monitor === monitor else { return }
      self.updateSubnet(path)
    }
    monitor.start(queue: .main)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    stopBrowser()
    monitor?.cancel()
    monitor = nil
    sink = nil
    subnet = nil
    lastEvent = nil
    return nil
  }

  func refresh() {
    if let monitor { updateSubnet(monitor.currentPath, force: true) }
  }

  @objc private func enterBackground() {
    foreground = false
    stopBrowser()
    if let subnet, subnet == lastEvent { emit("") }
  }

  @objc private func enterForeground() {
    foreground = true
    refresh()
  }

  private func updateSubnet(_ path: NWPath, force: Bool = false) {
    let next = Self.ipv4Subnet(path)
    guard force || subnet != next else { return }
    if let subnet, subnet != next { emit("") }
    subnet = next
    startBrowser()
  }

  private func startBrowser() {
    stopBrowser()
    guard foreground, let subnet else { return }
    guard !subnet.isEmpty else {
      emit("")
      return
    }
    // Bonsoir handles peers and registration. A browser tracks the OS permission
    // state because Bonsoir does not surface NWBrowser.waiting.
    let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: .tcp)
    self.browser = browser
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      guard let self, self.browser === browser else { return }
      switch state {
      case .ready:
        self.emit(subnet)
      case .waiting(let error), .failed(let error):
        if case .dns(let code) = error, Int(code) == Int(kDNSServiceErr_PolicyDenied) {
          self.emit("network_permission", error: true)
        } else {
          self.emit("discovery_failed", error: true)
        }
      default: break
      }
    }
    browser.start(queue: .main)
  }

  private func stopBrowser() {
    let active = browser
    browser = nil
    active?.cancel()
  }

  private func emit(_ value: String, error: Bool = false) {
    guard lastEvent != value else { return }
    lastEvent = value
    if error {
      sink?(FlutterError(code: value, message: nil, details: nil))
    } else {
      sink?(value)
    }
  }

  private static func ipv4Subnet(_ path: NWPath) -> String {
    let interfaces = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
    guard !interfaces.isEmpty else { return "" }
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return "" }
    defer { freeifaddrs(first) }

    let activeFlags = UInt32(IFF_UP | IFF_RUNNING)
    let names = Set(interfaces.map(\.name))
    var subnets: [String: String] = [:]
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard let address = entry.ifa_addr, let mask = entry.ifa_netmask,
            Int32(address.pointee.sa_family) == AF_INET,
            entry.ifa_flags & activeFlags == activeFlags else { continue }
      let name = String(cString: entry.ifa_name)
      guard names.contains(name) else { continue }
      var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr
      }
      let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
      }
      let prefix = bits.nonzeroBitCount
      guard prefix > 0, bits == UInt32.max << (32 - prefix) else { continue }
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      let length = socklen_t(buffer.count)
      guard inet_ntop(AF_INET, &ip, &buffer, length) != nil else { continue }
      subnets[name] = "\(String(cString: buffer))/\(prefix)"
    }
    return interfaces.compactMap { subnets[$0.name] }.first ?? ""
  }
}
