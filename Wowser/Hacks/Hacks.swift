//
//  Hacks.swift
//  Wowser
//
//  Created by Nate Parrott on 4/5/25.
//
import Core

struct MacHacks: Hacks {
    func fixPreferences(_ prefs: WKPreferences) {
        // https://stackoverflow.com/questions/78758812/wkwebview-oauth-popup-misses-window-opener-in-ios-17-5
        setSwapProcessNavFalse(prefs)
    }
}
