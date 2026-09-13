#import <Foundation/Foundation.h>
@class SpringBoard;
#import <UIKit/UIKit.h>


static NSString * _Nullable RC(const char *c) {
    @try { return [[NSString alloc] initWithUTF8String:c]; }
    @catch (NSException *e) { return nil; }
}
static NSString *RCToggleName(void) {
    static NSString *n = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ n = RC("com.rc.apphelper.toggle"); }); return n;
}

#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <mach-o/dyld.h>

static void RCLog(const char *msg) {
    int fd = open("/var/mobile/rc_debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    if (lseek(fd, 0, SEEK_END) > 200 * 1024) { close(fd); fd = open("/var/mobile/rc_debug.log", O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) return; }
    char buf[512];
    time_t t = time(NULL);
    struct tm tmv; localtime_r(&t, &tmv);
    int n = snprintf(buf, sizeof(buf), "[SB %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg);
    write(fd, buf, n);
    close(fd);
}

%hook SpringBoard

%new - (void)rcDoToggle {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)RCToggleName(), NULL, NULL, YES);
        RCLog("toggle: posted");
    } @catch (NSException *e) {
        RCLog("toggle exception");
    }
}

-(void)applicationDidFinishLaunching:(id)application {
    %orig;
    RCLog("tweak loaded, starting local server");
}

%end

%ctor {
    %init;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int sfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sfd < 0) { RCLog("socket failed"); return; }
        int opt = 1;
        setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(18080);
        if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { RCLog("bind failed"); close(sfd); return; }
        if (listen(sfd, 4) < 0) { RCLog("listen failed"); close(sfd); return; }
        RCLog("http server ready");
        char buf[1024];
        for (;;) {
            int cfd = accept(sfd, NULL, NULL);
            if (cfd < 0) continue;
            memset(buf, 0, sizeof(buf));
            read(cfd, buf, sizeof(buf) - 1);
            if (strstr(buf, "GET /toggle")) {
                const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
                write(cfd, resp, strlen(resp));
                close(cfd);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [(id)[UIApplication sharedApplication] performSelector:@selector(rcDoToggle)];
                });
            } else {
                const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
                write(cfd, resp, strlen(resp));
                close(cfd);
            }
        }
    });
}
