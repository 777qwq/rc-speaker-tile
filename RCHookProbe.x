#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>
#include <stdio.h>

static void PLog(const char *msg) {
    FILE *f = fopen("/var/mobile/rc_probe.log", "a");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    if (ftell(f) > 100 * 1024) { fclose(f); f = fopen("/var/mobile/rc_probe.log", "w"); if (!f) return; }
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[PROBE %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg);
    fclose(f);
}

static time_t g_catLog = 0;

%hook AVAudioSession
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    BOOL r = %orig;
    PLog(active ? "setActive(withOptions) YES (hook works)" : "setActive(withOptions) NO");
    return r;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    BOOL r = %orig;
    PLog(active ? "setActive(error) YES (hook works)" : "setActive(error) NO");
    return r;
}
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    BOOL r = %orig;
    PLog("setCategory hooked");
    return r;
}
- (NSString *)category {
    NSString *r = %orig;
    time_t now = time(NULL);
    if (now - g_catLog > 15) { g_catLog = now; PLog("category getter fired (interception alive)"); }
    return r;
}
%end

%ctor {
    %init;
    PLog("probe loaded, hook installed");
}
