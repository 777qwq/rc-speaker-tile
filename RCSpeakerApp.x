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


static BOOL RCSpeakerOn(void) {
    FILE *f = fopen("/var/mobile/.rc_speaker_on", "r");
    if (!f) return NO;
    char buf[8]; memset(buf, 0, sizeof(buf));
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    return n > 0 && buf[0] == '1';
}

static dispatch_source_t rcTimer = NULL;

static void StartAutoApplyTimer(void) {
    if (rcTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC, 1ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{
        if (RCSpeakerOn() && !g_speakerOn) applySpeakerMode();
    });
    dispatch_resume(t);
    rcTimer = t;
}

%ctor {
    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];
    if (!myBid || myBid.length == 0) return;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleCallback, (__bridge CFStringRef)RCToggleName(), NULL, CFNotificationSuspensionBehaviorCoalesce);
    AppLog("hook loaded, bid=%s", myBid.UTF8String);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (RCSpeakerOn()) { AppLog("state=ON at launch"); applySpeakerMode(); }
        StartAutoApplyTimer();
    });
}
