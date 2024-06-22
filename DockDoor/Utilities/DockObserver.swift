//  DockObserver.swift
//  DockDoor
//
//  Created by Ethan Bills on 6/3/24.
//

import Cocoa
import ApplicationServices

class DockObserver {
    static let shared = DockObserver()
    
    private var lastAppName: String?
    private var lastMouseLocation: CGPoint?
    private let mouseUpdateThreshold: CGFloat = 5.0
    private var eventTap: CFMachPort?
    
    private var hoverProcessingTask: DispatchWorkItem?
    private var isProcessing: Bool = false
        
    private var dockAppProcessIdentifier: pid_t? = nil
    
    private init() {
        setupEventTap()
        setupDockApp()
    }
    
    deinit {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0), CFRunLoopMode.commonModes)
        }
    }
    
    private func setupDockApp() {
        if let dockAppPid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier {
            self.dockAppProcessIdentifier = dockAppPid
        }
    }
    
    private func setupEventTap() {
        guard AXIsProcessTrusted() else {
            print("Debug: Accessibility permission not granted")
            MessageUtil.showMessage(title: "Permission error",
                                    message: "You need to give DockDoor access to the accessibility API in order for it to function.",
                                    completion: { _ in SystemPreferencesHelper.openAccessibilityPreferences() })
            return
        }
        
        func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
            let observer = Unmanaged<DockObserver>.fromOpaque(refcon!).takeUnretainedValue()
            
            if type == .mouseMoved {
                let mouseLocation = event.location
                observer.handleMouseEvent(mouseLocation: mouseLocation)
            }
            
            return Unmanaged.passRetained(event)
        }
        
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            print("Failed to create CGEvent tap.")
        }
    }
    
    @objc private func handleMouseEvent(mouseLocation: CGPoint) {
        // Cancel any ongoing processing
        hoverProcessingTask?.cancel()
        
        // Create a new task for hover processing
        hoverProcessingTask = DispatchWorkItem { [weak self] in
            self?.processMouseEvent(mouseLocation: mouseLocation)
        }
        
        // Execute the new task
        DispatchQueue.main.async(execute: hoverProcessingTask!)
    }
    
    private func processMouseEvent(mouseLocation: CGPoint) {
        guard !isProcessing else { return }
        isProcessing = true
        
        guard let lastMouseLocation = lastMouseLocation else {
            self.lastMouseLocation = mouseLocation
            isProcessing = false
            return
        }
        
        // Ignore minor movements
        if abs(mouseLocation.x - lastMouseLocation.x) < mouseUpdateThreshold &&
            abs(mouseLocation.y - lastMouseLocation.y) < mouseUpdateThreshold {
            isProcessing = false
            return
        }
        self.lastMouseLocation = mouseLocation
        
        // Capture the current mouseLocation
        let currentMouseLocation = mouseLocation
        
        if let dockIconAppName = getDockIconAtLocation(currentMouseLocation) {
            if dockIconAppName != lastAppName {
                lastAppName = dockIconAppName
                
                Task {
                    let activeWindows = await WindowUtil.activeWindows(for: dockIconAppName)
                    DispatchQueue.main.async {
                        if activeWindows.isEmpty {
                            self.hideHoverWindow()
                        } else {
                            // Execute UI updates on the main thread
                            let mouseScreen = DockObserver.screenContainingPoint(currentMouseLocation) ?? NSScreen.main!
                            let convertedMouseLocation = DockObserver.nsPointFromCGPoint(currentMouseLocation, forScreen: mouseScreen)
                            // Show HoverWindow (using shared instance)
                            HoverWindow.shared.showWindow(
                                appName: dockIconAppName,
                                windows: activeWindows,
                                mouseLocation: convertedMouseLocation,
                                mouseScreen: mouseScreen,
                                onWindowTap: { self.hideHoverWindow() }
                            )
                        }
                        self.isProcessing = false
                    }
                }
            } else {
                isProcessing = false
            }
        } else {
            DispatchQueue.main.async {
                // Perform conversion on main thread
                let mouseScreen = DockObserver.screenContainingPoint(currentMouseLocation) ?? NSScreen.main!
                let convertedMouseLocation = DockObserver.nsPointFromCGPoint(currentMouseLocation, forScreen: mouseScreen)
                if !HoverWindow.shared.frame.contains(convertedMouseLocation) {
                    self.lastAppName = nil
                    self.hideHoverWindow()
                }
                self.isProcessing = false
            }
        }
    }
    
    private func hideHoverWindow() {
        HoverWindow.shared.hideWindow() // Hide the shared HoverWindow
    }
    
    func getDockIconAtLocation(_ mouseLocation: CGPoint) -> String? {
        guard let dockAppProcessIdentifier else { return nil }
        
        let axDockApp = AXUIElementCreateApplication(dockAppProcessIdentifier)
        
        var dockItems: CFTypeRef?
        let dockItemsResult = AXUIElementCopyAttributeValue(axDockApp, kAXChildrenAttribute as CFString, &dockItems)
        
        guard dockItemsResult == .success, let items = dockItems as? [AXUIElement] else {
            print("Failed to get dock items")
            return nil
        }
        
        let axList = items.first { element in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            return (role as? String) == kAXListRole
        }
        
        guard axList != nil else {
            print("Failed to find the Dock list")
            return nil
        }
        
        var axChildren: CFTypeRef?
        AXUIElementCopyAttributeValue(axList!, kAXChildrenAttribute as CFString, &axChildren)
        
        guard let children = axChildren as? [AXUIElement] else {
            print("Failed to get children")
            return nil
        }
        
        for element in children {
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
            let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
            
            if positionResult == .success, sizeResult == .success {
                let position = positionValue as! AXValue
                let size = sizeValue as! AXValue
                var positionPoint = CGPoint.zero
                AXValueGetValue(position, .cgPoint, &positionPoint)
                var sizeCGSize = CGSize.zero
                AXValueGetValue(size, .cgSize, &sizeCGSize)
                
                let iconRect = CGRect(origin: positionPoint, size: sizeCGSize)
                if iconRect.contains(mouseLocation) {
                    var value: CFTypeRef?
                    let titleResult = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
                    if titleResult == .success, let title = value as? String {
                        var isRunningValue: CFTypeRef?
                        AXUIElementCopyAttributeValue(element, kAXIsApplicationRunningAttribute as CFString, &isRunningValue)
                        if (isRunningValue as? Bool) == true {
                            return title
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    static func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else { return nil }
        
        for screen in screens {
            let (offsetLeft, offsetTop) = computeOffsets(for: screen, primaryScreen: primaryScreen)
            
            if point.x >= offsetLeft && point.x <= offsetLeft + screen.frame.size.width &&
                point.y >= offsetTop && point.y <= offsetTop + screen.frame.size.height {
                return screen
            }
        }
        
        return primaryScreen
    }
    
    static func nsPointFromCGPoint(_ point: CGPoint, forScreen: NSScreen?) -> NSPoint {
        guard let screen = forScreen,
              let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: point.x, y: point.y)
        }
        
        let (_, offsetTop) = computeOffsets(for: screen, primaryScreen: primaryScreen)
        
        let y: CGFloat
        if screen == primaryScreen {
            y = screen.frame.size.height - point.y
        } else {
            let screenbottomoffset = primaryScreen.frame.size.height - (screen.frame.size.height + offsetTop)
            y = screen.frame.size.height + screenbottomoffset - (point.y - offsetTop)
        }
        
        return NSPoint(x: point.x, y: y)
    }
    
    static func cgPointFromNSPoint(_ point: CGPoint, forScreen: NSScreen?) -> CGPoint {
        guard let screen = forScreen,
              let primaryScreen = NSScreen.screens.first else {
            return CGPoint(x: point.x, y: point.y)
        }
        
        let (_, offsetTop) = computeOffsets(for: screen, primaryScreen: primaryScreen)
        let menuScreenHeight = screen.frame.maxY
        
        return CGPoint(x: point.x, y: menuScreenHeight - point.y + offsetTop)
    }
    
    private static func computeOffsets(for screen: NSScreen, primaryScreen: NSScreen) -> (CGFloat, CGFloat) {
        var offsetLeft = screen.frame.origin.x
        var offsetTop = primaryScreen.frame.size.height - (screen.frame.origin.y + screen.frame.size.height)
        
        if screen == primaryScreen {
            offsetTop = 0
            offsetLeft = 0
        }
        
        return (offsetLeft, offsetTop)
    }
}
