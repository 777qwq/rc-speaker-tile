#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <stdarg.h>
#include <stdio.h>
#include <limits.h>
#include <stdlib.h>
#include <dlfcn.h>

static void AppLog(const char *fmt, ...) {
    return; // logging disabled
    FILE *f = fopen("/var/mobile/rc_debug531.log", "a");
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
        if (!f) { AppLog("state check: %s (unreadable)", p.UTF8String); continue; }
        char buf[8]; memset(buf, 0, sizeof(buf));
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        AppLog("state check: %s = %s", p.UTF8String, (n > 0 && buf[0] == '1') ? "1" : (n > 0 ? buf : "empty"));
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

static BOOL g_inApply = NO;

extern void MSHookFunction(void *symbol, void *hook, void **old);

static void applySpeakerMode(void) {
    @try {
        g_inApply = YES;
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
    @try { g_inApply = NO; } @catch (NSException *e) {}
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
    @try { g_inApply = NO; } @catch (NSException *e) {}
}

static void ToggleCallback(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            BOOL on = RCSpeakerOn();
            BOOL spk = RouteIsSpeaker();
            AppLog("callback: state=%d routeIsSpeaker=%d", on ? 1 : 0, spk ? 1 : 0);
            if (!spk) {
                AVAudioSession *s = [AVAudioSession sharedInstance];
                for (AVAudioSessionPortDescription *out in s.currentRoute.outputs) {
                    AppLog("route output: %s", out.portType.UTF8String ? out.portType.UTF8String : "?");
                }
            }
            if (on) { if (!spk) applySpeakerMode(); }
            else restoreHeadphoneMode();
        } @catch (NSException *e) { AppLog("toggle exception"); }
    });
}

%group AVHooks
%hook AVAudioEngine
- (BOOL)startAndReturnError:(NSError **)outError {
    BOOL r = %orig;
    if (r && RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("AVAudioEngine start, re-assert"); applySpeakerMode(); }
    return r;
}
%end

%hook AVPlayer
- (void)play {
    %orig;
    if (RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("AVPlayer play, re-assert"); applySpeakerMode(); }
}
- (void)playImmediatelyAtRate:(float)rate {
    %orig;
    if (RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("AVPlayer playImmediately, re-assert"); applySpeakerMode(); }
}
- (void)setRate:(float)rate {
    %orig;
    if (rate > 0.0 && RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("AVPlayer setRate, re-assert"); applySpeakerMode(); }
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

%group RendererHooks
%hook AVSampleBufferAudioRenderer
- (void)play {
    %orig;
    if (RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("Renderer play, re-assert"); applySpeakerMode(); }
}
%end
%end

static BOOL g_avInited = NO;

static OSStatus (*orig_ASActive2)(unsigned int, void *options);
static OSStatus hook_ASActive2(unsigned int sid, void *options) {
    OSStatus r = orig_ASActive2(sid, options);
    if (!g_inApply && RCSpeakerOn()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_inApply && RCSpeakerOn() && !RouteIsSpeaker()) applySpeakerMode();
        });
    }
    return r;
}

static OSStatus (*orig_ASActive1)(int);
static OSStatus hook_ASActive1(int active) {
    OSStatus r = orig_ASActive1(active);
    if (active && !g_inApply && RCSpeakerOn()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_inApply && RCSpeakerOn() && !RouteIsSpeaker()) applySpeakerMode();
        });
    }
    return r;
}

static void *g_hookedPtrs[8] = {0};
static int g_hookedCount = 0;

static BOOL AlreadyHooked(void *p) {
    for (int i = 0; i < g_hookedCount; i++) if (g_hookedPtrs[i] == p) return YES;
    return NO;
}
static void MarkHooked(void *p) { if (g_hookedCount < 8) g_hookedPtrs[g_hookedCount++] = p; }

static void TryInstallCHook(void) {
    void *ms = dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!ms) return;
    void (*_MSHookFunction)(void *, void *, void **) = (void (*)(void *, void *, void **))ms;

    const char *libs[] = {
        "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
        "/System/Library/PrivateFrameworks/AudioSession.framework/AudioSession",
        "/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox",
        NULL
    };
    const char *syms2[] = { "AudioSessionSetActiveWithOptions", "AudioSessionSetActiveWithProperties", NULL };
    for (int li = 0; libs[li]; li++) {
        void *tb = dlopen(libs[li], RTLD_NOW);
        if (!tb) continue;
        for (int si = 0; syms2[si]; si++) {
            void *fn = dlsym(tb, syms2[si]);
            if (fn && !AlreadyHooked(fn)) {
                _MSHookFunction(fn, (void *)hook_ASActive2, (void **)&orig_ASActive2);
                MarkHooked(fn);
                AppLog("C hook installed: %s", syms2[si]);
            }
        }
        void *fn1 = dlsym(tb, "AudioSessionSetActive");
        if (fn1 && !AlreadyHooked(fn1)) {
            _MSHookFunction(fn1, (void *)hook_ASActive1, (void **)&orig_ASActive1);
            MarkHooked(fn1);
            AppLog("C hook installed: AudioSessionSetActive");
        }
        void *au = dlopen("/System/Library/Frameworks/AudioUnit.framework/AudioUnit", RTLD_NOW);
        if (au) {
            void *fou = dlsym(au, "AudioOutputUnitStart");
            if (fou && !AlreadyHooked(fou)) {
                _MSHookFunction(fou, (void *)hook_ASActive1, (void **)&orig_ASActive1);
                MarkHooked(fou);
                AppLog("C hook installed: AudioOutputUnitStart");
            }
        }
        void *aq = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
        if (aq) {
            void *fqs = dlsym(aq, "AudioQueueStart");
            if (fqs && !AlreadyHooked(fqs)) {
                _MSHookFunction(fqs, (void *)hook_ASActive1, (void **)&orig_ASActive1);
                MarkHooked(fqs);
                AppLog("C hook installed: AudioQueueStart");
            }
        }
    }
}

static void InstallRouteObserver(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:[AVAudioSession sharedInstance] queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (!g_inApply && RCSpeakerOn() && !RouteIsSpeaker()) { AppLog("route change, re-assert"); applySpeakerMode(); }
    }];
}

static void TryInitAVHooks(void) {
    if (g_avInited) return;
    if (objc_getClass("AVPlayer") && objc_getClass("AVAudioPlayer")) {
        %init(AVHooks);
        g_avInited = YES;
        AppLog("AV hooks registered");
    }
    if (objc_getClass("AVSampleBufferAudioRenderer")) {
        %init(RendererHooks);
        AppLog("Renderer hooks registered");
    }
    TryInstallCHook();
}

%ctor {
    %init;
    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleCallback, CFSTR("com.rc.apphelper.toggle"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    {
        NSString *nb = [[NSString alloc] initWithFormat:@"com.rc.apphelper.%@", @"toggle"];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleCallback, (__bridge CFStringRef)nb, NULL, CFNotificationSuspensionBehaviorCoalesce);
        AppLog("observers: literal + runtime dual registered");
    }
    AppLog("hook loaded, bid=%s", myBid ? myBid.UTF8String : "(null)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (RCSpeakerOn()) { AppLog("state=ON at launch"); if (!RouteIsSpeaker()) applySpeakerMode(); }
        else { AppLog("state=OFF at launch"); }
    });
    // AV 框架可能加载较晚，多次尝试注册钩子
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInitAVHooks(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInitAVHooks(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInitAVHooks(); });
    InstallRouteObserver();
}
