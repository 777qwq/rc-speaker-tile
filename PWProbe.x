#import <CoreBluetooth/CoreBluetooth.h>
#import <UIKit/UIKit.h>
#include <stdio.h>

static void PLog(NSString *msg) {
    NSString *p = [[NSString alloc] initWithFormat:@"/var/mob%@/pw_probe.log", @"ile"];
    FILE *f = fopen(p.UTF8String, "a");
    if (!f) {
        NSString *alt = [[NSString alloc] initWithFormat:@"%@pw_probe_%@.log", NSTemporaryDirectory(), [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"];
        f = fopen(alt.UTF8String, "a");
    }
    if (!f) return;
    fseek(f, 0, SEEK_END);
    if (ftell(f) > 200 * 1024) { fclose(f); f = fopen(p.UTF8String, "w"); if (!f) return; }
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[PW %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

static NSString *HexOf(NSData *d) {
    if (!d || d.length == 0) return @"(empty)";
    const unsigned char *b = (const unsigned char *)d.bytes;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < d.length && i < 32; i++) [s appendFormat:@"%02x ", b[i]];
    if (d.length > 32) [s appendFormat:@"... (%lu bytes)", (unsigned long)d.length];
    return s;
}

%hook CBPeripheral
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)characteristic type:(CBCharacteristicWriteType)type {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSString *svc = characteristic.service.UUID.UUIDString ?: @"?";
    NSString *chr = characteristic.UUID.UUIDString ?: @"?";
    PLog([NSString stringWithFormat:@"bid=%@ WRITE svc=%@ chr=%@ type=%lu data=%@", bid, svc, chr, (unsigned long)type, HexOf(data)]);
    %orig;
}
%end

%ctor {
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    PLog([NSString stringWithFormat:@"probe loaded, bid=%@", bid ?: @"(null)"]);
}
