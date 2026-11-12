#import "dmc4_touch_overlay.h"

#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <cmath>
#include <unordered_map>

#include "dmc4_touch_state.h"

// Xbox 360 controller button bitmasks (matching rex::input)
static constexpr uint16_t kXInputDpadUp = 0x0001;
static constexpr uint16_t kXInputDpadDown = 0x0002;
static constexpr uint16_t kXInputDpadLeft = 0x0004;
static constexpr uint16_t kXInputDpadRight = 0x0008;
static constexpr uint16_t kXInputStart = 0x0010;
static constexpr uint16_t kXInputBack = 0x0020;
static constexpr uint16_t kXInputLeftThumb = 0x0040;
static constexpr uint16_t kXInputRightThumb = 0x0080;
static constexpr uint16_t kXInputLeftShoulder = 0x0100;
static constexpr uint16_t kXInputRightShoulder = 0x0200;
static constexpr uint16_t kXInputA = 0x1000;
static constexpr uint16_t kXInputB = 0x2000;
static constexpr uint16_t kXInputX = 0x4000;
static constexpr uint16_t kXInputY = 0x8000;

typedef NS_ENUM(NSInteger, Dmc4TouchTarget) {
  kDmc4TargetNone = 0,
  kDmc4TargetLeftStick,
  kDmc4TargetRightStick,
  kDmc4TargetButtonA,
  kDmc4TargetButtonB,
  kDmc4TargetButtonX,
  kDmc4TargetButtonY,
  kDmc4TargetDpadUp,
  kDmc4TargetDpadDown,
  kDmc4TargetDpadLeft,
  kDmc4TargetDpadRight,
  kDmc4TargetLB,
  kDmc4TargetRB,
  kDmc4TargetLT,
  kDmc4TargetRT,
  kDmc4TargetStart,
  kDmc4TargetBack,
  kDmc4TargetToggle,
  kDmc4TargetRestorePill
};

@interface Dmc4TouchOverlayView () {
  UIView* _containerView;
  UIView* _leftStickBase;
  UIView* _leftStickKnob;
  UIView* _rightStickBase;
  UIView* _rightStickKnob;

  UIView* _btnA;
  UIView* _btnB;
  UIView* _btnX;
  UIView* _btnY;

  UIView* _btnDpadUp;
  UIView* _btnDpadDown;
  UIView* _btnDpadLeft;
  UIView* _btnDpadRight;

  UIView* _btnLB;
  UIView* _btnRB;
  UIView* _btnLT;
  UIView* _btnRT;

  UIView* _btnStart;
  UIView* _btnBack;
  UIView* _btnToggle;
  UIView* _restorePill;

  NSMutableArray<UIView*>* _allButtons;
  std::unordered_map<uintptr_t, Dmc4TouchTarget> _activeTouches;

  CGPoint _leftStickCenter;
  CGPoint _rightStickCenter;
  CGFloat _leftStickRadius;
  CGFloat _rightStickRadius;

  UIImpactFeedbackGenerator* _lightHaptic;
  UIImpactFeedbackGenerator* _mediumHaptic;
  UIImpactFeedbackGenerator* _heavyHaptic;
  CADisplayLink* _hapticLink;

  NSInteger _opacityStep;
}
@end

@implementation Dmc4TouchOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.multipleTouchEnabled = YES;
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _controlsAlpha = 1.0f;
    _opacityStep = 0;
    _leftStickRadius = 60.0f;
    _rightStickRadius = 48.0f;
    _allButtons = [[NSMutableArray alloc] init];

    _containerView = [[UIView alloc] initWithFrame:self.bounds];
    _containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _containerView.backgroundColor = [UIColor clearColor];
    [self addSubview:_containerView];

    [self setupControls];
    [self setupHaptics];
  }
  return self;
}

- (void)dealloc {
  [_hapticLink invalidate];
  [_hapticLink release];
  [_lightHaptic release];
  [_mediumHaptic release];
  [_heavyHaptic release];

  [_containerView release];
  [_leftStickBase release];
  [_leftStickKnob release];
  [_rightStickBase release];
  [_rightStickKnob release];

  [_btnA release];
  [_btnB release];
  [_btnX release];
  [_btnY release];
  [_btnDpadUp release];
  [_btnDpadDown release];
  [_btnDpadLeft release];
  [_btnDpadRight release];
  [_btnLB release];
  [_btnRB release];
  [_btnLT release];
  [_btnRT release];
  [_btnStart release];
  [_btnBack release];
  [_btnToggle release];
  [_restorePill release];
  [_allButtons release];

  [super dealloc];
}

- (void)setupHaptics {
  _lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
  _mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
  _heavyHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
  [_lightHaptic prepare];
  [_mediumHaptic prepare];
  [_heavyHaptic prepare];

  _hapticLink = [[CADisplayLink displayLinkWithTarget:self selector:@selector(pollHapticRumble:)] retain];
  [_hapticLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)pollHapticRumble:(CADisplayLink*)link {
  (void)link;
  uint8_t haptic = dmc4::touch::ConsumeHapticFeedback();
  if (haptic == 1) {
    [_lightHaptic impactOccurred];
  } else if (haptic == 2) {
    [_mediumHaptic impactOccurred];
  } else if (haptic == 3) {
    [_heavyHaptic impactOccurred];
  }
}

- (UIView*)createButtonWithTitle:(NSString*)title
                     accentColor:(UIColor*)accent
                             tag:(NSInteger)tag
                    cornerRadius:(CGFloat)radius {
  UIView* v = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
  v.tag = tag;
  v.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.50f];
  v.layer.cornerRadius = radius;
  v.layer.borderWidth = 1.5f;
  v.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.35f].CGColor;
  v.clipsToBounds = YES;

  UILabel* label = [[[UILabel alloc] initWithFrame:v.bounds] autorelease];
  label.tag = 101;
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  label.text = title;
  label.textColor = accent;
  label.textAlignment = NSTextAlignmentCenter;
  label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
  [v addSubview:label];

  [_containerView addSubview:v];
  [_allButtons addObject:v];
  return [v retain];
}

- (void)setupControls {
  // Left Stick
  _leftStickBase = [[UIView alloc] initWithFrame:CGRectZero];
  _leftStickBase.backgroundColor = [UIColor colorWithWhite:0.10f alpha:0.35f];
  _leftStickBase.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.30f].CGColor;
  _leftStickBase.layer.borderWidth = 1.5f;
  _leftStickBase.layer.cornerRadius = _leftStickRadius;
  [_containerView addSubview:_leftStickBase];

  _leftStickKnob = [[UIView alloc] initWithFrame:CGRectZero];
  _leftStickKnob.backgroundColor = [UIColor colorWithWhite:0.85f alpha:0.65f];
  _leftStickKnob.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.45f].CGColor;
  _leftStickKnob.layer.borderWidth = 1.5f;
  _leftStickKnob.layer.cornerRadius = 26.0f;
  [_containerView addSubview:_leftStickKnob];

  // Right Stick
  _rightStickBase = [[UIView alloc] initWithFrame:CGRectZero];
  _rightStickBase.backgroundColor = [UIColor colorWithWhite:0.10f alpha:0.30f];
  _rightStickBase.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.25f].CGColor;
  _rightStickBase.layer.borderWidth = 1.5f;
  _rightStickBase.layer.cornerRadius = _rightStickRadius;
  [_containerView addSubview:_rightStickBase];

  _rightStickKnob = [[UIView alloc] initWithFrame:CGRectZero];
  _rightStickKnob.backgroundColor = [UIColor colorWithWhite:0.80f alpha:0.60f];
  _rightStickKnob.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.40f].CGColor;
  _rightStickKnob.layer.borderWidth = 1.5f;
  _rightStickKnob.layer.cornerRadius = 22.0f;
  [_containerView addSubview:_rightStickKnob];

  // Action diamond
  UIColor* colorY = [UIColor colorWithRed:1.0f green:0.82f blue:0.20f alpha:0.95f];
  UIColor* colorB = [UIColor colorWithRed:0.96f green:0.28f blue:0.28f alpha:0.95f];
  UIColor* colorA = [UIColor colorWithRed:0.28f green:0.90f blue:0.38f alpha:0.95f];
  UIColor* colorX = [UIColor colorWithRed:0.28f green:0.64f blue:1.00f alpha:0.95f];

  _btnY = [self createButtonWithTitle:@"Y" accentColor:colorY tag:kDmc4TargetButtonY cornerRadius:26.0f];
  _btnB = [self createButtonWithTitle:@"B" accentColor:colorB tag:kDmc4TargetButtonB cornerRadius:26.0f];
  _btnA = [self createButtonWithTitle:@"A" accentColor:colorA tag:kDmc4TargetButtonA cornerRadius:26.0f];
  _btnX = [self createButtonWithTitle:@"X" accentColor:colorX tag:kDmc4TargetButtonX cornerRadius:26.0f];

  // D-Pad
  UIColor* colorDpad = [UIColor colorWithWhite:0.92f alpha:0.90f];
  _btnDpadUp = [self createButtonWithTitle:@"▲" accentColor:colorDpad tag:kDmc4TargetDpadUp cornerRadius:8.0f];
  _btnDpadDown = [self createButtonWithTitle:@"▼" accentColor:colorDpad tag:kDmc4TargetDpadDown cornerRadius:8.0f];
  _btnDpadLeft = [self createButtonWithTitle:@"◀" accentColor:colorDpad tag:kDmc4TargetDpadLeft cornerRadius:8.0f];
  _btnDpadRight = [self createButtonWithTitle:@"▶" accentColor:colorDpad tag:kDmc4TargetDpadRight cornerRadius:8.0f];

  // Shoulders & Triggers
  UIColor* colorShoulder = [UIColor colorWithRed:0.82f green:0.90f blue:1.00f alpha:0.90f];
  _btnLB = [self createButtonWithTitle:@"LB" accentColor:colorShoulder tag:kDmc4TargetLB cornerRadius:10.0f];
  _btnRB = [self createButtonWithTitle:@"RB" accentColor:colorShoulder tag:kDmc4TargetRB cornerRadius:10.0f];
  _btnLT = [self createButtonWithTitle:@"LT" accentColor:colorShoulder tag:kDmc4TargetLT cornerRadius:10.0f];
  _btnRT = [self createButtonWithTitle:@"RT" accentColor:colorShoulder tag:kDmc4TargetRT cornerRadius:10.0f];

  // System & Toggle
  UIColor* colorSystem = [UIColor colorWithWhite:0.85f alpha:0.85f];
  _btnBack = [self createButtonWithTitle:@"BACK" accentColor:colorSystem tag:kDmc4TargetBack cornerRadius:8.0f];
  _btnStart = [self createButtonWithTitle:@"START" accentColor:colorSystem tag:kDmc4TargetStart cornerRadius:8.0f];
  _btnToggle = [self createButtonWithTitle:@"👁" accentColor:colorSystem tag:kDmc4TargetToggle cornerRadius:8.0f];

  // Restore Pill (shown only when controls are completely hidden)
  _restorePill = [[UIView alloc] initWithFrame:CGRectZero];
  _restorePill.tag = kDmc4TargetRestorePill;
  _restorePill.backgroundColor = [UIColor colorWithWhite:0.15f alpha:0.40f];
  _restorePill.layer.cornerRadius = 14.0f;
  _restorePill.layer.borderWidth = 1.0f;
  _restorePill.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.25f].CGColor;
  _restorePill.hidden = YES;

  UILabel* pillLabel = [[[UILabel alloc] initWithFrame:_restorePill.bounds] autorelease];
  pillLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  pillLabel.text = @"🎮";
  pillLabel.textAlignment = NSTextAlignmentCenter;
  pillLabel.font = [UIFont systemFontOfSize:14];
  [_restorePill addSubview:pillLabel];
  [self addSubview:_restorePill];
}

- (void)layoutSubviews {
  [super layoutSubviews];

  UIEdgeInsets insets = UIEdgeInsetsZero;
  if (@available(iOS 11.0, *)) {
    insets = self.safeAreaInsets;
  }
  const CGFloat safeLeft = MAX(insets.left, 20.0f);
  const CGFloat safeRight = MAX(insets.right, 20.0f);
  const CGFloat safeTop = MAX(insets.top, 10.0f);
  const CGFloat safeBottom = MAX(insets.bottom, 12.0f);
  const CGFloat w = self.bounds.size.width;
  const CGFloat h = self.bounds.size.height;

  _containerView.frame = self.bounds;

  // Left Stick
  _leftStickCenter = CGPointMake(safeLeft + 85.0f, h - safeBottom - 85.0f);
  _leftStickBase.frame = CGRectMake(_leftStickCenter.x - _leftStickRadius,
                                    _leftStickCenter.y - _leftStickRadius,
                                    _leftStickRadius * 2.0f,
                                    _leftStickRadius * 2.0f);
  _leftStickKnob.frame = CGRectMake(_leftStickCenter.x - 26.0f,
                                    _leftStickCenter.y - 26.0f,
                                    52.0f, 52.0f);

  // Right Stick (Camera)
  _rightStickCenter = CGPointMake(w - safeRight - 185.0f, h - safeBottom - 75.0f);
  _rightStickBase.frame = CGRectMake(_rightStickCenter.x - _rightStickRadius,
                                     _rightStickCenter.y - _rightStickRadius,
                                     _rightStickRadius * 2.0f,
                                     _rightStickRadius * 2.0f);
  _rightStickKnob.frame = CGRectMake(_rightStickCenter.x - 22.0f,
                                     _rightStickCenter.y - 22.0f,
                                     44.0f, 44.0f);

  // D-Pad
  const CGFloat dpadCenterX = safeLeft + 85.0f;
  const CGFloat dpadCenterY = safeTop + 105.0f;
  _btnDpadUp.frame = CGRectMake(dpadCenterX - 18.0f, dpadCenterY - 50.0f, 36.0f, 32.0f);
  _btnDpadDown.frame = CGRectMake(dpadCenterX - 18.0f, dpadCenterY + 18.0f, 36.0f, 32.0f);
  _btnDpadLeft.frame = CGRectMake(dpadCenterX - 50.0f, dpadCenterY - 16.0f, 32.0f, 32.0f);
  _btnDpadRight.frame = CGRectMake(dpadCenterX + 18.0f, dpadCenterY - 16.0f, 32.0f, 32.0f);

  // Shoulders & Triggers
  _btnLT.frame = CGRectMake(safeLeft + 10.0f, safeTop + 12.0f, 58.0f, 34.0f);
  _btnLB.frame = CGRectMake(safeLeft + 78.0f, safeTop + 12.0f, 58.0f, 34.0f);

  _btnRB.frame = CGRectMake(w - safeRight - 136.0f, safeTop + 12.0f, 58.0f, 34.0f);
  _btnRT.frame = CGRectMake(w - safeRight - 68.0f, safeTop + 12.0f, 58.0f, 34.0f);

  // Center System Buttons
  const CGFloat midX = w * 0.5f;
  _btnBack.frame = CGRectMake(midX - 85.0f, safeTop + 10.0f, 52.0f, 30.0f);
  _btnToggle.frame = CGRectMake(midX - 24.0f, safeTop + 10.0f, 48.0f, 30.0f);
  _btnStart.frame = CGRectMake(midX + 33.0f, safeTop + 10.0f, 52.0f, 30.0f);

  // Restore Pill
  _restorePill.frame = CGRectMake(midX - 24.0f, safeTop + 6.0f, 48.0f, 28.0f);

  // Action Diamond (Y top, B right, A bottom, X left)
  const CGFloat actCenterX = w - safeRight - 80.0f;
  const CGFloat actCenterY = h - safeBottom - 105.0f;
  _btnY.frame = CGRectMake(actCenterX - 26.0f, actCenterY - 62.0f, 52.0f, 52.0f);
  _btnB.frame = CGRectMake(actCenterX + 36.0f, actCenterY - 26.0f, 52.0f, 52.0f);
  _btnA.frame = CGRectMake(actCenterX - 26.0f, actCenterY + 10.0f, 52.0f, 52.0f);
  _btnX.frame = CGRectMake(actCenterX - 62.0f, actCenterY - 26.0f, 52.0f, 52.0f);
}

- (void)cycleOpacity {
  static const CGFloat kOpacities[] = { 1.0f, 0.55f, 0.25f, 0.0f };
  _opacityStep = (_opacityStep + 1) % 4;
  CGFloat target = kOpacities[_opacityStep];

  [UIView animateWithDuration:0.2 animations:^{
    if (target <= 0.05f) {
      _containerView.alpha = 0.0f;
      _restorePill.hidden = NO;
      _restorePill.alpha = 0.75f;
    } else {
      _containerView.alpha = target;
      _restorePill.hidden = YES;
      _restorePill.alpha = 0.0f;
    }
  }];
}

- (void)setOverlayHidden:(BOOL)hidden {
  _isHiddenByUser = hidden;
  _containerView.hidden = hidden;
  _restorePill.hidden = !hidden;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
  (void)event;
  if (self.isHidden) {
    return nil;
  }

  if (!_restorePill.isHidden && CGRectContainsPoint(CGRectInset(_restorePill.frame, -10, -10), point)) {
    return self;
  }

  if (_containerView.alpha < 0.05f || _containerView.hidden) {
    return nil;
  }

  for (UIView* btn in _allButtons) {
    if (CGRectContainsPoint(CGRectInset(btn.frame, -12, -12), point)) {
      return self;
    }
  }

  if (CGRectContainsPoint(CGRectInset(_leftStickBase.frame, -25, -25), point) ||
      CGRectContainsPoint(CGRectInset(_rightStickBase.frame, -20, -20), point)) {
    return self;
  }

  return nil;
}

- (Dmc4TouchTarget)targetForPoint:(CGPoint)pt {
  if (!_restorePill.isHidden && CGRectContainsPoint(CGRectInset(_restorePill.frame, -10, -10), pt)) {
    return kDmc4TargetRestorePill;
  }

  if (_containerView.alpha < 0.05f || _containerView.hidden) {
    return kDmc4TargetNone;
  }

  for (UIView* btn in _allButtons) {
    if (CGRectContainsPoint(CGRectInset(btn.frame, -12, -12), pt)) {
      return (Dmc4TouchTarget)btn.tag;
    }
  }

  CGFloat distLeft = std::hypot(pt.x - _leftStickCenter.x, pt.y - _leftStickCenter.y);
  if (distLeft <= _leftStickRadius + 25.0f) {
    return kDmc4TargetLeftStick;
  }

  CGFloat distRight = std::hypot(pt.x - _rightStickCenter.x, pt.y - _rightStickCenter.y);
  if (distRight <= _rightStickRadius + 25.0f) {
    return kDmc4TargetRightStick;
  }

  return kDmc4TargetNone;
}

- (void)setButtonStateForTarget:(Dmc4TouchTarget)target pressed:(BOOL)pressed {
  UIView* buttonView = nil;
  uint16_t mask = 0;

  switch (target) {
    case kDmc4TargetButtonA:
      mask = kXInputA;
      buttonView = _btnA;
      break;
    case kDmc4TargetButtonB:
      mask = kXInputB;
      buttonView = _btnB;
      break;
    case kDmc4TargetButtonX:
      mask = kXInputX;
      buttonView = _btnX;
      break;
    case kDmc4TargetButtonY:
      mask = kXInputY;
      buttonView = _btnY;
      break;
    case kDmc4TargetDpadUp:
      mask = kXInputDpadUp;
      buttonView = _btnDpadUp;
      break;
    case kDmc4TargetDpadDown:
      mask = kXInputDpadDown;
      buttonView = _btnDpadDown;
      break;
    case kDmc4TargetDpadLeft:
      mask = kXInputDpadLeft;
      buttonView = _btnDpadLeft;
      break;
    case kDmc4TargetDpadRight:
      mask = kXInputDpadRight;
      buttonView = _btnDpadRight;
      break;
    case kDmc4TargetLB:
      mask = kXInputLeftShoulder;
      buttonView = _btnLB;
      break;
    case kDmc4TargetRB:
      mask = kXInputRightShoulder;
      buttonView = _btnRB;
      break;
    case kDmc4TargetLT:
      dmc4::touch::SetLeftTrigger(pressed ? 255 : 0);
      buttonView = _btnLT;
      break;
    case kDmc4TargetRT:
      dmc4::touch::SetRightTrigger(pressed ? 255 : 0);
      buttonView = _btnRT;
      break;
    case kDmc4TargetStart:
      mask = kXInputStart;
      buttonView = _btnStart;
      break;
    case kDmc4TargetBack:
      mask = kXInputBack;
      buttonView = _btnBack;
      break;
    default:
      break;
  }

  if (mask != 0) {
    dmc4::touch::SetButton(mask, pressed);
  }

  if (buttonView) {
    if (pressed) {
      buttonView.transform = CGAffineTransformMakeScale(0.92f, 0.92f);
      buttonView.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.45f];
    } else {
      buttonView.transform = CGAffineTransformIdentity;
      buttonView.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.50f];
    }
  }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  for (UITouch* touch in touches) {
    CGPoint pt = [touch locationInView:self];
    Dmc4TouchTarget target = [self targetForPoint:pt];
    if (target == kDmc4TargetNone) continue;

    _activeTouches[(uintptr_t)touch] = target;

    if (target == kDmc4TargetToggle || target == kDmc4TargetRestorePill) {
      [_lightHaptic impactOccurred];
      [self cycleOpacity];
      continue;
    }

    [_lightHaptic impactOccurred];

    if (target == kDmc4TargetLeftStick) {
      [self updateStick:_leftStickKnob center:_leftStickCenter radius:_leftStickRadius touchPoint:pt isLeft:YES];
    } else if (target == kDmc4TargetRightStick) {
      [self updateStick:_rightStickKnob center:_rightStickCenter radius:_rightStickRadius touchPoint:pt isLeft:NO];
    } else {
      [self setButtonStateForTarget:target pressed:YES];
    }
  }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  for (UITouch* touch in touches) {
    auto it = _activeTouches.find((uintptr_t)touch);
    if (it == _activeTouches.end()) continue;

    CGPoint pt = [touch locationInView:self];
    Dmc4TouchTarget target = it->second;

    if (target == kDmc4TargetLeftStick) {
      [self updateStick:_leftStickKnob center:_leftStickCenter radius:_leftStickRadius touchPoint:pt isLeft:YES];
    } else if (target == kDmc4TargetRightStick) {
      [self updateStick:_rightStickKnob center:_rightStickCenter radius:_rightStickRadius touchPoint:pt isLeft:NO];
    } else {
      // If finger slides significantly off button, temporarily release it
      UIView* btn = [self viewForTarget:target];
      if (btn) {
        BOOL inside = CGRectContainsPoint(CGRectInset(btn.frame, -16, -16), pt);
        [self setButtonStateForTarget:target pressed:inside];
      }
    }
  }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  (void)event;
  for (UITouch* touch in touches) {
    auto it = _activeTouches.find((uintptr_t)touch);
    if (it == _activeTouches.end()) continue;

    Dmc4TouchTarget target = it->second;
    _activeTouches.erase(it);

    if (target == kDmc4TargetLeftStick) {
      [UIView animateWithDuration:0.12 animations:^{
        _leftStickKnob.center = _leftStickCenter;
      }];
      dmc4::touch::SetLeftThumb(0, 0);
    } else if (target == kDmc4TargetRightStick) {
      [UIView animateWithDuration:0.12 animations:^{
        _rightStickKnob.center = _rightStickCenter;
      }];
      dmc4::touch::SetRightThumb(0, 0);
    } else if (target != kDmc4TargetToggle && target != kDmc4TargetRestorePill) {
      [self setButtonStateForTarget:target pressed:NO];
    }
  }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self touchesEnded:touches withEvent:event];
}

- (void)updateStick:(UIView*)knob
             center:(CGPoint)center
             radius:(CGFloat)radius
         touchPoint:(CGPoint)pt
             isLeft:(BOOL)isLeft {
  CGFloat dx = pt.x - center.x;
  CGFloat dy = pt.y - center.y;
  CGFloat dist = std::hypot(dx, dy);

  if (dist > radius) {
    dx = (dx / dist) * radius;
    dy = (dy / dist) * radius;
    dist = radius;
  }

  knob.center = CGPointMake(center.x + dx, center.y + dy);

  // Normalize to -1.0 .. 1.0 (deadzone 10%)
  CGFloat normDist = dist / radius;
  CGFloat normX = 0.0f;
  CGFloat normY = 0.0f;

  if (normDist > 0.10f) {
    CGFloat scaledDist = (normDist - 0.10f) / 0.90f;
    normX = (dx / dist) * scaledDist;
    normY = -(dy / dist) * scaledDist;  // Xbox 360 Y-axis: up is positive!
  }

  int16_t axisX = static_cast<int16_t>(std::clamp(normX * 32767.0f, -32768.0f, 32767.0f));
  int16_t axisY = static_cast<int16_t>(std::clamp(normY * 32767.0f, -32768.0f, 32767.0f));

  if (isLeft) {
    dmc4::touch::SetLeftThumb(axisX, axisY);
  } else {
    dmc4::touch::SetRightThumb(axisX, axisY);
  }
}

- (UIView*)viewForTarget:(Dmc4TouchTarget)target {
  for (UIView* btn in _allButtons) {
    if (btn.tag == target) return btn;
  }
  return nil;
}

@end

// -----------------------------------------------------------------------------
// Dmc4TouchOverlayManager Implementation
// -----------------------------------------------------------------------------

@interface Dmc4TouchOverlayManager ()
@property (nonatomic, retain) Dmc4TouchOverlayView* overlayView;
@property (nonatomic, assign) BOOL isEnabled;
@end

@implementation Dmc4TouchOverlayManager

+ (instancetype)sharedInstance {
  static Dmc4TouchOverlayManager* s_instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    s_instance = [[Dmc4TouchOverlayManager alloc] init];
  });
  return s_instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _isEnabled = NO;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleWindowNotification:)
               name:UIWindowDidBecomeKeyNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleWindowNotification:)
               name:UIWindowDidBecomeVisibleNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleWindowNotification:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_overlayView release];
  [super dealloc];
}

- (void)handleWindowNotification:(NSNotification*)notification {
  (void)notification;
  if (self.isEnabled) {
    [self attachOverlayToActiveWindow];
  }
}

- (void)attachOverlayToActiveWindow {
  UIWindow* targetWindow = nil;
  if (@available(iOS 13.0, *)) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]] &&
          scene.activationState == UISceneActivationStateForegroundActive) {
        UIWindowScene* ws = (UIWindowScene*)scene;
        for (UIWindow* w in ws.windows) {
          if (w.isKeyWindow || [NSStringFromClass([w.rootViewController class]) containsString:@"SDL"]) {
            targetWindow = w;
            break;
          }
        }
        if (targetWindow) break;
        if (!targetWindow && ws.windows.count > 0) {
          targetWindow = ws.windows.lastObject;
        }
      }
    }
  }

  if (!targetWindow) {
    targetWindow = UIApplication.sharedApplication.keyWindow;
  }

  if (!targetWindow) {
    NSLog(@"[DMC4 Touch] Warning: No active UIWindow found for touch overlay");
    return;
  }

  UIView* parent = targetWindow.rootViewController ? targetWindow.rootViewController.view : targetWindow;
  if (!parent) {
    parent = targetWindow;
  }

  if (!self.overlayView) {
    self.overlayView = [[[Dmc4TouchOverlayView alloc] initWithFrame:parent.bounds] autorelease];
  }

  if (self.overlayView.superview != parent) {
    [self.overlayView removeFromSuperview];
    self.overlayView.frame = parent.bounds;
    [parent addSubview:self.overlayView];
    NSLog(@"[DMC4 Touch] Attached Dmc4TouchOverlayView to %@", NSStringFromClass([parent class]));
  }

  [parent bringSubviewToFront:self.overlayView];
  self.overlayView.hidden = NO;
}

+ (void)showOverlay {
  Dmc4TouchOverlayManager* mgr = [Dmc4TouchOverlayManager sharedInstance];
  mgr.isEnabled = YES;
  [mgr attachOverlayToActiveWindow];
}

+ (void)hideOverlay {
  Dmc4TouchOverlayManager* mgr = [Dmc4TouchOverlayManager sharedInstance];
  mgr.isEnabled = NO;
  if (mgr.overlayView) {
    [mgr.overlayView removeFromSuperview];
    mgr.overlayView = nil;
  }
  dmc4::touch::ResetTouchGamepad();
}

+ (void)toggleOverlayVisibility {
  Dmc4TouchOverlayManager* mgr = [Dmc4TouchOverlayManager sharedInstance];
  if (mgr.overlayView) {
    [mgr.overlayView cycleOpacity];
  }
}

+ (BOOL)isOverlayVisible {
  Dmc4TouchOverlayManager* mgr = [Dmc4TouchOverlayManager sharedInstance];
  return mgr.isEnabled && mgr.overlayView != nil && !mgr.overlayView.isHidden;
}

@end
