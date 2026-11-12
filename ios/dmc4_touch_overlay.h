#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Dmc4TouchOverlayView : UIView

@property (nonatomic, assign) CGFloat controlsAlpha;
@property (nonatomic, assign) BOOL isHiddenByUser;

- (void)cycleOpacity;
- (void)setOverlayHidden:(BOOL)hidden;

@end

@interface Dmc4TouchOverlayManager : NSObject

+ (instancetype)sharedInstance;
+ (void)showOverlay;
+ (void)hideOverlay;
+ (void)toggleOverlayVisibility;
+ (BOOL)isOverlayVisible;

@end

NS_ASSUME_NONNULL_END

