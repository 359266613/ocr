#pragma once

#import <Foundation/Foundation.h>

typedef void (^AxsOcrCompletion)(NSString *text, NSError *error);

@interface AxsOcrRecognizer : NSObject
// Captures the whole screen on the main thread, then recognizes it off the main thread.
// The completion block always runs on the main thread.
+ (void)axs_ocr_recognizeScreenWithCompletion:(AxsOcrCompletion)completion;
@end
