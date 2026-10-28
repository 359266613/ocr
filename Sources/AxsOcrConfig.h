#pragma once

#import <Foundation/Foundation.h>

@interface AxsOcrConfig : NSObject
+ (instancetype)axs_ocr_shared;
- (BOOL)axs_ocr_isEnabled;
- (id)axs_ocr_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_ocr_reload;
@end
