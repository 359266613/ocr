#pragma once

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>
#import "AxsOcrPaths.h"

// Appends one line to /var/mobile/Library/Logs/AxsOcr.log.
// Safe from any thread. The file is dropped once it passes about 200 KB.
static inline void axs_ocr_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static inline void axs_ocr_log(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &local);
    NSString *line = [NSString stringWithFormat:@"%s [%d] %@\n", stamp, getpid(), message];

    const char *path = axs_ocr_logPath().fileSystemRepresentation;
    NSString *directory = [axs_ocr_logPath() stringByDeletingLastPathComponent];
    mkdir(directory.fileSystemRepresentation, 0755);
    struct stat info;
    if (stat(path, &info) == 0 && info.st_size > 200000) unlink(path);
    int descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (descriptor < 0) return;
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(descriptor, data.bytes, data.length);
    close(descriptor);
}
