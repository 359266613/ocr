#import <UIKit/UIKit.h>
#import "AxsOcrConfig.h"
#import "AxsOcrPrivate.h"
#import "AxsOcrRecognizer.h"
#import "AxsOcrPanel.h"
#import "AxsOcrLog.h"

// Deep link: prefs:root=axsocr_recognize (app-prefs: works too)
// GesturePro (or any SpringBoard code) triggers it with a URL action.
// The URL is consumed here, so Settings never opens.

static NSString * const AxsOcrRootValue = @"axsocr_recognize";

// Extracts the value of "root=" from a prefs: style URL, or nil when absent.
static NSString *axs_ocr_rootValue(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"prefs"] && ![scheme isEqualToString:@"app-prefs"]) return nil;
    NSString *spec = url.resourceSpecifier.lowercaseString;
    NSRange range = [spec rangeOfString:@"root="];
    if (range.location == NSNotFound) return nil;
    NSString *value = [spec substringFromIndex:NSMaxRange(range)];
    NSRange end = [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"&#/"]];
    return end.location == NSNotFound ? value : [value substringToIndex:end.location];
}

static void axs_ocr_recognizeNow(void) {
    // Remove the previous result card so it is not captured and recognized again.
    [AxsOcrPanel axs_ocr_dismiss];
    // Let the gesture animation settle so the screenshot shows the page, not the gesture UI.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [AxsOcrRecognizer axs_ocr_recognizeScreenWithCompletion:^(NSString *text, NSError *error) {
            if (text) [AxsOcrPanel axs_ocr_showText:text copyable:YES];
            // Errors are copyable too so the full diagnostic text can be pasted into a bug report.
            else [AxsOcrPanel axs_ocr_showText:error.localizedDescription ?: @"识别失败" copyable:YES];
        }];
    });
}

// Returns YES when the URL belongs to this plugin and must not be forwarded to the system.
static BOOL axs_ocr_handleURL(NSURL *url) {
    if (![axs_ocr_rootValue(url) isEqualToString:AxsOcrRootValue]) return NO;
    // Disabled: still swallow the link so a stray trigger does not open Settings.
    BOOL enabled = [[AxsOcrConfig axs_ocr_shared] axs_ocr_isEnabled];
    axs_ocr_log(@"trigger: url=%@ enabled=%d", url.absoluteString, enabled);
    if (!enabled) return YES;

    // Ignore repeated triggers fired in quick succession.
    static CFAbsoluteTime lastTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastTime < 0.6) return YES;
    lastTime = now;

    dispatch_async(dispatch_get_main_queue(), ^{ axs_ocr_recognizeNow(); });
    return YES;
}

// GesturePro's URL action calls this private SpringBoard method directly.
%hook SpringBoard

- (void)applicationOpenURL:(id)url {
    if ([url isKindOfClass:[NSURL class]] && axs_ocr_handleURL(url)) return;
    %orig;
}

%end

// Other in-process callers that go through the public API.
%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    if (axs_ocr_handleURL(url)) {
        if (completion) completion(YES);
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // Readers load a snapshot; they never write default preferences.
        [AxsOcrConfig axs_ocr_shared];
    }
}
