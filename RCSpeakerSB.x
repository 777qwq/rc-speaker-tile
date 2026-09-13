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

#include <dlfcn.h>

static void MRForceRoute(BOOL speaker) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { RCLog("MR: dlopen failed"); return; }
    CFArrayRef (*CopyRoutes)(void) = (CFArrayRef (*)(void))dlsym(mr, "MRMediaRemoteCopyPickableRoutes");
    void (*SetPicked)(CFStringRef, CFStringRef) = (void (*)(CFStringRef, CFStringRef))dlsym(mr, "MRMediaRemoteSetPickedRouteWithPassword");
    if (!CopyRoutes || !SetPicked) { RCLog("MR: symbols missing"); return; }
    CFArrayRef routes = CopyRoutes();
    if (!routes) { RCLog("MR: no routes"); return; }
    CFIndex n = CFArrayGetCount(routes);
    NSString *devName = [[UIDevice currentDevice] name];
    CFStringRef pickUID = NULL;
    CFStringRef altUID = NULL;
    char linebuf[512];
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(routes, i);
        CFStringRef name = CFDictionaryGetValue(d, CFSTR("RouteName"));
        CFStringRef uid = CFDictionaryGetValue(d, CFSTR("RouteUID"));
        if (!name || !uid) continue;
        const char *ns = [(__bridge NSString *)name UTF8String];
        const char *us = [(__bridge NSString *)uid UTF8String];
        snprintf(linebuf, sizeof(linebuf), "MR route: name=%s uid=%s", ns ? ns : "?", us ? us : "?");
        RCLog(linebuf);
        BOOL builtin = [(__bridge NSString *)name isEqualToString:devName];
        if (builtin && speaker) pickUID = uid;
        if (!builtin && !altUID) altUID = uid;
    }
    if (speaker) {
        if (pickUID) { SetPicked(pickUID, CFSTR("")); RCLog("MR: picked builtin speaker"); }
        else {
            RCLog("MR: builtin not listed, trying hard pick by device name");
            SetPicked((__bridge CFStringRef)devName, CFSTR(""));
        }
    } else {
        if (altUID) { SetPicked(altUID, CFSTR("")); RCLog("MR: picked alt route"); }
        else RCLog("MR: no alt route, keep default");
    }
    CFRelease(routes);
}

%hook SpringBoard

%new - (void)rcDoToggle {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)RCToggleName(), NULL, NULL, YES);
        BOOL on = [[NSString stringWithContentsOfFile:@"/var/mobile/.rc_speaker_on" encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"1"];
        MRForceRoute(on);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([[NSString stringWithContentsOfFile:@"/var/mobile/.rc_speaker_on" encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"1"]) {
            RCLog("state=ON at launch, forcing route");
            MRForceRoute(YES);
        }
    });
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
