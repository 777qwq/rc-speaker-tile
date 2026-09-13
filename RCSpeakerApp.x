#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>
#include <stdarg.h>
#include <stdio.h>

static NSString *StateFile = @"/var/mobile/.rc_speaker_on";

static BOOL SpeakerOn(void) {
    NSString *s = [NSString stringWithContentsOfFile:StateFile encoding:NSUTF8StringEncoding error:nil];
    return [s isEqualToString:@"1"];
}

static void AppLog(NSString *msg) {
    FILE *f = fopen("/var/mobile/rc_debug.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[APP %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

static NSString *savedCategory_global = nil;
static BOOL g_speakerOn = NO;

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
        AppLog(@"speaker ON (auto)");
    } @catch (NSException *e) { AppLog(@"apply exception"); }
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
        AppLog(@"speaker OFF (restored)");
    } @catch (NSException *e) { AppLog(@"restore exception"); }
}

static void ToggleCallback(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (SpeakerOn()) applySpeakerMode();
            else restoreHeadphoneMode();
        } @catch (NSException *e) { AppLog(@"toggle exception"); }
    });
}

%hook AVAudioSession
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    BOOL r = %orig;
    if (r && active && SpeakerOn()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (SpeakerOn() && !g_speakerOn) applySpeakerMode();
            else if (SpeakerOn() && g_speakerOn) applySpeakerMode();
        });
    }
    return r;
}
%end

%ctor {
    %init;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleCallback, CFSTR("com.rc.apphelper.toggle"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    // 冷启动自动接管：若开关为开，延迟应用
    if (SpeakerOn()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (SpeakerOn()) applySpeakerMode();
        });
    }
}
