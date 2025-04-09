import Foundation
import Combine
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import QuartzCore
#endif

class FrameThrottledValue<V> {
//    @Published private(set) var value: V
    var publisher: AnyPublisher<V, Never> {
        subject.eraseToAnyPublisher()
    }
    private var pendingVal: V?
    private var displayLink: DisplayLink?
    private var subject: CurrentValueSubject<V, Never>
    
    init(value: V) {
        subject = .init(value)
//        self.value = value
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    func update(value: V) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.update(value: value)
            }
            return
        }
        pendingVal = value
        
        if displayLink == nil {
            displayLink = DisplayLink { [weak self] in
                assertOnMainThread()
                guard let self = self, let pendingVal = self.pendingVal else { return }
                subject.value = value
//                self.value = pendingVal
                self.pendingVal = nil
                self.displayLink?.invalidate()
                self.displayLink = nil
            }
        }
    }
}

// MARK: - DisplayLink

private class DisplayLink {
    private var callback: () -> Void
    private var isValid = true
    
    #if os(iOS) || os(tvOS)
    private var displayLink: CADisplayLink?
    #elseif os(macOS)
    private var displayLink: CVDisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    #endif
    
    init(callback: @escaping () -> Void) {
        self.callback = callback
        setupDisplayLink()
    }
    
    func invalidate() {
        guard isValid else { return }
        isValid = false
        
        #if os(iOS) || os(tvOS)
        displayLink?.invalidate()
        displayLink = nil
        #elseif os(macOS)
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        #endif
    }
    
    private func setupDisplayLink() {
        #if os(iOS) || os(tvOS)
        let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLinkCallback))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        #elseif os(macOS)
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        
        if let displayLink = displayLink {
            let opaqueself = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, opaquePointer -> CVReturn in
                let obj = Unmanaged<DisplayLink>.fromOpaque(opaquePointer!).takeUnretainedValue()
                obj.handleMacDisplayLinkCallback()
                return kCVReturnSuccess
            }, opaqueself)
            
            CVDisplayLinkStart(displayLink)
            self.displayLink = displayLink
        }
        #endif
    }
    
    #if os(iOS) || os(tvOS)
    @objc private func handleDisplayLinkCallback() {
        guard isValid else { return }
        callback()
    }
    #elseif os(macOS)
    private func handleMacDisplayLinkCallback() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isValid else { return }
            self.callback()
        }
    }
    #endif
}
