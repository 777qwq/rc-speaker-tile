#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static void CLog(NSString *msg) {
    NSString *p = [[NSString alloc] initWithFormat:@"/var/mob%@/pw_ctl.log", @"ile"];
    FILE *f = fopen(p.UTF8String, "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[CTL %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

// 捕获的指令帧（2026-09-14 23:39 校准：打开=byte17 0x00，关闭=byte17 0x32）
static const unsigned char ON_FRAME[]  = {0x20,0x01,0x16,0x00,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x03,0x01,0x00,0x01,0x02,0x22,0x01,0x01,0x00,0x5f};
static const unsigned char OFF_FRAME[] = {0x20,0x01,0x16,0x00,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x03,0x01,0x32,0x01,0x02,0x20,0x01,0x00,0x00,0x8e};
#define FRAME_LEN 26
static NSString * const SVC_UUID = @"49535343-FE7D-4AE5-8FA9-9FAFD205E455";
static NSString * const CHR_UUID = @"49535343-8841-43F4-A8D4-ECBE34729BB3";

static NSString *DesiredPath(void) {
    return [[NSString alloc] initWithFormat:@"/var/mob%@/.pw_cooler_desired", @"ile"];
}
static void SetDesired(BOOL on) {
    [on ? @"1" : @"0" writeToFile:DesiredPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL DesiredOn(void) {
    NSString *s = [NSString stringWithContentsOfFile:DesiredPath() encoding:NSUTF8StringEncoding error:nil];
    return [s isEqualToString:@"1"]; // 文件不存在时默认=关（守护会压制来电自启动）
}

@interface PWCentral : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (strong, nonatomic) CBCentralManager *cm;
@property (strong, nonatomic) CBPeripheral *periph;
@property (strong, nonatomic) CBCharacteristic *wchr;
@property (copy, nonatomic) void (^onReady)(void);
@property (assign, nonatomic) BOOL scanning;
+ (PWCentral *)shared;
- (void)applyDesired;
- (void)writeFrame:(NSData *)d;
@end

@implementation PWCentral

+ (PWCentral *)shared {
    static PWCentral *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PWCentral alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cm = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        CLog(@"central init");
    }
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    CLog([NSString stringWithFormat:@"cm state=%ld", (long)central.state]);
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    NSString *nm = (peripheral.name ?: @"").lowercaseString;
    if (![nm containsString:@"b2max"]) return; // 只关心散热器，其他设备不记日志
    CLog([NSString stringWithFormat:@"guard discovered B2MAX rssi=%@", RSSI]);
    if (self.periph) return;
    self.periph = peripheral;
    peripheral.delegate = self;
    [central stopScan];
    self.scanning = NO;
    [central connectPeripheral:peripheral options:nil];
    CLog(@"guard connecting");
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    CLog(@"connect failed");
    self.periph = nil;
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    CLog(@"connected, discovering");
    [peripheral discoverServices:@[[CBUUID UUIDWithString:SVC_UUID]]];
}

- (void)peripheral:(CBPeripheral *)peripheral didDisconnectPeripheral:(NSError *)error {
    CLog(@"disconnected (guard will re-enforce)");
    self.wchr = nil;
    self.periph = nil;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:CHR_UUID]] forService:peripheral.services.firstObject];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID.UUIDString isEqualToString:CHR_UUID]) {
            self.wchr = c;
            CLog(@"write characteristic ready");
        }
    }
    if (self.wchr && self.onReady) { void (^cb)(void) = self.onReady; self.onReady = nil; cb(); }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    CLog(error ? @"write err" : @"write ok");
}

- (void)writeFrame:(NSData *)d {
    if (self.wchr && self.periph) {
        CBCharacteristicWriteType t = (self.wchr.properties & CBCharacteristicPropertyWriteWithoutResponse) ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
        [self.periph writeValue:d forCharacteristic:self.wchr type:t];
        CLog(@"frame written");
    } else {
        CLog(@"write skipped, not ready");
    }
}

- (void)applyDesired {
    BOOL want = DesiredOn();
    NSData *frame = [NSData dataWithBytes:(want ? ON_FRAME : OFF_FRAME) length:FRAME_LEN];
    CLog([NSString stringWithFormat:@"applying desired state: %@", want ? @"ON" : @"OFF"]);
    [self writeFrame:frame];
}

- (void)requestState:(BOOL)on reply:(void (^)(NSString *line))reply {
    SetDesired(on);
    NSData *frame = [NSData dataWithBytes:(on ? ON_FRAME : OFF_FRAME) length:FRAME_LEN];
    if (!self.wchr) {
        CLog(@"not connected, connecting first");
        self.onReady = ^{ [[PWCentral shared] applyDesired]; if (reply) reply(@"ok"); };
        if (self.cm.state == CBManagerStatePoweredOn && !self.periph && !self.scanning) {
            [self.cm scanForPeripheralsWithServices:nil options:nil];
            self.scanning = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.scanning) { [self.cm stopScan]; self.scanning = NO; }
            });
        }
    } else {
        [self writeFrame:frame];
        if (reply) reply(@"ok");
    }
}

@end

static BOOL g_guardEnabled = YES;

static BOOL g_displayOn = YES;

static void ToggleDisplay(void) { g_displayOn = !g_displayOn; }

#import <objc/message.h>

static BOOL ScreenUsable(void) {
    BOOL locked = NO;
    id lockCtl = objc_getClass("SBLockStateController");
    if (lockCtl) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(lockCtl, @selector(sharedInstance));
        if (inst && [(id)inst respondsToSelector:@selector(isLocked)]) locked = ((BOOL(*)(id, SEL))objc_msgSend)(inst, @selector(isLocked));
    }
    if (locked) return NO;
    BOOL screenOn = g_displayOn;
    id blc = objc_getClass("SBBacklightController");
    if (blc) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(blc, @selector(sharedInstance));
        if (inst && [(id)inst respondsToSelector:@selector(backlightLevel)]) screenOn = (((float(*)(id, SEL))objc_msgSend)(inst, @selector(backlightLevel)) > 0);
    }
    return screenOn;
}

static void GuardTick(void) {
    if (!g_guardEnabled) return;
    if (ScreenUsable()) return;
    PWCentral *c = [PWCentral shared];
    if (c.periph || c.scanning) return;
    if (c.cm.state != CBManagerStatePoweredOn) return;
    [c.cm scanForPeripheralsWithServices:nil options:nil];
    c.scanning = YES;
    CLog(@"guard scan window");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (c.scanning) { [c.cm stopScan]; c.scanning = NO; }
    });
}

static void StartServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int sfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sfd < 0) { CLog(@"socket failed"); return; }
        int opt = 1;
        setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(18090);
        if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { CLog(@"bind failed"); close(sfd); return; }
        if (listen(sfd, 4) < 0) { CLog(@"listen failed"); close(sfd); return; }
        CLog(@"http server ready :18090");
        char buf[1024];
        for (;;) {
            int cfd = accept(sfd, NULL, NULL);
            if (cfd < 0) continue;
            memset(buf, 0, sizeof(buf));
            read(cfd, buf, sizeof(buf) - 1);
            CLog([NSString stringWithUTF8String:buf]);
            const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
            if (strstr(buf, "/cooler?on=1")) {
                [[PWCentral shared] requestState:YES reply:nil];
            } else if (strstr(buf, "/cooler?on=0")) {
                [[PWCentral shared] requestState:NO reply:nil];
            } else if (strstr(buf, "/guard?on=0")) {
                g_guardEnabled = NO;
                CLog(@"guard disabled");
            } else if (strstr(buf, "/guard?on=1")) {
                g_guardEnabled = YES;
                CLog(@"guard enabled");
            }
            write(cfd, resp, strlen(resp));
            close(cfd);
        }
    });
}

%ctor {
    %init;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)ToggleDisplay, CFSTR("com.apple.iokit.hid.displayStatus"), NULL, CFNotificationSuspensionBehaviorCoalesce);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CLog(@"ctl loaded");
        [PWCentral shared];
        StartServer();
        // 守护扫描窗口：每15秒扫3秒，仅锁屏时扫描（解锁时不打扰）
        dispatch_source_t guardTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(guardTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), 15ull * NSEC_PER_SEC, 2ull * NSEC_PER_SEC);
        dispatch_source_set_event_handler(guardTimer, ^{ GuardTick(); });
        dispatch_resume(guardTimer);
    });
}
