#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>
#import <notify.h>

// 声音路由磁贴 —— 云端构建版（官方工具链）
// 结构参考: ba31k/RefreshRateCC (MIT)
// 状态文件: /var/mobile/.rc_speaker_on ("1" = 扬声器接管中)
// 切换动作: notify_post("com.rc.apphelper.toggle")
//          (设备上的 RCSpeakerApp.dylib 监听此通知, 在各 App 内切换 AVAudioSession)

static NSString *StateFile = @"/var/mobile/.rc_speaker_on";
static NSString *NotifyName = @"com.rc.apphelper.toggle";

static BOOL SpeakerOn(void) {
    NSString *s = [NSString stringWithContentsOfFile:StateFile
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    return [s isEqualToString:@"1"];
}

static void SetSpeakerOn(BOOL on) {
    [on ? @"1" : @"0" writeToFile:StateFile
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:nil];
    notify_post(NotifyName.UTF8String);
}

@interface RCSpeakerToggleModule : CCUIToggleModule
{
    BOOL _selected;
}
@end

@implementation RCSpeakerToggleModule

+ (void)load {
    NSLog(@"[RCSpeakerCC] module loaded, speaker=%d", SpeakerOn());
}

- (BOOL)isSelected {
    _selected = SpeakerOn();
    return _selected;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    SetSpeakerOn(selected);
    [super refreshState];
}

- (UIColor *)selectedColor {
    return [UIColor colorWithRed:0.10 green:0.36 blue:0.90 alpha:1.0];
}

- (UIImage *)iconGlyph {
    return [UIImage systemImageNamed:@"speaker.wave.2.fill"];
}

@end
