import Cocoa
import Darwin
import FlutterMacOS
import SystemConfiguration

final class MacOSBridge {
  private weak var window: NSWindow?
  private var scopes: [String: URL] = [:]
  private var lock: Int32 = -1

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    FlutterMethodChannel(name: "near_transfer/macos", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "startup_failed", message: nil, details: nil))
          return
        }
        self.handle(call, result: result)
      }
  }

  deinit {
    for url in scopes.values { url.stopAccessingSecurityScopedResource() }
    if lock >= 0 { close(lock) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      info(result)
    case "network":
      if let networks = lanNetworks() {
        result(networks)
      } else {
        result(error("network_permission"))
      }
    case "pick":
      pick(result)
    case "startAccess":
      startAccess(call.arguments as? String, result: result)
    case "stopAccess":
      if let token = call.arguments as? String {
        scopes.removeValue(forKey: token)?.stopAccessingSecurityScopedResource()
      }
      result(nil)
    case "downloadsPath":
      // The account home resolves to the user's Downloads outside the container.
      guard let account = getpwuid(getuid()), let home = account.pointee.pw_dir else {
        result(error("storage_failed"))
        return
      }
      result(URL(fileURLWithPath: String(cString: home), isDirectory: true)
        .appendingPathComponent("Downloads", isDirectory: true).path)
    case "open", "reveal":
      open(call.arguments as? String, reveal: call.method == "reveal", result: result)
    case "commit":
      commit(call.arguments as? [String: String], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func info(_ result: FlutterResult) {
    do {
      let files = FileManager.default
      let support = try files.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      let directory = support.appendingPathComponent("NearTransfer", isDirectory: true)
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      if lock < 0 {
        // Prevent another instance from cleaning our active .part files.
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path,
                             O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
          result(error("startup_failed"))
          return
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
          let busy = errno == EWOULDBLOCK
          close(fd)
          result(error(busy ? "already_running" : "startup_failed"))
          return
        }
        lock = fd
      }
      let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
      result(["directory": directory.path, "name": deviceName(name)])
    } catch {
      result(self.error("startup_failed"))
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard let window else {
      result(error("picker_failed"))
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.beginSheetModal(for: window) { response in
      guard response == .OK else {
        result([[String: String]]())
        return
      }
      result(panel.urls.map { url in
        var selected = ["path": url.path]
        // Persist read access for a retry from the outgoing journal after relaunch.
        let bookmark = try? url.bookmarkData(
          options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
          includingResourceValuesForKeys: nil, relativeTo: nil
        )
        selected["bookmark"] = bookmark?.base64EncodedString()
        return selected
      })
    }
  }

  private func startAccess(_ encoded: String?, result: FlutterResult) {
    guard let encoded, let data = Data(base64Encoded: encoded) else {
      result(error("source_permission"))
      return
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
        relativeTo: nil, bookmarkDataIsStale: &stale
      )
      var access = ["path": url.path]
      if url.startAccessingSecurityScopedResource() {
        let token = UUID().uuidString
        scopes[token] = url
        access["token"] = token
      }
      // The sandbox can already allow the path, for example in Downloads.
      result(access)
    } catch let failure as NSError {
      let missing = failure.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
      result(error(missing ? "source_missing" : "source_permission"))
    }
  }

  private func open(_ path: String?, reveal: Bool, result: FlutterResult) {
    guard let path, FileManager.default.fileExists(atPath: path) else {
      result(error("source_missing"))
      return
    }
    let url = URL(fileURLWithPath: path)
    if reveal {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      result(nil)
    } else if NSWorkspace.shared.open(url) {
      result(nil)
    } else {
      result(error("open_failed"))
    }
  }

  private func commit(_ paths: [String: String]?, result: FlutterResult) {
    guard let from = paths?["from"], let to = paths?["to"] else {
      result(error("storage_failed"))
      return
    }
    // The collision check and the move must be one operation.
    if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 {
      result(true)
      return
    }
    switch errno {
    case EEXIST:
      result(false)
    case ENOSPC, EDQUOT:
      result(error("no_space"))
    default:
      result(error("storage_failed"))
    }
  }

  private func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }
}

private func deviceName(_ rawName: String) -> String {
  var name = ""
  var size = 0
  for scalar in rawName.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
    let character = String(scalar)
    size += character.utf8.count
    if size > 120 { break }
    name.append(character)
  }
  return name.isEmpty ? "Mac" : name
}

private func lanNetworks() -> String? {
  var interfaces: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&interfaces) == 0 else { return nil }
  defer { freeifaddrs(interfaces) }
  let required = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
  let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
  var addresses: [String: Set<String>] = [:]
  var current = interfaces
  while let interface = current?.pointee {
    current = interface.ifa_next
    guard interface.ifa_flags & required == required,
          interface.ifa_flags & excluded == 0,
          let address = interface.ifa_addr,
          address.pointee.sa_family == sa_family_t(AF_INET),
          let mask = interface.ifa_netmask else { continue }
    var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
      $0.pointee.sin_addr
    }
    let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
      UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
    }
    let prefix = (~bits).leadingZeroBitCount
    guard ip.s_addr != 0, prefix > 0, prefix == bits.nonzeroBitCount else { continue }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let host = buffer.withUnsafeMutableBufferPointer { chars in
      inet_ntop(AF_INET, &ip, chars.baseAddress, socklen_t(chars.count))
        .map { String(cString: $0) }
    }
    if let host {
      addresses[String(cString: interface.ifa_name), default: []].insert("\(host)/\(prefix)")
    }
  }
  let names = addresses.keys.sorted()
  guard !names.isEmpty else { return "" }
  let subnets = names.flatMap { addresses[$0, default: []].sorted() }
  return "\(names.joined(separator: ",")):\(subnets.joined(separator: ","))"
}
