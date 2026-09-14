#import <CoreBluetooth/CoreBluetooth.h>
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

// 捕获的指令帧
// 2026-09-14 23:39 实测校准：打开=byte17为0x00，关闭=byte17为0x32
static const unsigned char ON_FRAME[]  = {0x20,0x01,0x16,0x00,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x03,0x01,0x00,0x01,0x02,0x22,0x01,0x01,0x00,0x5f};
static const unsigned char OFF_FRAME[] = {0x20,0x01,0x16,0x00,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x00,0x00,0x00,0xff,0x03,0x01,0x32,0x01,0x02,0x20,0x01,0x00,0x00,0x8e};
#define FRAME_LEN 26
static NSString * const SVC_UUID = @"49535343-FE7D-4AE5-8FA9-9FAFD205E455";
static NSString * const CHR_UUID = @"49535343-8841-43F4-A8D4-ECBE34729BB3";

@interface PWCentral : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (strong, nonatomic) CBCentralManager *cm;
@property (strong, nonatomic) CBPeripheral *periph;
@property (strong, nonatomic) CBCharacteristic *wchr;
@property (copy, nonatomic) void (^onReady)(BOOL ok);
+ (PWCentral *)shared;
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
        _cm = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        CLog(@"central init");
    }
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    CLog([NSString stringWithFormat:@"cm state=%ld", (long)central.state]);
    if (central.state == CBManagerStatePoweredOn && !self.periph) {
        [central scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@NO}];
        CLog(@"scanning ALL devices (diagnostic)");
    }
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    NSMutableString *line = [NSMutableString stringWithFormat:@"DISCOVERED name=%@ id=%@ rssi=%@", peripheral.name ?: @"(nil)", peripheral.identifier.UUIDString, RSSI];
    id su = advertisementData[CBAdvertiseDataServiceUUIDsKey];
    if (su) [line appendFormat:@" svc=%@", su];
    id mfg = advertisementData[CBAdvertiseDataManufacturerDataKey];
    if (mfg) [line appendFormat:@" mfg=%@", mfg];
    CLog(line);
    // 命中散热器（名字或广播含目标服务）才连接
    BOOL hit = NO;
    if (su && [su isKindOfClass:[NSArray class]]) {
        for (CBUUID *u in su) if ([u.UUIDString isEqualToString:SVC_UUID]) hit = YES;
    }
    NSString *nm = (peripheral.name ?: @"").lowercaseString;
    if ([nm containsString:@"b2max"] || [nm containsString:@"pw"] || [nm containsString:@"piva"] || [nm containsString:@"rypiva"] || [nm containsString:@"cooler"] || [nm containsString:@"散热"]) hit = YES;
    if (hit) {
        CLog(@"HIT target, connecting");
        self.periph = peripheral;
        peripheral.delegate = self;
        [central stopScan];
        [central connectPeripheral:peripheral options:nil];
    }
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    CLog(@"connect failed");
    self.periph = nil;
    if (self.onReady) { void (^cb)(BOOL) = self.onReady; self.onReady = nil; cb(NO); }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    CLog(@"connected, discovering services");
    [peripheral discoverServices:@[[CBUUID UUIDWithString:SVC_UUID]]];
}

- (void)peripheral:(CBPeripheral *)peripheral didDisconnectPeripheral:(NSError *)error {
    CLog(@"disconnected");
    self.wchr = nil;
    self.periph = nil;
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    for (CBService *svc in peripheral.services) {
        CLog([NSString stringWithFormat:@"service found %@", svc.UUID.UUIDString]);
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:CHR_UUID]] forService:svc];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID.UUIDString isEqualToString:CHR_UUID]) {
            self.wchr = c;
            CLog(@"write characteristic ready");
        }
    }
    if (self.wchr && self.onReady) { void (^cb)(BOOL) = self.onReady; self.onReady = nil; cb(YES); }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    CLog(error ? @"write err" : @"write ok");
}

- (void)requestState:(BOOL)on reply:(void (^)(NSString *line))reply {
    NSData *frame = [NSData dataWithBytes:(on ? ON_FRAME : OFF_FRAME) length:FRAME_LEN];
    if (!self.wchr) {
        CLog(@"not connected, connecting first");
        self.onReady = ^(BOOL ok) {
            if (ok) { [[PWCentral shared] writeFrame:frame]; reply(@"ok"); }
            else reply(@"connect failed");
        };
        if (self.cm.state == CBManagerStatePoweredOn && !self.periph) {
            [self.cm scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:SVC_UUID]] options:nil];
        }
    } else {
        [self writeFrame:frame];
        reply(@"ok");
    }
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

@end

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
                resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
            } else if (strstr(buf, "/cooler?on=0")) {
                [[PWCentral shared] requestState:NO reply:nil];
            } else if (strstr(buf, "/cooler/status")) {
                resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
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
        [PWCentral shared];
        StartServer();
    });
}
