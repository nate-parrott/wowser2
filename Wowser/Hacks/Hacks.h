//
//  Hacks.h
//  Wowser
//
//  Created by Nate Parrott on 4/5/25.
//

#import <Foundation/Foundation.h>
@import WebKit;

//// From https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/C/WKPreferences.cpp#L1613
//void WKPreferencesSetProcessSwapOnNavigationEnabled(WKPreferences *preferencesRef, bool flag);
//
int setSwapProcessNavFalse(WKPreferences *preferences);


