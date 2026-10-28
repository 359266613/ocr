#pragma once

#import <Foundation/Foundation.h>

@interface AxsOcrPanel : NSObject
// Shows a card above all apps. Main thread only. A new call replaces the current card.
+ (void)axs_ocr_showText:(NSString *)text copyable:(BOOL)copyable;
// Hides the current card, if any. Call before capturing the screen.
+ (void)axs_ocr_dismiss;
@end
