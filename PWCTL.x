#import <CoreBluetooth/CoreBluetooth.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define PWCTL_LOG 0 // 定版：日志关闭；排障时改为1重新编译

static void CLog(NSString *msg) {
    if (!PWCTL_LOG) return;
    NSString *p = [[NSString alloc] initWithFormat:@"/var/mob%@/pw_ctl.log", @"ile"];
    FILE *f = fopen(p.UTF8String, "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[CTL %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

// 2026-09-14 23:39 校准：打开=byte17 0x00，关闭=byte17 0x32
static const unsigned char ON_FRAME[]  = {0x20,0x01,0x16,0x00,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x03,0x01,0x00,0x01,0x02,0x22,0x01,0x01,0x00,0x5f};
static const unsigned char OFF_FRAME[] = {0x20,0x01,0x16,0x00,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x03,0x01,0x32,0x01,0x02,0x20,0x01,0x00,0x00,0x8e};
#define FRAME_LEN 26
static NSString * const SVC_UUID = @"49535343-FE7D-4AE5-8FA9-9FAFD205E455";
static NSString * const CHR_UUID = @"49535343-8841-43F4-A8D4-ECBE34729BB3";

static id g_delegate = nil;
static NSString *g_initiator = @"?"; // 连接发起方：shortcut / lock-off
static BOOL g_guardEnabled = YES;

@interface PWCentral : NSObject
@property (strong, nonatomic) CBCentralManager *cm;
@property (strong, nonatomic) CBPeripheral *periph;
@property (strong, nonatomic) CBCharacteristic *wchr;
@property (strong, nonatomic) NSData *pendingFrame;   // 待写入帧（连接就绪后发出）
@property (copy, nonatomic) void (^pendingReply)(NSString *line);
@property (assign, nonatomic) BOOL scanning;
+ (PWCentral *)shared;
- (void)cmDidUpdateState:(CBCentralManager *)cm;
- (void)cmDidDiscover:(CBCentralManager *)cm p:(CBPeripheral *)p adv:(NSDictionary *)adv rssi:(NSNumber *)rssi;
- (void)cmDidConnect:(CBCentralManager *)cm p:(CBPeripheral *)p;
- (void)cmDidFail:(CBCentralManager *)cm p:(CBPeripheral *)p;
- (void)cmDidDisconnect:(CBCentralManager *)cm p:(CBPeripheral *)p;
- (void)pDidDiscoverServices:(CBPeripheral *)p;
- (void)pDidDiscoverChars:(CBPeripheral *)p;
- (void)scanWindow;
- (void)writeFrame:(NSData *)d;
- (void)requestState:(BOOL)on reply:(void (^)(NSString *line))reply;
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
        _cm = [[CBCentralManager alloc] initWithDelegate:g_delegate queue:nil];
        CLog(@"central init");
    }
    return self;
}

- (void)cmDidUpdateState:(CBCentralManager *)central {
    CLog([NSString stringWithFormat:@"cm state=%ld", (long)central.state]);
}

- (void)cmDidDiscover:(CBCentralManager *)central p:(CBPeripheral *)peripheral adv:(NSDictionary *)adv rssi:(NSNumber *)RSSI {
    NSString *nm = (peripheral.name ?: @"").lowercaseString;
    if (![nm containsString:@"b2max"]) return;
    CLog([NSString stringWithFormat:@"discovered B2MAX via %@ rssi=%@", g_initiator, RSSI]);
    if (self.periph) return;
    self.periph = peripheral;
    peripheral.delegate = g_delegate;
    [central stopScan];
    self.scanning = NO;
    [central connectPeripheral:peripheral options:nil];
    CLog([NSString stringWithFormat:@"connecting via %@", g_initiator]);
}

- (void)cmDidFail:(CBCentralManager *)central p:(CBPeripheral *)peripheral {
    CLog(@"connect failed");
    self.periph = nil;
}

- (void)cmDidConnect:(CBCentralManager *)central p:(CBPeripheral *)peripheral {
    CLog([NSString stringWithFormat:@"connected via %@", g_initiator]);
    [peripheral discoverServices:@[[CBUUID UUIDWithString:SVC_UUID]]];
}

- (void)cmDidDisconnect:(CBCentralManager *)cm p:(CBPeripheral *)peripheral {
    CLog(@"disconnected");
    self.wchr = nil;
    self.periph = nil;
}

- (void)pDidDiscoverServices:(CBPeripheral *)peripheral {
    CLog(@"services discovered");
    [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:CHR_UUID]] forService:peripheral.services.firstObject];
}

- (void)pDidDiscoverChars:(CBPeripheral *)peripheral {
    for (CBService *svc in peripheral.services) {
        for (CBCharacteristic *c in svc.characteristics) {
            if ([c.UUID.UUIDString isEqualToString:CHR_UUID]) {
                self.wchr = c;
                CLog(@"write characteristic ready");
            }
        }
    }
    if (self.wchr && self.pendingFrame) {
        NSData *f = self.pendingFrame; self.pendingFrame = nil;
        [self writeFrame:f];
    }
    if (self.wchr && self.pendingReply) {
        void (^r)(NSString *) = self.pendingReply; self.pendingReply = nil;
        r(@"ok");
    }
}

- (void)scanWindow {
    if (self.periph || self.scanning) return;
    if (self.cm.state != CBManagerStatePoweredOn) return;
    [self.cm scanForPeripheralsWithServices:nil options:nil];
    self.scanning = YES;
    CLog(@"scan window");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (PWCentral.shared.scanning) { [PWCentral.shared.cm stopScan]; PWCentral.shared.scanning = NO; }
    });
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

- (void)requestState:(BOOL)on reply:(void (^)(NSString *line))reply {
    g_initiator = @"shortcut";
    NSData *frame = [NSData dataWithBytes:(on ? ON_FRAME : OFF_FRAME) length:FRAME_LEN];
    if (!self.wchr) {
        CLog(@"not connected, connecting first");
        self.pendingFrame = frame;
        self.pendingReply = reply;
        [self scanWindow];
    } else {
        [self writeFrame:frame];
        if (reply) reply(@"ok");
    }
}

@end

static Class BuildDelegateClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_allocateClassPair([NSObject class], "PWBleDelegate", 0);
        class_addMethod(cls, @selector(centralManagerDidUpdateState:), imp_implementationWithBlock(^(id s, CBCentralManager *cm){ [[PWCentral shared] cmDidUpdateState:cm]; }), "v@:@");
        class_addMethod(cls, @selector(centralManager:didDiscoverPeripheral:advertisementData:RSSI:), imp_implementationWithBlock(^(id s, CBCentralManager *cm, CBPeripheral *p, NSDictionary *adv, NSNumber *rssi){ [[PWCentral shared] cmDidDiscover:cm p:p adv:adv rssi:rssi]; }), "v@:@@@@");
        class_addMethod(cls, @selector(centralManager:didConnectPeripheral:), imp_implementationWithBlock(^(id s, CBCentralManager *cm, CBPeripheral *p){ [[PWCentral shared] cmDidConnect:cm p:p]; }), "v@:@@");
        class_addMethod(cls, @selector(centralManager:didFailToConnectPeripheral:error:), imp_implementationWithBlock(^(id s, CBCentralManager *cm, CBPeripheral *p, NSError *e){ [[PWCentral shared] cmDidFail:cm p:p]; }), "v@:@@@");
        class_addMethod(cls, @selector(centralManager:didDisconnectPeripheral:error:), imp_implementationWithBlock(^(id s, CBCentralManager *cm, CBPeripheral *p, NSError *e){ [[PWCentral shared] cmDidDisconnect:cm p:p]; }), "v@:@@@");
        class_addMethod(cls, @selector(centralManager:willRestoreState:), imp_implementationWithBlock(^(id s, CBCentralManager *cm, NSDictionary *st){ }), "v@:@");
        class_addMethod(cls, @selector(peripheral:didDiscoverServices:), imp_implementationWithBlock(^(id s, CBPeripheral *p, NSError *e){ [[PWCentral shared] pDidDiscoverServices:p]; }), "v@:@@@");
        class_addMethod(cls, @selector(peripheral:didDiscoverIncludedServicesForService:error:), imp_implementationWithBlock(^(id s, CBPeripheral *p, CBService *svc, NSError *e){ }), "v@:@@@");
        class_addMethod(cls, @selector(peripheral:didDiscoverCharacteristicsForService:error:), imp_implementationWithBlock(^(id s, CBPeripheral *p, CBService *svc, NSError *e){ [[PWCentral shared] pDidDiscoverChars:p]; }), "v@:@@@");
        class_addMethod(cls, @selector(peripheral:didUpdateValueForCharacteristic:error:), imp_implementationWithBlock(^(id s, CBPeripheral *p, CBCharacteristic *c, NSError *e){ }), "v@:@@@");
        class_addMethod(cls, @selector(peripheral:didWriteValueForCharacteristic:error:), imp_implementationWithBlock(^(id s, CBPeripheral *p, CBCharacteristic *c, NSError *e){ CLog(e ? @"write err" : @"write ok"); }), "v@:@@@");
        class_addMethod(cls, @selector(peripheral:didUpdateNotificationStateForCharacteristic:error:), imp_implementationWithBlock(^(id s, CBPeripheral *p, CBCharacteristic *c, NSError *e){ }), "v@:@@@");
        class_addMethod(cls, @selector(peripheral:didReadRSSI:error:), imp_implementationWithBlock(^(id s, CBPeripheral *p, NSNumber *rssi, NSError *e){ }), "v@:@@");
        class_addMethod(cls, @selector(peripheral:didModifyServices:), imp_implementationWithBlock(^(id s, CBPeripheral *p, NSArray *inv){ }), "v@:@");
        objc_registerClassPair(cls);
    });
    return cls;
}

#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

// 触发条件（v2.8.1 状态机）：
//   锁屏事件 → 关
//   接电事件 + 当前锁屏 → 关（覆盖"已锁屏时散热器得电自启"场景）
//   解锁 + 接电 → 忽略
//   快捷指令 → 直写对应帧
static void LockStateChanged(void) {
    if (!g_guardEnabled) return;
    BOOL locked = NO;
    id lockCtl = objc_getClass("SBLockStateController");
    if (lockCtl) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(lockCtl, @selector(sharedInstance));
        if (inst && [(id)inst respondsToSelector:@selector(isLocked)]) locked = ((BOOL(*)(id, SEL))objc_msgSend)(inst, @selector(isLocked));
    }
    if (!locked) return; // 解锁动作不处理
    g_initiator = @"lock-off";
    CLog(@"locked -> cooler OFF");
    ForceOffNow();
}

static void ForceOffNow(void) {
    PWCentral *c = [PWCentral shared];
    NSData *off = [NSData dataWithBytes:OFF_FRAME length:FRAME_LEN];
    if (c.wchr) {
        [c writeFrame:off];
    } else {
        c.pendingFrame = off;
        [c scanWindow];
    }
}

static void PowerConnectedEvent(void) {
    if (!g_guardEnabled) return;
    BOOL locked = NO;
    id lockCtl = objc_getClass("SBLockStateController");
    if (lockCtl) {
        id inst = ((id(*)(id, SEL))objc_msgSend)(lockCtl, @selector(sharedInstance));
        if (inst && [(id)inst respondsToSelector:@selector(isLocked)]) locked = ((BOOL(*)(id, SEL))objc_msgSend)(inst, @selector(isLocked));
    }
    if (!locked) { CLog(@"power event while unlocked, ignore"); return; } // 解锁+接电=忽略
    g_initiator = @"power-off";
    CLog(@"power event while locked -> OFF");
    ForceOffNow();
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CLog(@"ctl loaded");
        g_delegate = [[BuildDelegateClass() alloc] init];
        [PWCentral shared];
        StartServer();
        // 锁屏事件 → 关；接电事件+锁屏 → 关
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)LockStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFRunLoopSourceRef iopsSrc = IOPSNotificationCreateRunLoopSource((IOPowerSourceCallbackType)PowerConnectedEvent, NULL);
        if (iopsSrc) { CFRunLoopAddSource(CFRunLoopGetMain(), iopsSrc, kCFRunLoopDefaultMode); CFRelease(iopsSrc); }
        CLog(@"guard armed: lock->off, power+locked->off");
    });
}
