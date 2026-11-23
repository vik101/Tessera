// Adds a pretend second screen to a Mac, for testing Tessera with two displays on CI.
// Uses CoreGraphics' virtual display classes (the same ones apps like DeskPad use).
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/ci/vdisplay.m -o /tmp/vdisplay
//   /tmp/vdisplay 1920 1080 &                  # keeps the screen alive until killed
//   /tmp/vdisplay 5120 1440 7 -1600 -1440 &    # serial 7 (each screen needs its own), placed at x y
//                                              # (points, from the main screen's top-left; y goes down)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int width = argc > 1 ? (unsigned int)atoi(argv[1]) : 1920;
        unsigned int height = argc > 2 ? (unsigned int)atoi(argv[2]) : 1080;

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Tessera Test Display";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.sizeInMillimeters = CGSizeMake(width * 0.28, height * 0.28);
        descriptor.vendorID = 0x7E55;
        descriptor.productID = 0x0002;
        descriptor.serialNum = argc > 3 ? (unsigned int)atoi(argv[3]) : 0x0042;
        descriptor.terminationHandler = ^(id a, id b) { NSLog(@"virtual display ended"); };

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display) { fprintf(stderr, "could not create a virtual display\n"); return 1; }

        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 0;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
        if (![display applySettings:settings]) { fprintf(stderr, "could not apply settings\n"); return 1; }

        printf("virtual display %u: %ux%u\n", display.displayID, width, height);
        fflush(stdout);
        if (argc > 5) {
            // Let macOS set the screen up, then put it where we want it.
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            CGDisplayConfigRef config;
            CGBeginDisplayConfiguration(&config);
            CGConfigureDisplayOrigin(config, display.displayID, atoi(argv[4]), atoi(argv[5]));
            CGError error = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            CGRect bounds = CGDisplayBounds(display.displayID);
            printf("placed at %d %d: error %d, now %.0f %.0f\n", atoi(argv[4]), atoi(argv[5]), error, bounds.origin.x, bounds.origin.y);
            fflush(stdout);
        }
        [[NSRunLoop mainRunLoop] run];   // The screen lasts as long as this process.
    }
    return 0;
}
