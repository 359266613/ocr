#import "AxsOcrConfig.h"
#import "AxsOcrPreferences.h"

@interface AxsOcrConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_ocr_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsOcrConfig *config = (__bridge AxsOcrConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_ocr_reload];
    });
}

@implementation AxsOcrConfig

+ (instancetype)axs_ocr_shared {
    static AxsOcrConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.ocr.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_ocr_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_ocr_preferencesDidChange,
            (__bridge CFStringRef)AxsOcrPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_ocr_reload]; });
    }
    return self;
}

- (void)axs_ocr_reload {
    self.snapshot = axs_ocr_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsOcrPreferencesChanged object:self];
    });
}

- (id)axs_ocr_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_ocr_isEnabled {
    id value = [self axs_ocr_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
