#import <Foundation/Foundation.h>
#include <stdarg.h>
#include <stdio.h>
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>

static NSString * _Nullable RC(const char *c) {
    @try { return [[NSString alloc] initWithUTF8String:c]; }
    @catch (NSException *e) { return nil; }
}
static NSString *RCToggleName(void) {
    static NSString *n = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ n = RC("com.rc.apphelper.toggle"); }); return n;
}

static NSString *savedCategory_global = nil;
static BOOL g_speakerOn = NO;

static void AppLog(const char *fmt, ...) {
    FILE *f = fopen("/var/mobile/rc_debug.log", "a");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    if (ftell(f) > 200 * 1024) { fclose(f); f = fopen("/var/mobile/rc_debug.log", "w"); if (!f) return; }
    char buf[512]; va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[APP %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, buf);
    fclose(f);
}

static void applySpeakerMode(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (!savedCategory_global) savedCategory_global = [s.category copy];
        NSError *err = nil;
        BOOL ok = [s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];
        if (!ok) {
            err = nil;
            ok = [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&err];
            if (ok) {
                err = nil;
                [s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];
            }
        }
        g_speakerOn = YES;
        AppLog("speaker ON");
    } @catch (NSException *e) { AppLog("apply exception"); }
}

static void restoreHeadphoneMode(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *err = nil;
        [s overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&err];
        if (savedCategory_global) {
            [s setCategory:savedCategory_global mode:AVAudioSessionModeDefault options:0 error:&err];
            savedCategory_global = nil;
        }
        g_speakerOn = NO;
        AppLog("speaker OFF (restored)");
    } @catch (NSException *e) { AppLog("restore exception"); }
}

static void ToggleCallback(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
            AppLog("callback fired, bid=%s", bid ? [bid UTF8String] : "(null)");
            if (g_speakerOn) restoreHeadphoneMode();
            else applySpeakerMode();
        } @catch (NSException *e) { AppLog("toggle exception"); }
    });
}


#include <limits.h>
#include <stdlib.h>

static NSArray *RCStatePaths(void) {
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *m = [NSMutableArray array];
        char resolved[PATH_MAX];
        if (realpath("/var/jb", resolved))
            [m addObject:[[NSString alloc] initWithFormat:@"%s/var/mobile/.rc_speaker_on", resolved]];
        [m addObject:[[NSString alloc] initWithFormat:@"/var/mob%@/.rc_speaker_on", @"ile"]];
        paths = [m copy];
    });
    return paths;
}

static BOOL RCSpeakerOn(void) {
    for (NSString *p in RCStatePaths()) {
        FILE *f = fopen(p.UTF8String, "r");
        if (!f) continue;
        char buf[8]; memset(buf, 0, sizeof(buf));
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        if (n > 0 && buf[0] == '1') return YES;
    }
    return NO;
}

%ctor {
    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];
    if (!myBid || myBid.length == 0) return;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleCallback, (__bridge CFStringRef)RCToggleName(), NULL, CFNotificationSuspensionBehaviorCoalesce);
    AppLog("hook loaded, bid=%s", myBid.UTF8String);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (RCSpeakerOn()) { AppLog("state=ON at launch"); applySpeakerMode(); }
        else { AppLog("state=OFF at launch"); }
    });
    // 按需纠错：仅当开关为开且实际路由不是扬声器时补挂
    dispatch_source_t rcTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(rcTimer, DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC, 1ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(rcTimer, ^{
        if (!RCSpeakerOn()) return;
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (s.isOtherAudioPlaying) return; // 别的 App 正在发声，由它负责
        BOOL speakerNow = NO;
        for (AVAudioSessionPortDescription *out in s.currentRoute.outputs) {
            if ([out.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) { speakerNow = YES; break; }
        }
        if (!speakerNow) {
            static time_t lastAssert = 0;
            time_t now = time(NULL);
            int verbose = (now - lastAssert > 60);
            if (verbose) lastAssert = now;
            applySpeakerMode();
            if (verbose) AppLog("route drifted, re-asserted");
        }
    });
    dispatch_resume(rcTimer);
}
