#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <unistd.h>

// Usage: AxsOcrHelper [--accurate|--fast] <image path>
// Prints the recognized text on stdout, one line per text block.
// Exit codes: 0 ok, 2 bad arguments, 3 image load failed, 4 recognition failed.
//
// Runs as its own process so a Vision/Neural Engine failure cannot take SpringBoard down.

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

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) {
            fputs("usage: AxsOcrHelper [--accurate|--fast] <image path>\n", stderr);
            axs_ocr_helper_finish(2);
        }
        BOOL fast = strcmp(argv[1], "--fast") == 0;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];

        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (!image) {
            fputs("cannot load image\n", stderr);
            axs_ocr_helper_finish(3);
        }

        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
        request.recognitionLevel = fast ? VNRequestTextRecognitionLevelFast
                                        : VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = !fast;
        NSArray<NSString *> *languages = axs_ocr_helper_languages(request);
        if (languages) request.recognitionLanguages = languages;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        request.usesCPUOnly = YES;
#pragma clang diagnostic pop

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String ?: "recognition failed");
            axs_ocr_helper_finish(4);
        }

        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (VNRecognizedTextObservation *observation in request.results) {
            NSString *line = [observation topCandidates:1].firstObject.string;
            if (line.length > 0) [lines addObject:line];
        }
        fputs([lines componentsJoinedByString:@"\n"].UTF8String, stdout);
        axs_ocr_helper_finish(0);
    }
}
