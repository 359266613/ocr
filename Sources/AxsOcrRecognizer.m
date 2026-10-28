#import "AxsOcrRecognizer.h"
#import "AxsOcrPaths.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString * const AxsOcrErrorDomain = @"com.axs.ocr";
static NSString * const AxsOcrHelperPath = @"/usr/libexec/AxsOcrHelper";
static const NSTimeInterval AxsOcrHelperTimeout = 25.0;

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

// Runs the helper on an image file and returns its stdout (possibly empty).
// Returns nil with *error set when the helper cannot start, times out, or fails.
// Vision runs in the helper, never in this process: loading its text model inside
// SpringBoard crashed it (SIGTRAP in AppleNeuralEngine) and caused safe mode.
static NSString *axs_ocr_runHelper(NSString *imagePath, BOOL allowAnyDevice, NSError **error) {
    NSString *helperPath = axs_ocr_resourcePath(AxsOcrHelperPath);
    if (access(helperPath.fileSystemRepresentation, X_OK) != 0) {
        if (error) *error = axs_ocr_error(10, @"找不到识别组件，请重新安装插件");
        return nil;
    }

    int outPipe[2];
    if (pipe(outPipe) != 0) {
        if (error) *error = axs_ocr_error(11, @"无法创建管道");
        return nil;
    }
    // The child gets stdout through dup2 below; its copies of the pipe ends close on exec.
    fcntl(outPipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(outPipe[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    const char *helper = helperPath.fileSystemRepresentation;
    const char *argv[] = { helper, allowAnyDevice ? "--any" : "--safe", imagePath.fileSystemRepresentation, NULL };
    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, helper, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(outPipe[1]);
    if (spawnResult != 0) {
        close(outPipe[0]);
        if (error) *error = axs_ocr_error(12, @"无法启动识别组件");
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + AxsOcrHelperTimeout;
    BOOL timedOut = NO;
    for (;;) {
        int remaining = (int)((deadline - CFAbsoluteTimeGetCurrent()) * 1000);
        if (remaining <= 0) { timedOut = YES; break; }
        struct pollfd descriptor = { outPipe[0], POLLIN, 0 };
        int ready = poll(&descriptor, 1, remaining);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) { timedOut = YES; break; }
        char buffer[4096];
        ssize_t count = read(outPipe[0], buffer, sizeof(buffer));
        if (count > 0) [output appendBytes:buffer length:(NSUInteger)count];
        else if (count == 0) break;                 // EOF: the helper exited
        else if (errno != EINTR) break;
    }
    close(outPipe[0]);
    if (timedOut) kill(pid, SIGKILL);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    if (timedOut) {
        if (error) *error = axs_ocr_error(13, @"识别超时");
        return nil;
    }
    if (WIFSIGNALED(status)) {
        if (error) *error = axs_ocr_error(14, [NSString stringWithFormat:@"识别组件异常退出（信号 %d）", WTERMSIG(status)]);
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
    if (WEXITSTATUS(status) != 0) {
        // On failure the helper prints the Vision error messages instead of text.
        NSString *detail = text.length > 0 ? [NSString stringWithFormat:@"\n%@", text] : @"";
        if (error) *error = axs_ocr_error(15, [NSString stringWithFormat:@"识别失败（代码 %d）%@", WEXITSTATUS(status), detail]);
        return nil;
    }
    return text;
}

@implementation AxsOcrRecognizer

+ (void)axs_ocr_recognizeScreenWithCompletion:(AxsOcrCompletion)completion {
    UIImage *image = axs_ocr_captureScreen();
    if (!image) {
        completion(nil, axs_ocr_error(1, @"无法截取屏幕"));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"axsocr-%@.png", [NSUUID UUID].UUIDString]];
        NSData *png = UIImagePNGRepresentation(image);
        NSError *error = nil;
        NSString *text = nil;
        if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
            error = error ?: axs_ocr_error(2, @"无法保存截图");
        } else {
            // CPU-only first; if that fails, let the helper try the default compute devices.
            // A crash there only kills the helper process.
            for (NSInteger attempt = 0; attempt < 2 && !text; attempt++) {
                error = nil;
                text = axs_ocr_runHelper(path, attempt > 0, &error);
            }
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!text) {
                completion(nil, error ?: axs_ocr_error(3, @"识别失败"));
            } else if (text.length == 0) {
                completion(nil, axs_ocr_error(4, @"没有识别到文字"));
            } else {
                completion(text, nil);
            }
        });
    });
}

@end
