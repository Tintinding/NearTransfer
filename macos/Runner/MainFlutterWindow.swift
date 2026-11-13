import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var bridge: MacOSBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = NSSize(width: 400, height: 440)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    bridge = MacOSBridge(window: self, messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
