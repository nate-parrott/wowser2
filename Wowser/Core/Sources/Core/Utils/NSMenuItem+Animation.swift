#if os(macOS)
import AppKit

extension NSMenuItem {
    private static let originalTitleKey = AssociatedObjectKey<String>()
    private static let animationTaskKey = AssociatedObjectKey<Task<Void, Never>>()
    
    public func animateTextMessage(text: String, timeout: TimeInterval = 3, skipAnimation: Bool = false) {
        // Cancel any existing animation
        if let existingTask = self.getAssociatedObject(forKey: NSMenuItem.animationTaskKey) {
            existingTask.cancel()
        }
        
        // Store the original title if not already saved
        let originalTitle = self.getAssociatedObject(forKey: NSMenuItem.originalTitleKey) ?? self.title
        self.setAssociatedObject(originalTitle, forKey: NSMenuItem.originalTitleKey)
        
        // Get menu and index for replacement
        guard let menu = self.menu,
              let index = menu.items.firstIndex(of: self) else {
            return
        }
        
        // Start new animation task
        let animationTask = Task { @MainActor in
            let targetTitle = text
            
            // Ensure we have something to animate
            guard !originalTitle.isEmpty else { return }
            
            // Hide the original menu item
            self.isHidden = true
            
            if skipAnimation {
                // Skip animation and just display the target text
                let tempItem = NSMenuItem(title: targetTitle, action: self.action, keyEquivalent: self.keyEquivalent)
                if self.hasSubmenu {
                    tempItem.submenu = NSMenu(title: "Submenu")
                }
                tempItem.target = self.target
                tempItem.tag = self.tag
                tempItem.isEnabled = self.isEnabled
                tempItem.image = self.image
                menu.insertItem(tempItem, at: index)
                
                // Wait for the timeout
                if !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                }
                
                // Cleanup
                if !Task.isCancelled && tempItem.menu != nil {
                    menu.removeItem(tempItem)
                    self.isHidden = false
                }
            } else {
                // Get max length for animation
                let maxLength = max(originalTitle.count, targetTitle.count)
                
                // Track our temporary item so we can remove it later
                var tempItem: NSMenuItem? = nil
                
                // Animation: Run t from 0 to maxLength
                for t in 0...maxLength {
                    if Task.isCancelled { break }
                    
                    // Remove previous temp item if it exists
                    if let oldItem = tempItem, oldItem.menu != nil {
                        menu.removeItem(oldItem)
                    }
                    
                    // Create the mixed string: alert[..t] + orig[t..]
                    var result = ""
                    
                    // Add characters from target (up to t)
                    if t > 0 {
                        let targetEndIndex = min(t, targetTitle.count)
                        let targetPrefix = targetTitle.prefix(targetEndIndex)
                        result += targetPrefix
                    }
                    
                    // Add the "boundary" character as uppercase if available
                    if t < originalTitle.count {
                        let index = originalTitle.index(originalTitle.startIndex, offsetBy: t)
                        let boundaryChar = String(originalTitle[index]).uppercased()
                        result += boundaryChar
                        
                        // Add remaining characters from original (t+1 onwards)
                        if t+1 < originalTitle.count {
                            let startSuffix = originalTitle.suffix(originalTitle.count - (t+1))
                            result += startSuffix
                        }
                    }
                    
                    // Create a new temporary menu item with the updated title
                    tempItem = NSMenuItem(title: result, action: self.action, keyEquivalent: self.keyEquivalent)
                    if self.hasSubmenu {
                        tempItem?.submenu = NSMenu(title: "Submenu")
                    }
                    tempItem?.target = self.target
                    tempItem?.tag = self.tag
                    tempItem?.isEnabled = self.isEnabled
                    tempItem?.image = self.image
                    menu.insertItem(tempItem!, at: index)
                    
                    // Wait for next frame
                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                }
                
                // Wait for the timeout
                if !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                }
                
                // Cleanup - remove temp item and unhide original
                if !Task.isCancelled {
                    if let finalItem = tempItem, finalItem.menu != nil {
                        menu.removeItem(finalItem)
                    }
                    self.isHidden = false
                }
            }
            
            // Clean up
            self.setAssociatedObject(nil as Task<Void, Never>?, forKey: NSMenuItem.animationTaskKey)
        }
        
        // Store the animation task
        self.setAssociatedObject(animationTask, forKey: NSMenuItem.animationTaskKey)
    }
}

#endif
