import AppKit
import SwiftUI
import Core

class SwipeGestureContainer: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect, .direct]
//        wantsRestingTouches = true
        wantsLayer = true
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    
    // MARK: - API
    var swipeGestureOffset: Int? {
        didSet {
            if swipeGestureOffset != oldValue {
                onSwipeGestureOffsetChanged?(swipeGestureOffset)
                
                if swipeGestureOffset != nil {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                }
            }
        }
    }
    var onSwipeGestureOffsetChanged: ((Int?) -> Void)?
    
    // MARK: - Gestures
    private enum GestureState: Equatable {
        case none
        case gesturePossible(initialCentroid: CGPoint) // once we move > 0.1, transition to committed if moving down, cancelled otherwise. set initialCentroid to the new centroid when transitioning
        case gestureCancelled
        case gestureCommitted(initialCentroid: CGPoint, curCentroid: CGPoint) // Set swipeGestureOffset = displacement.y / 0.2
    }
    
    private var state = GestureState.none {
        didSet {
            if state != oldValue {
//                print("Gesture state changed: \(state)")
                switch state {
                case .none, .gesturePossible, .gestureCancelled:
                    swipeGestureOffset = nil
                case .gestureCommitted(let initialCentroid, let curCentroid):
                    let displacement = -(curCentroid.y - initialCentroid.y)
                    swipeGestureOffset = max(0, Int(floor(displacement / 0.15 + 1)))
                }
            }
        }
    }
    
    private var touchCount = 0 {
        didSet {
//            print("Touch count: \(touchCount)")
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
    
    override func touchesBegan(with event: NSEvent) {
        touchCount = event.allTouches().count // += touches.count
        if touchCount == 3, window?.isKeyWindow ?? false {
            state = .gesturePossible(initialCentroid: event.touchCentroid)
        } else {
            state = .none
        }
    }
    
    override func touchesMoved(with event: NSEvent) {
        let centroid = event.touchCentroid
        
        switch state {
        case .gesturePossible(let initialCentroid):
            let displacement = -(centroid.y - initialCentroid.y)
            if abs(displacement) > 0.1 {
                if displacement > 0 {
                    state = .gestureCommitted(initialCentroid: centroid, curCentroid: centroid)
                } else {
                    state = .gestureCancelled
                }
            }
        case .gestureCommitted(let initialCentroid, _):
            state = .gestureCommitted(initialCentroid: initialCentroid, curCentroid: centroid)
        case .none, .gestureCancelled:
            break
        }
    }
    
    override func touchesEnded(with event: NSEvent) {
//        let touches = event.touches(matching: .ended, in: self)
//        touchCount -= touches.count
        state = .none
        touchCount = 0
    }
    
    override func touchesCancelled(with event: NSEvent) {
//        let touches = event.touches(matching: .cancelled, in: self)
//        touchCount -= touches.count
        state = .none
        touchCount = 0
    }
    
    // MARK: - Window Notifications
    
    @objc private func windowDidResignKey(_ notification: Notification) {
        if let notificationWindow = notification.object as? NSWindow, 
           let myWindow = window, 
           notificationWindow == myWindow {
            state = .none
            touchCount = 0
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension NSEvent {
    var touchCentroid: CGPoint {
        let touches = allTouches()
        guard !touches.isEmpty else { return .zero }
        
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        
        for touch in touches {
            sumX += touch.normalizedPosition.x
            sumY += touch.normalizedPosition.y
        }
        
        return CGPoint(
            x: sumX / CGFloat(touches.count),
            y: sumY / CGFloat(touches.count)
        )
    }
}
