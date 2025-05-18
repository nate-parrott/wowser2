//
//  Hacks.m
//  Wowser
//
//  Created by Nate Parrott on 4/5/25.
//

#import "Hacks.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdbool.h>

/**
 * Sets process swap on navigation to false for the given WKPreferences object.
 *
 * @param preferences The WKPreferences object to modify
 * @return 0 on success, -1 on error
 */
int setSwapProcessNavFalse(WKPreferences *preferences) {
    if (preferences == NULL) {
        fprintf(stderr, "Error: NULL preferences object provided\n");
        return -1;
    }
    
    // Load WebKit framework
    void* handle = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY);
    if (!handle) {
        fprintf(stderr, "Error loading WebKit framework: %s\n", dlerror());
        return -1;
    }
    
    // Clear any existing error
    dlerror();
    
    // Look up the WKPreferencesSetProcessSwapOnNavigationEnabled function
    typedef void (*HelpfulFunc)(WKPreferences *, bool);
    
    NSString *str1 = @"BKPreferences";
    NSString *str2 = @"SetProcessSwapOnNavigationEnabled";
    
    NSString *symbol = [[str1 stringByReplacingOccurrencesOfString:@"BK" withString:@"WK"] stringByAppendingString:str2];
//    const char *symbolC = [symbol cStringUsingEncoding:NSUTF8StringEncoding];
    
    HelpfulFunc setSwapEnabled =
        (HelpfulFunc)dlsym(handle,
                           [symbol UTF8String]);
    
    // Check for errors
    char* error = dlerror();
    if (error) {
        fprintf(stderr, "Error finding symbol: %s\n", error);
        dlclose(handle);
        return -1;
    }
    
    // Call the function (disabling process swap on navigation)
    setSwapEnabled(preferences, false);
    
    // Close the handle when done
    dlclose(handle);
    
    return 0;
}
