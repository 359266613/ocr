#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <unistd.h>

// Usage: AxsOcrHelper [--safe|--any] <image path>
// Prints the recognized text on stdout, one line per text block.
// On failure (exit 4) stdout carries the Vision error messages instead of text.
// Exit codes: 0 ok, 2 bad arguments, 3 image load failed, 4 recognition failed.
//
// Runs as its own process so a Vision/Neural Engine failure cannot take SpringBoard down.
// --safe tries CPU-only configurations; --any also tries the default compute devices,
// which may crash this process but never the caller.

typedef struct {
    BOOL fast;
    BOOL cpuOnly;
    BOOL ownBuffer;   // feed Vision a CVPixelBuffer we allocated instead of the CGImage
} AxsOcrHelperConfig;

__attribute__((noreturn))
static void axs_ocr_helper_finish(int code) {
    fflush(stdout);
    // Skip Objective-C/C++ teardown on purpose: releasing the text recognition model
    // aborted the host process inside AppleNeuralEngine. The output is already flushed.
    _exit(code);
}

static NSArray<NSString *> *axs_ocr_helper_languages(VNRecognizeTextRequest *request) {
    NSError *error = nil;
    NSArray<NSString *> *supported = [request supportedRecognitionLanguagesAndReturnError:&error];
    if (supported.count == 0) return nil;
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    for (NSString *language in @[@"zh-Hans", @"zh-Hant", @"en-US"]) {
        if ([supported containsObject:language]) [languages addObject:language];
    }
    return languages.count > 0 ? languages : nil;
}

// Draws the image into a plain memory-backed BGRA buffer (no IOSurface attributes).
// Vision's own conversion to 420f failed in this process, so this avoids relying on it
// for the input. Returns a +1 buffer the caller releases, or NULL.
static CVPixelBufferRef axs_ocr_helper_createBuffer(CGImageRef image) {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess || !buffer) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
        CVPixelBufferGetBytesPerRow(buffer), colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (!context) {
        CVPixelBufferRelease(buffer);
        return NULL;
    }
    return buffer;
}

// Returns the recognized text, or nil with *error set.
static NSString *axs_ocr_helper_recognize(CGImageRef image, AxsOcrHelperConfig config, NSError **error) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    request.recognitionLevel = config.fast ? VNRequestTextRecognitionLevelFast
                                           : VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = !config.fast;
    NSArray<NSString *> *languages = axs_ocr_helper_languages(request);
    if (languages) request.recognitionLanguages = languages;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = config.cpuOnly;
#pragma clang diagnostic pop

    CVPixelBufferRef buffer = NULL;
    VNImageRequestHandler *handler;
    if (config.ownBuffer) {
        buffer = axs_ocr_helper_createBuffer(image);
        if (!buffer) {
            if (error) *error = [NSError errorWithDomain:@"com.axs.ocr.helper" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"cannot allocate own pixel buffer"}];
            return nil;
        }
        handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
    } else {
        handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    }
    BOOL ok = [handler performRequests:@[request] error:error];
    if (buffer) CVPixelBufferRelease(buffer);
    if (!ok) return nil;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (line.length > 0) [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) {
            fputs("usage: AxsOcrHelper [--safe|--any] <image path>\n", stderr);
            axs_ocr_helper_finish(2);
        }
        BOOL allowAnyDevice = strcmp(argv[1], "--any") == 0;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];

        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (!image) {
            fputs("cannot load image\n", stdout);
            axs_ocr_helper_finish(3);
        }

        // Accurate before fast; CPU-only before default devices; CGImage before own buffer.
        AxsOcrHelperConfig configs[] = {
            {NO,  YES, NO}, {NO,  YES, YES}, {YES, YES, NO}, {YES, YES, YES},
            {NO,  NO,  NO}, {NO,  NO,  YES}, {YES, NO,  NO}, {YES, NO,  YES},
        };
        NSInteger count = allowAnyDevice ? 8 : 4;
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        for (NSInteger index = 0; index < count; index++) {
            AxsOcrHelperConfig config = configs[index];
            NSError *error = nil;
            NSString *text = axs_ocr_helper_recognize(image, config, &error);
            if (text) {
                fputs(text.UTF8String, stdout);
                axs_ocr_helper_finish(0);
            }
            // The first line of each message is enough to tell the failure modes apart.
            NSString *reason = [error.localizedDescription componentsSeparatedByString:@"\n"].firstObject;
            [failures addObject:[NSString stringWithFormat:@"%@%@%@: %@",
                                 config.fast ? @"fast" : @"accurate",
                                 config.cpuOnly ? @"+cpu" : @"",
                                 config.ownBuffer ? @"+buf" : @"",
                                 reason ?: @"unknown error"]];
        }
        fputs([failures componentsJoinedByString:@"\n"].UTF8String, stdout);
        axs_ocr_helper_finish(4);
    }
}
