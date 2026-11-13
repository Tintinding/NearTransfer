import Darwin
import Flutter
import QuickLook
import UIKit
import UniformTypeIdentifiers

final class IosBridge: NSObject, FlutterPlugin, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate, QLPreviewControllerDataSource {
  private let presenter: () -> UIViewController?
  private let network = IosNetwork()
  private let files = IosFiles()
  private let fileQueue = DispatchQueue(label: "app.neartransfer.files", qos: .userInitiated)
  private var pickResult: FlutterResult?
  private var pickLimit = 0
  private var previewItem: NSURL?

  private init(presenter: @escaping () -> UIViewController?) {
    self.presenter = presenter
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = IosBridge { [weak registrar] in registrar?.viewController }
    let messenger = registrar.messenger()
    let methods = FlutterMethodChannel(name: "near_transfer/ios", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(bridge, channel: methods)
    let events = FlutterEventChannel(name: "near_transfer/ios/network", binaryMessenger: messenger)
    events.setStreamHandler(bridge.network)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = deviceName.isEmpty || deviceName.utf8.count > 120
        ? UIDevice.current.model : deviceName
      result([
        "name": name,
        "directory": files.support.path,
        "received": files.received.path,
        "scratch": files.scratch.path,
      ])
    case "refreshNetwork":
      network.refresh()
      result(nil)
    case "pick":
      guard let arguments = call.arguments as? [String: Int], let limit = arguments["limit"],
            pickResult == nil, let parent = presentationParent() else {
        result(FlutterError(code: "picker_failed", message: nil, details: nil))
        return
      }
      pickLimit = limit
      pickResult = result
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
      picker.allowsMultipleSelection = true
      picker.delegate = self
      parent.present(picker, animated: true)
      picker.presentationController?.delegate = self
    case "retain":
      let handles = (call.arguments as? [String: [String]])?["handles"] ?? []
      fileQueue.async { [files] in
        let error = files.retain(Set(handles))
        DispatchQueue.main.async { result(error) }
      }
    case "commit":
      guard let paths = call.arguments as? [String: String],
            let source = paths["from"], let destination = paths["to"] else {
        result(FlutterError(code: "storage_failed", message: nil, details: nil))
        return
      }
      fileQueue.async {
        // Keep publication atomic, including when another app uses Files in Split View.
        let status = renamex_np(source, destination, UInt32(RENAME_EXCL))
        let failure = errno
        DispatchQueue.main.async {
          if status == 0 {
            result(true)
          } else if failure == EEXIST || failure == ENOTEMPTY || failure == EISDIR {
            result(false)
          } else {
            result(FlutterError(code: failure == ENOSPC ? "no_space" : "storage_failed",
                                message: nil, details: nil))
          }
        }
      }
    case "open", "export":
      guard let path = call.arguments as? String, let parent = presentationParent() else {
        result(FlutterError(code: "presentation_failed", message: nil, details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        result(FlutterError(code: "source_missing", message: nil, details: nil))
        return
      }
      let controller: UIViewController
      if call.method == "open" {
        let item = url as NSURL
        guard QLPreviewController.canPreview(item) else {
          result(FlutterError(code: "preview_unsupported", message: nil, details: nil))
          return
        }
        previewItem = item
        let preview = QLPreviewController()
        preview.dataSource = self
        controller = preview
      } else {
        controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      }
      parent.present(controller, animated: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    cancelPick()
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    cancelPick()
  }

  private func cancelPick() {
    let result = pickResult
    pickResult = nil
    result?(["files": [], "issues": []] as [String: [[String: Any]]])
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pickResult else { return }
    pickResult = nil
    guard urls.count <= pickLimit else {
      result(FlutterError(code: "too_many_files", message: nil, details: nil))
      return
    }
    fileQueue.async { [files] in
      let selection = files.importDocuments(urls)
      DispatchQueue.main.async { result(selection) }
    }
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewItem == nil ? 0 : 1
  }

  func previewController(
    _ controller: QLPreviewController, previewItemAt index: Int
  ) -> QLPreviewItem {
    previewItem!
  }

  private func presentationParent() -> UIViewController? {
    guard let parent = presenter(), parent.viewIfLoaded?.window != nil,
          parent.presentedViewController == nil else { return nil }
    return parent
  }
}
