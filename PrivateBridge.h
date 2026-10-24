#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

// Private Core Animation declarations also used by ClearMenuBar 1.2.
// They are not stable OS APIs; stop before changing wallpaper if unavailable.
@interface CAFilter : NSObject
+ (nullable instancetype)filterWithType:(NSString *_Nonnull)type;
@property(copy) NSString *_Nonnull name;
@end

@interface CABackdropLayer : CALayer
@property BOOL allowsInPlaceFiltering;
@property BOOL disablesOccludedBackdropBlurs;
@property BOOL ignoresOffscreenGroups;
@property BOOL windowServerAware;
@property double scale;
@property double bleedAmount;
@end

extern NSString *const kCAFilterColorBrightness;
extern NSString *const kCAFilterColorContrast;
extern NSString *const kCAFilterColorInvert;
extern NSString *const kCAFilterColorHueRotate;
extern NSString *const kCAFilterMultiplyBlendMode;
extern NSString *const kCAFilterScreenBlendMode;
