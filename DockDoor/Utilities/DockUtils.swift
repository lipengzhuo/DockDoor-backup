//
//  DockUtils.swift
//  DockDoor
//
//

import Cocoa

enum DockPosition {
    case bottom
    case left
    case right
    case unknown
}

class DockUtils {
    static let shared = DockUtils()
    
    private let dockDefaults: UserDefaults? // Store a single instance
    
    private init() {
        dockDefaults = UserDefaults(suiteName: "com.apple.dock")
    }
    
    func isDockHidingEnabled() -> Bool {
        if let dockAutohide = dockDefaults?.bool(forKey: "autohide") {
            return dockAutohide
        }
        
        return false
    }
    
    func countIcons() -> (Int, Int) {
        let persistentAppsCount = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        let recentAppsCount = dockDefaults?.array(forKey: "recent-apps")?.count ?? 0
        return (persistentAppsCount + recentAppsCount, (persistentAppsCount > 0 && recentAppsCount > 0) ? 1 : 0)
    }
    
    func calculateDockWidth() -> CGFloat {
        let countIcons = countIcons()
        let iconCount = countIcons.0
        let numberOfDividers = countIcons.1
        let tileSize = tileSize()
        
        let baseWidth = tileSize * CGFloat(iconCount)
        let dividerWidth: CGFloat = 10.0
        let totalDividerWidth = CGFloat(numberOfDividers) * dividerWidth
        
        if self.isMagnificationEnabled(),
           let largeSize = dockDefaults?.object(forKey: "largesize") as? CGFloat {
            let extraWidth = (largeSize - tileSize) * CGFloat(iconCount) * 0.5
            return baseWidth + extraWidth + totalDividerWidth
        }
        
        return baseWidth + totalDividerWidth
    }
    
    private func tileSize() -> CGFloat {
        return dockDefaults?.double(forKey: "tilesize") ?? 0
    }
    
    private func largeSize() -> CGFloat {
        return dockDefaults?.double(forKey: "largesize") ?? 0
    }
    
    func isMagnificationEnabled() -> Bool {
        return dockDefaults?.bool(forKey: "magnification") ?? false
    }
    
    func calculateDockHeight(_ forScreen: NSScreen?) -> CGFloat {
        if self.isDockHidingEnabled() {
            return abs(largeSize() - tileSize())
        } else {
            if let currentScreen = forScreen {
                switch self.getDockPosition() {
                case .right, .left:
                    let size = abs(currentScreen.frame.width - currentScreen.visibleFrame.width)
                    return size
                case .bottom:
                    let size = currentScreen.frame.height - currentScreen.visibleFrame.height - getStatusBarHeight(screen: currentScreen) - 1
                    return size
                default:
                    break
                }
            }
            return 0.0
        }
    }
    
    func getStatusBarHeight(screen: NSScreen?) -> CGFloat {
        var statusBarHeight = 0.0
        if let screen = screen {
            statusBarHeight = screen.frame.height - screen.visibleFrame.height - (screen.visibleFrame.origin.y - screen.frame.origin.y) - 1
        }
        return statusBarHeight
    }
    
    func getDockPosition() -> DockPosition {
        guard let orientation = dockDefaults?.string(forKey: "orientation")?.lowercased() else {
            if NSScreen.main!.visibleFrame.origin.y == 0 && !self.isDockHidingEnabled() {
                if NSScreen.main!.visibleFrame.origin.x == 0 {
                    return .right
                } else {
                    return .left
                }
            } else {
                return .bottom
            }
        }
        
        switch orientation {
        case "left":   return .left
        case "bottom": return .bottom
        case "right":  return .right
        default:       return .unknown
        }
    }
    
    func getAppIcon(byName appName: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        
        for app in apps {
            if let appLocalizedName = app.localizedName, appLocalizedName.caseInsensitiveCompare(appName) == .orderedSame {
                return workspace.icon(forFile: app.bundleURL!.path)
            }
        }
        
        return nil
    }
    
    func dockScreen() -> NSScreen {
        // Get the Dock application
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            print("Dock application not found.")
            return NSScreen.main!
        }
        
        // Use Accessibility API to get the Dock element
        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        var children: CFTypeRef?
        // Get children elements of the Dock
        AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &children)
        
        guard let childElements = children as? [AXUIElement] else {
            print("Failed to get children of dock element.")
            return NSScreen.main!
        }
        
        // Find Dock icons and their positions and print titles
        let dockIcons = childElements.compactMap { element -> CGPoint? in
            var position: CFTypeRef?
            var title: CFTypeRef?
            let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
            let titleResult = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            
            if titleResult == .success, let titleValue = title as? String {
                print("Dock Icon Title: \(titleValue)")
            }
            
            if posResult == .success, let posValue = position {
                var point = CGPoint.zero
                if AXValueGetValue(posValue as! AXValue, .cgPoint, &point) {
                    return point
                }
            }
            return nil
        }
        
        // Determine which screen contains the dock and print the monitor name
        for point in dockIcons {
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                print("Dock is on monitor: \(screen.localizedName)")
                return screen
            }
        }
        
        // Default to main screen if not found
        return NSScreen.main!
    }
}
