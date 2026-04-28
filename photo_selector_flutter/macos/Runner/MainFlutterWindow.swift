import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Apply exact initial sizing for 270px sidebar + 3:2 aspect ratio preview area
    let defaultHeight: CGFloat = 800.0
    let previewWidth = defaultHeight * 1.5 
    let defaultWidth = 270.0 + previewWidth
    
    // Position it roughly in center
    let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let xOffset = (screenRect.width - defaultWidth) / 2.0
    let yOffset = (screenRect.height - defaultHeight) / 2.0
    
    let newFrame = NSRect(x: xOffset, y: yOffset, width: defaultWidth, height: defaultHeight)
    self.setFrame(newFrame, display: true)
    
    if #available(macOS 11.0, *) {
      self.titlebarSeparatorStyle = .none
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
