#import <Foundation/Foundation.h>
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

// Returns the recognized text, or nil with *error set.
static NSString *axs_ocr_helper_recognize(CGImageRef image, BOOL fast, BOOL cpuOnly, NSError **error) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    request.recognitionLevel = fast ? VNRequestTextRecognitionLevelFast
                                    : VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = !fast;
    NSArray<NSString *> *languages = axs_ocr_helper_languages(request);
    if (languages) request.recognitionLanguages = languages;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = cpuOnly;
#pragma clang diagnostic pop

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:error]) return nil;

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

        // {fast, cpuOnly}: accurate first, then fast; CPU-only first, then default devices.
        BOOL configs[4][2] = { {NO, YES}, {YES, YES}, {NO, NO}, {YES, NO} };
        NSInteger count = allowAnyDevice ? 4 : 2;
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        for (NSInteger index = 0; index < count; index++) {
            NSError *error = nil;
            NSString *text = axs_ocr_helper_recognize(image, configs[index][0], configs[index][1], &error);
            if (text) {
                fputs(text.UTF8String, stdout);
                axs_ocr_helper_finish(0);
            }
            [failures addObject:[NSString stringWithFormat:@"%@%@: %@",
                                 configs[index][0] ? @"fast" : @"accurate",
                                 configs[index][1] ? @"+cpu" : @"",
                                 error.localizedDescription ?: @"unknown error"]];
        }
        fputs([failures componentsJoinedByString:@"\n"].UTF8String, stdout);
        axs_ocr_helper_finish(4);
    }
}
