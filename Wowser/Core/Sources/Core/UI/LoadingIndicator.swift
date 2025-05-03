import SwiftUI

struct LoadingIndicator: View {
    var progress: Double?
    
    @State private var showComplete = false
    @State private var loadingIndicatorId = 0
    
    var body: some View {
        ZStack {
            if let displayProgress {
                LoadingBar(progress: displayProgress)
                    .transition(.asymmetric(insertion: .offset(x: -20), removal: .offset(y: -10)))
            }
        }
//        .frame(height: 10)
//        .clipped()
        .animation(.niceDefault(duration: 0.1), value: displayProgress)
        .onChange(of: progress != nil) { isLoading in
            if isLoading {
                loadingIndicatorId += 1
                showComplete = false
            }
            if !isLoading {
                let id = self.loadingIndicatorId
                showComplete = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.loadingIndicatorId == id {
                        self.showComplete = false
                    }
                }
            }
        }
    }
    
    private var displayProgress: Double? {
        if let progress {
            return progress
        }
        if showComplete {
            return 1
        }
        return nil
    }
}

private struct LoadingBar: View {
    var progress: Double
    
    @StateObject private var driver = LoadingBarDriver()
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Capsule()
                    .fill(Color.accentColor)
                
                Capsule().fill(LinearGradient(colors: [Color.white, Color.black], startPoint: .top, endPoint: .bottom))
                    .blendMode(.overlay)
                    .opacity(0.2)
                
                Capsule().strokeBorder(Color.white, lineWidth: 0.5)
                    .opacity(0.1)
            }
//            .shadow(color: Color(hex: 0x404080, alpha: 0.25), radius: 6, x: 0, y: 0)
            .frame(width: geo.size.width * driver.displayProgress, height: 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(duration: driver.displayProgress == 1 ? 0.15 : 0.3, bounce: 0, blendDuration: 0.2), value: driver.displayProgress)
        }
        .onAppearOrChange(of: progress, perform: { driver.progress = $0 })
    }
}

// Implement a UI where we're always pushing the bar forward a little bit, even if actually stuck
// Also implement a big initial fake jump
private class LoadingBarDriver: ObservableObject {
    var progress: Double = 0 {
        didSet {
            update()
        }
    }
    @Published private(set) var displayProgress: Double = 0
    private var ticks: Int = 0 {
        didSet {
            update()
        }
    }
    
    private var timer: Timer?
    
    private func update() {
        let remainingProgress = 1 - progress
        let fudgedRemainingProgress = remainingProgress * pow(0.95, Double(ticks))
        let firstTickBoost: Double = ticks > 0 ? 0.3 : 0
        self.displayProgress = (1 - fudgedRemainingProgress) * (1 - 0.3) + firstTickBoost
        
        if ticks > 20 {
            timer?.invalidate()
        }
    }
    
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true, block: { [weak self] _ in
            self?.ticks += 1
        })
    }
    
    deinit {
        timer?.invalidate()
    }
}
