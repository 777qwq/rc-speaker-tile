#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <stdarg.h>
#include <stdio.h>
#include <limits.h>
#include <stdlib.h>

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

static NSString *savedCategory_global = nil;
static BOOL g_speakerOn = NO;

static BOOL RouteIsSpeaker(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    for (AVAudioSessionPortDescription *out in s.currentRoute.outputs) {
        if ([out.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) return YES;
    }
    return NO;
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
            if (ok) { err = nil; [s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err]; }
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
            if (RCSpeakerOn()) { if (!RouteIsSpeaker()) applySpeakerMode(); }
            else restoreHeadphoneMode();
        } @catch (NSException *e) { AppLog("toggle exception"); }
    });
}

%group AVHooks
%hook AVPlayer
- (void)play {
    %orig;
    if (RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("AVPlayer play, re-assert"); applySpeakerMode(); }
}
%end

%hook AVAudioPlayer
- (BOOL)play {
    BOOL r = %orig;
    if (RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("AVAudioPlayer play, re-assert"); applySpeakerMode(); }
    return r;
}
%end
%end

static BOOL g_avInited = NO;

static void TryInitAVHooks(void) {
    if (g_avInited) return;
    if (objc_getClass("AVPlayer") && objc_getClass("AVAudioPlayer")) {
        %init(AVHooks);
        g_avInited = YES;
        AppLog("AV hooks registered");
    }
}

%ctor {
    %init;
    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleCallback, CFSTR("com.rc.apphelper.toggle"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    AppLog("hook loaded, bid=%s", myBid ? myBid.UTF8String : "(null)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (RCSpeakerOn()) { AppLog("state=ON at launch"); if (!RouteIsSpeaker()) applySpeakerMode(); }
        else { AppLog("state=OFF at launch"); }
    });
    // AV 框架可能加载较晚，多次尝试注册钩子
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInitAVHooks(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInitAVHooks(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInitAVHooks(); });
}
