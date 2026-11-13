import Flutter
import Foundation

struct IosFiles {
  private let manager = FileManager.default
  private let sources: URL
  let support: URL
  let received: URL
  let scratch: URL

  init() {
    support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NearTransfer", isDirectory: true)
    sources = support.appendingPathComponent("Outgoing", isDirectory: true)
    received = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Received", isDirectory: true)
    scratch = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NearTransfer-Incoming", isDirectory: true)
  }

  func importDocuments(_ urls: [URL]) -> [String: [[String: Any]]] {
    var files: [[String: Any]] = []
    var issues: [[String: Any]] = []
    for source in urls {
      let name = source.lastPathComponent
      let handle = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let destination = sources.appendingPathComponent(handle, isDirectory: false)
      do {
        let size = try importDocument(source, to: destination)
        files.append(["handle": handle, "name": name, "size": size])
      } catch {
        try? manager.removeItem(at: destination)
        issues.append(["name": name, "code": Self.importError(error)])
      }
    }
    return ["files": files, "issues": issues]
  }

  private func importDocument(_ source: URL, to destination: URL) throws -> Int64 {
    var folder = sources
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)

    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var copy: Result<Int64, Error>?
    // File providers can materialize a cloud document during this coordinated read.
    NSFileCoordinator().coordinate(readingItemAt: source, options: [],
                                   error: &coordinationError) { url in
      copy = Result {
        let kind = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                     .isSymbolicLinkKey])
        if kind.isDirectory == true { throw ImportError.folder }
        guard kind.isRegularFile == true, kind.isSymbolicLink != true else {
          throw ImportError.unreadable
        }
        try manager.copyItem(at: url, to: destination)
        guard let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
          throw ImportError.unreadable
        }
        return Int64(size)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let copy else { throw ImportError.unreadable }
    return try copy.get()
  }

  func retain(_ handles: Set<String>) -> FlutterError? {
    guard manager.fileExists(atPath: sources.path) else { return nil }
    do {
      for url in try manager.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
      where !handles.contains(url.lastPathComponent) {
        try manager.removeItem(at: url)
      }
      return nil
    } catch {
      return FlutterError(code: "storage_failed", message: nil, details: nil)
    }
  }

  private enum ImportError: Error {
    case folder, unreadable
  }

  private static func importError(_ error: Error) -> String {
    if let reason = error as? ImportError, case .folder = reason {
      return "folder_unsupported"
    }
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain {
      switch CocoaError.Code(rawValue: error.code) {
      case .fileReadNoPermission: return "source_permission"
      case .fileNoSuchFile, .fileReadNoSuchFile: return "source_missing"
      case .fileWriteOutOfSpace: return "no_space"
      default: break
      }
    }
    return "source_unreadable"
  }
}
