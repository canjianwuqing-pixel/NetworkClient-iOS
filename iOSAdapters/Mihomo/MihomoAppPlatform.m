#import "MihomoAppPlatform.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>

@interface MihomoStringIterator : NSObject <ClashStringIterator>
- (instancetype)initWithValues:(NSArray<NSString *> *)values;
@end

@implementation MihomoStringIterator {
    NSArray<NSString *> *_values;
    NSUInteger _index;
}
- (instancetype)initWithValues:(NSArray<NSString *> *)values {
    if ((self = [super init])) _values = [values copy];
    return self;
}
- (BOOL)hasNext { return _index < _values.count; }
- (int32_t)len { return (int32_t)MIN(_values.count, INT32_MAX); }
- (NSString *)next { return [self hasNext] ? _values[_index++] : @""; }
@end

@interface MihomoNetworkInterfaceIterator : NSObject <ClashNetworkInterfaceIterator>
- (instancetype)initWithValues:(NSArray<ClashNetworkInterface *> *)values;
@end

@implementation MihomoNetworkInterfaceIterator {
    NSArray<ClashNetworkInterface *> *_values;
    NSUInteger _index;
}
- (instancetype)initWithValues:(NSArray<ClashNetworkInterface *> *)values {
    if ((self = [super init])) _values = [values copy];
    return self;
}
- (BOOL)hasNext { return _index < _values.count; }
- (int32_t)len { return (int32_t)MIN(_values.count, INT32_MAX); }
- (ClashNetworkInterface *)next { return [self hasNext] ? _values[_index++] : nil; }
@end

static NSString *MihomoNumericAddress(const struct sockaddr *address) {
    if (address == NULL || (address->sa_family != AF_INET && address->sa_family != AF_INET6)) return nil;
    char host[NI_MAXHOST] = {0};
    if (getnameinfo(address, address->sa_len, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) return nil;
    NSString *value = [NSString stringWithUTF8String:host];
    return [value componentsSeparatedByString:@"%"].firstObject;
}

static id<ClashNetworkInterfaceIterator> MihomoCurrentInterfaces(void) {
    struct ifaddrs *start = NULL;
    if (getifaddrs(&start) != 0 || start == NULL) {
        return [[MihomoNetworkInterfaceIterator alloc] initWithValues:@[]];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *records = [NSMutableDictionary dictionary];
    for (struct ifaddrs *entry = start; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_name == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:entry->ifa_name];
        NSMutableDictionary *record = records[name];
        if (record == nil) {
            record = [@{ @"flags": @0, @"mtu": @0, @"addresses": [NSMutableArray array] } mutableCopy];
            records[name] = record;
            [order addObject:name];
        }
        record[@"flags"] = @([record[@"flags"] unsignedIntValue] | entry->ifa_flags);
        if ([record[@"mtu"] intValue] == 0 && entry->ifa_data != NULL) {
            record[@"mtu"] = @(((const struct if_data *)entry->ifa_data)->ifi_mtu);
        }
        NSString *address = MihomoNumericAddress(entry->ifa_addr);
        NSMutableArray<NSString *> *addresses = record[@"addresses"];
        if (address != nil && ![addresses containsObject:address]) [addresses addObject:address];
    }
    freeifaddrs(start);

    NSMutableArray<ClashNetworkInterface *> *values = [NSMutableArray array];
    for (NSString *name in order) {
        unsigned int index = if_nametoindex(name.UTF8String);
        if (index == 0 || index > INT32_MAX) continue;
        NSDictionary *record = records[name];
        unsigned int systemFlags = [record[@"flags"] unsignedIntValue];
        int32_t flags = 0;
        if (systemFlags & IFF_UP) flags |= 1;
        if (systemFlags & IFF_BROADCAST) flags |= 2;
        if (systemFlags & IFF_LOOPBACK) flags |= 4;
        if (systemFlags & IFF_POINTOPOINT) flags |= 8;
        if (systemFlags & IFF_MULTICAST) flags |= 16;
        if (systemFlags & IFF_RUNNING) flags |= 32;
        if ((systemFlags & IFF_UP) && (systemFlags & IFF_RUNNING)) flags |= (1 << 8);

        int32_t type = 0;
        BOOL metered = NO;
        if ((systemFlags & IFF_LOOPBACK) || [name hasPrefix:@"lo"]) type = 4;
        else if ([name hasPrefix:@"pdp_ip"]) { type = 2; metered = YES; }
        else if ([name hasPrefix:@"utun"] || [name hasPrefix:@"ipsec"]) { type = 5; flags |= (1 << 10); }

        ClashNetworkInterface *value = [ClashNetworkInterface new];
        value.name = name;
        value.index = (int32_t)index;
        value.mtu = [record[@"mtu"] intValue];
        value.addresses = [[MihomoStringIterator alloc] initWithValues:record[@"addresses"]];
        value.flags = flags;
        value.type = type;
        value.metered = metered;
        [values addObject:value];
    }
    return [[MihomoNetworkInterfaceIterator alloc] initWithValues:values];
}

@implementation MihomoAppPlatform
- (BOOL)autoDetectInterfaceControl:(int32_t)fd error:(NSError **)error { return NO; }
- (BOOL)closeDefaultInterfaceMonitor:(id<ClashInterfaceUpdateListener>)listener error:(NSError **)error { return YES; }
- (id<ClashNetworkInterfaceIterator>)getInterfaces:(NSError **)error { return MihomoCurrentInterfaces(); }
- (BOOL)openTun:(id<ClashTunOptions>)options ret0_:(int32_t *)ret0_ error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"MihomoApp.NoTunnel" code:1 userInfo:nil];
    return NO;
}
- (BOOL)startDefaultInterfaceMonitor:(id<ClashInterfaceUpdateListener>)listener error:(NSError **)error { return YES; }
- (BOOL)underNetworkExtension { return NO; }
- (BOOL)usePlatformAutoDetectInterfaceControl { return NO; }
- (void)writeLog:(NSString *)message { /* SDK text may contain secrets; discard it. */ }
@end

int MihomoFreeLoopbackPort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return 0; }
    socklen_t length = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) { close(fd); return 0; }
    int port = ntohs(address.sin_port);
    close(fd);
    return port;
}
