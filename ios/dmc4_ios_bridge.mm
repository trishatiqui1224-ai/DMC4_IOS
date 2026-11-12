#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include "dmc4_ios_bridge.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

#ifndef DMC4_IOS_HAS_RUNTIME
#define DMC4_IOS_HAS_RUNTIME 0
#endif

#if DMC4_IOS_HAS_RUNTIME
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <mutex>
#include <system_error>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ui/windowed_app.h>
#include <rex/ui/windowed_app_context_sdl.h>

#include "../src/dmc4_ios_runtime.h"
#endif

// -----------------------------------------------------------------------------
// On-Screen Touch Virtual Controller Manager (iOS 15.0+)
// -----------------------------------------------------------------------------

API_AVAILABLE(ios(15.0))
@interface Dmc4VirtualControllerManager : NSObject
@property (nonatomic, strong) GCVirtualController* virtualController;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL isConnected;

+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;
- (void)refresh;
@end

@implementation Dmc4VirtualControllerManager

+ (instancetype)sharedInstance {
  static Dmc4VirtualControllerManager* instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[Dmc4VirtualControllerManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _isEnabled = NO;
    _isConnected = NO;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleWindowNotification:)
               name:UIWindowDidBecomeKeyNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleWindowNotification:(NSNotification*)notification {
  if (self.isEnabled && !self.isConnected) {
    [self start];
  }
}

- (void)start {
  self.isEnabled = YES;
  if (@available(iOS 15.0, *)) {
    if (self.isConnected && self.virtualController) {
      return;
    }
    GCVirtualControllerConfiguration* config =
        [[GCVirtualControllerConfiguration alloc] init];
    config.elements = [NSSet setWithObjects:
        GCInputLeftThumbstick,
        GCInputRightThumbstick,
        GCInputButtonA,
        GCInputButtonB,
        GCInputButtonX,
        GCInputButtonY,
        GCInputLeftShoulder,
        GCInputRightShoulder,
        GCInputLeftTrigger,
        GCInputRightTrigger,
        GCInputDirectionPad,
        GCInputButtonMenu,
        nil];

    self.virtualController =
        [GCVirtualController virtualControllerWithConfiguration:config];
    __weak typeof(self) weakSelf = self;
    [self.virtualController connectWithReplyHandler:^(NSError* _Nullable error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
          NSLog(@"[DMC4 Touch] GCVirtualController connection failed: %@",
                error.localizedDescription);
          strongSelf.isConnected = NO;
        } else {
          NSLog(@"[DMC4 Touch] GCVirtualController connected successfully with full layout (dual sticks, triggers, bumpers, d-pad, A/B/X/Y)");
          strongSelf.isConnected = YES;
        }
      });
    }];
  }
}

- (void)stop {
  self.isEnabled = NO;
  if (@available(iOS 15.0, *)) {
    if (self.virtualController) {
      [self.virtualController disconnect];
      self.virtualController = nil;
      self.isConnected = NO;
      NSLog(@"[DMC4 Touch] GCVirtualController disconnected");
    }
  }
}

- (void)refresh {
  if (self.isEnabled) {
    [self stop];
    [self start];
  }
}

@end

// -----------------------------------------------------------------------------
// C Bridge Functions for Touch Controls
// -----------------------------------------------------------------------------

extern "C" void dmc4_ios_set_touch_controls_enabled(bool enabled) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (enabled) {
      [[Dmc4VirtualControllerManager sharedInstance] start];
    } else {
      [[Dmc4VirtualControllerManager sharedInstance] stop];
    }
  });
}

extern "C" bool dmc4_ios_is_virtual_controller_active(void) {
  return [Dmc4VirtualControllerManager sharedInstance].isConnected;
}

// -----------------------------------------------------------------------------
// Diagnostics & Crash Handler Helpers
// -----------------------------------------------------------------------------

static void InstallCrashDiagnosticsHandler(const std::string& logs_dir) {
  static std::string s_logs_dir = logs_dir;
  NSSetUncaughtExceptionHandler([](NSException* exception) {
    NSLog(@"[DMC4 CRASH] Uncaught exception: %@ (reason: %@)\nCallStack:\n%@",
          exception.name, exception.reason,
          [exception.callStackSymbols componentsJoinedByString:@"\n"]);
    if (!s_logs_dir.empty()) {
      std::string path = s_logs_dir + "/crash_exception.txt";
      NSString* report = [NSString stringWithFormat:
          @"=== DMC4 iOS Crash Report ===\nDate: %@\nException: %@\nReason: %@\n\nCallStack:\n%@\n",
          [NSDate date], exception.name, exception.reason,
          [exception.callStackSymbols componentsJoinedByString:@"\n"]];
      [report writeToFile:[NSString stringWithUTF8String:path.c_str()]
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }
  });
}

namespace {

void WriteError(char* error_buf, int32_t error_buf_size, const char* message) {
  if (!error_buf || error_buf_size <= 0) {
    return;
  }
  if (!message) {
    error_buf[0] = '\0';
    return;
  }
  std::snprintf(error_buf, static_cast<size_t>(error_buf_size), "%s", message);
}

#if DMC4_IOS_HAS_RUNTIME
dmc4::ios::RuntimeLaunchOptions g_ios_launch_options;
std::mutex g_ios_launch_mutex;
#endif

}  // namespace

#if DMC4_IOS_HAS_RUNTIME
namespace dmc4::ios {

void SetLaunchOptions(const RuntimeLaunchOptions& options) {
  std::lock_guard<std::mutex> lock(g_ios_launch_mutex);
  g_ios_launch_options = options;
}

RuntimeLaunchOptions GetLaunchOptions() {
  std::lock_guard<std::mutex> lock(g_ios_launch_mutex);
  return g_ios_launch_options;
}

}  // namespace dmc4::ios
#endif

extern "C" bool dmc4_ios_runtime_available(void) {
#if DMC4_IOS_HAS_RUNTIME
  return true;
#else
  return false;
#endif
}

extern "C" bool dmc4_ios_launch(const Dmc4IosLaunchConfig* config,
                                char* error_buf,
                                int32_t error_buf_size) {
#if !DMC4_IOS_HAS_RUNTIME
  (void)config;
  WriteError(error_buf, error_buf_size,
             "Recompiled DMC4 runtime sources (build/recompiled) are not included in this build.");
  return false;
#else
  if (!config || !config->game_path || config->game_path[0] == '\0') {
    WriteError(error_buf, error_buf_size, "No Xbox 360 game folder or ISO path was provided.");
    return false;
  }

  dmc4::ios::RuntimeLaunchOptions options;
  options.game_path = config->game_path;
  if (config->user_data_dir) {
    options.user_data_dir = config->user_data_dir;
  }
  if (config->cache_dir) {
    options.cache_dir = config->cache_dir;
  }
  if (config->documents_dir) {
    options.documents_dir = config->documents_dir;
  }
  options.resolution_scale = std::clamp(config->resolution_scale, int32_t(1), int32_t(8));
  options.frame_rate = config->frame_rate > 0 ? config->frame_rate : 60;
  options.master_volume = std::clamp(config->master_volume, 0.0f, 1.0f);
  options.mute_audio = config->mute_audio;
  options.touch_controls = config->touch_controls;
  options.controller_vibration = config->controller_vibration;
  options.debug_logging = config->debug_logging;

  NSLog(@"[DMC4 Bridge] Launch requested: path=%s, scale=%d, fps=%d, touch=%d, debug_log=%d",
        options.game_path.c_str(), options.resolution_scale, options.frame_rate,
        options.touch_controls ? 1 : 0, options.debug_logging ? 1 : 0);

  std::error_code ec;
  if (!options.user_data_dir.empty()) {
    std::filesystem::create_directories(options.user_data_dir, ec);
  }
  if (!options.cache_dir.empty()) {
    std::filesystem::create_directories(options.cache_dir, ec);
  }
  if (!options.documents_dir.empty()) {
    auto logs_path = std::filesystem::path(options.documents_dir) / "logs";
    std::filesystem::create_directories(logs_path, ec);
    InstallCrashDiagnosticsHandler(logs_path.string());
  }

  dmc4::ios::SetLaunchOptions(options);

  // Activate on-screen touch controls if requested
  if (options.touch_controls) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[Dmc4VirtualControllerManager sharedInstance] start];
    });
  }

  static std::once_flag init_once;
  std::call_once(init_once, []() {
    char arg0[] = "DMC4";
    char* argv[] = {arg0, nullptr};
    rex::cvar::Init(1, argv);
    rex::cvar::ApplyEnvironment();
    rex::InitLoggingEarly();
    SDL_SetMainReady();
  });

  rex::ui::SDLWindowedAppContext app_context;
  if (!app_context.Initialize()) {
    WriteError(error_buf, error_buf_size, "Failed to initialize SDL3 UIKit video context.");
    dispatch_async(dispatch_get_main_queue(), ^{
      [[Dmc4VirtualControllerManager sharedInstance] stop];
    });
    return false;
  }

  auto creator = rex::ui::GetWindowedAppCreator();
  if (!creator) {
    WriteError(error_buf, error_buf_size, "DMC4 ReXApp creator is not registered.");
    dispatch_async(dispatch_get_main_queue(), ^{
      [[Dmc4VirtualControllerManager sharedInstance] stop];
    });
    return false;
  }

  std::unique_ptr<rex::ui::WindowedApp> app = creator(app_context);
  if (!app || !app->OnInitialize()) {
    if (app) {
      app->InvokeOnDestroy();
    }
    WriteError(error_buf, error_buf_size,
               "Failed to initialize DMC4 runtime or Vulkan/MoltenVK presentation.");
    dispatch_async(dispatch_get_main_queue(), ^{
      [[Dmc4VirtualControllerManager sharedInstance] stop];
    });
    return false;
  }

  NSLog(@"[DMC4 Bridge] Entering SDL3 main message loop...");
  const int exit_code = app_context.RunMainMessageLoop();
  NSLog(@"[DMC4 Bridge] Main message loop finished with exit code %d", exit_code);

  app->InvokeOnDestroy();

  dispatch_async(dispatch_get_main_queue(), ^{
    [[Dmc4VirtualControllerManager sharedInstance] stop];
  });

  if (exit_code != 0) {
    WriteError(error_buf, error_buf_size, "DMC4 runtime exited with a non-zero status.");
    return false;
  }
  return true;
#endif
}
