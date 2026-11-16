#import <Foundation/Foundation.h>
#import <Clash/Clash.objc.h>

/// Main-app profile only. This platform never opens a TUN device.
@interface MihomoAppPlatform : NSObject <ClashPlatformInterface>
@end

FOUNDATION_EXPORT int MihomoFreeLoopbackPort(void);
