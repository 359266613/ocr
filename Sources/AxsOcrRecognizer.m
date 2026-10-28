#import "AxsOcrRecognizer.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <dlfcn.h>

static NSString * const AxsOcrErrorDomain = @"com.axs.ocr";

typedef CGImageRef (*AxsOcrScreenImageFunc)(void);
typedef UIImage *(*AxsOcrScreenUIImageFunc)(void);

static NSError *axs_ocr_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AxsOcrErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Private UIKit screen capture functions, resolved at runtime so a missing symbol
// fails with an error message instead of a load failure. Neither has been verified
// on a device yet; the first one found is used.
static UIImage *axs_ocr_captureScreen(void) {
    static AxsOcrScreenUIImageFunc uiImageFunction;
    static AxsOcrScreenImageFunc cgImageFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uiImageFunction = (AxsOcrScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        cgImageFunction = (AxsOcrScreenImageFunc)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    });
    if (uiImageFunction) return uiImageFunction();
    if (cgImageFunction) {
        CGImageRef image = cgImageFunction();
        return image ? [UIImage imageWithCGImage:image] : nil;
    }
    return nil;
}

static NSArray<NSString *> *axs_ocr_languages(VNRecognizeTextRequest *request) {
    NSError *error = nil;
    NSArray<NSString *> *supported = [request supportedRecognitionLanguagesAndReturnError:&error];
    if (supported.count == 0) return nil;
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    for (NSString *language in @[@"zh-Hans", @"zh-Hant", @"en-US"]) {
        if ([supported containsObject:language]) [languages addObject:language];
    }
    return languages.count > 0 ? languages : nil;
}

// attempt 0: accurate, GPU/ANE allowed, language detection on iOS 16+.
// attempt 1: accurate, CPU only, fixed languages.
// attempt 2: fast, CPU only, no language correction.
// Returns the recognized text (possibly empty), or nil with *error set when the request failed.
static NSString *axs_ocr_runRequest(CGImageRef cgImage, NSInteger attempt, NSError **error) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    request.recognitionLevel = attempt >= 2 ? VNRequestTextRecognitionLevelFast
                                            : VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = attempt < 2;
    NSArray<NSString *> *languages = axs_ocr_languages(request);
    if (languages) request.recognitionLanguages = languages;
    if (attempt == 0) {
        if (@available(iOS 16.0, *)) {
            request.automaticallyDetectsLanguage = YES;
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        request.usesCPUOnly = YES;
#pragma clang diagnostic pop
    }

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
    if (![handler performRequests:@[request] error:error]) return nil;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (line.length > 0) [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@implementation AxsOcrRecognizer

+ (void)axs_ocr_recognizeScreenWithCompletion:(AxsOcrCompletion)completion {
    UIImage *image = axs_ocr_captureScreen();
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        completion(nil, axs_ocr_error(1, @"无法截取屏幕"));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // A failure such as "error computing MM outputs" comes from the neural-network backend,
        // so retry with progressively lighter settings instead of giving up on the first error.
        NSError *error = nil;
        NSString *text = nil;
        BOOL ok = NO;
        for (NSInteger attempt = 0; attempt < 3 && !ok; attempt++) {
            error = nil;
            text = axs_ocr_runRequest(cgImage, attempt, &error);
            ok = (text != nil);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                completion(nil, error ?: axs_ocr_error(2, @"识别失败"));
            } else if (text.length == 0) {
                completion(nil, axs_ocr_error(3, @"没有识别到文字"));
            } else {
                completion(text, nil);
            }
        });
    });
}

@end
