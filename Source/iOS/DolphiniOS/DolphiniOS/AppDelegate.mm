// Copyright 2019 Dolphin Emulator Project
// Licensed under GPLv2+
// Refer to the license.txt file included.

#import <AppCenter/AppCenter.h>
#import <AppCenterAnalytics/AppCenterAnalytics.h>
#import <AppCenterCrashes/AppCenterCrashes.h>

#import "AnalyticsNoticeViewController.h"

#import "AppDelegate.h"

#import "Common/Config/Config.h"
#import "Common/FileUtil.h"
#import "Common/IniFile.h"
#import "Common/MsgHandler.h"
#import "Common/StringUtil.h"

#import "Core/Config/MainSettings.h"
#import "Core/ConfigManager.h"
#import "Core/Core.h"
#import "Core/HW/GCKeyboard.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/Wiimote.h"
#import "Core/PowerPC/PowerPC.h"
#import "Core/State.h"

#import "DolphiniOS-Swift.h"

#import "DonationNoticeViewController.h"

#import "InputCommon/ControllerInterface/ControllerInterface.h"

#import "InvalidCpuCoreNoticeViewController.h"

#import <Keys/DolphiniOSKeys.h>

#import "MainiOS.h"

#import <MetalKit/MetalKit.h>

#import "NoticeNavigationViewController.h"

#import "ReloadFailedNoticeViewController.h"
#import "ReloadStateNoticeViewController.h"

#import "UICommon/UICommon.h"

#import "UnofficialBuildNoticeViewController.h"

#import "UpdateNoticeViewController.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
  // Check the device compatibility
#ifndef SUPPRESS_UNSUPPORTED_DEVICE
  // Provide a way to bypass this check for debugging purposes
  NSString* bypass_flag_file = [[MainiOS getUserFolder] stringByAppendingPathComponent:@"bypass_unsupported_device"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:bypass_flag_file])
  {
    // Check for GPU Family 3
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    if (![metalDevice supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily3_v2])
    {
      // Show the incompatibilty warning
      self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
      self.window.rootViewController = [[UIViewController alloc] initWithNibName:@"UnsupportedDeviceNotice" bundle:nil];
      [self.window makeKeyAndVisible];
      
      return true;
    }
  }
#endif
  
  // Default settings values should be set in DefaultPreferences.plist in the future
  NSURL *defaultPrefsFile = [[NSBundle mainBundle] URLForResource:@"DefaultPreferences" withExtension:@"plist"];
  NSDictionary *defaultPrefs = [NSDictionary dictionaryWithContentsOfURL:defaultPrefsFile];
  [[NSUserDefaults standardUserDefaults] registerDefaults:defaultPrefs];
  
  Common::RegisterStringTranslator([](const char* text) -> std::string {
    return FoundationToCppString(DOLocalizedString(CToFoundationString(text)));
  });
  
  [MainiOS applicationStart];
  
  // Mark the ROM folder as excluded from backups
  NSURL* rom_folder_url = [NSURL fileURLWithPath:[MainiOS getUserFolder]];
  [rom_folder_url setResourceValue:[NSNumber numberWithBool:true] forKey:NSURLIsExcludedFromBackupKey error:nil];
  
  // Create a UINavigationController for alerts
  NoticeNavigationViewController* nav_controller = [[NoticeNavigationViewController alloc] init];
  [nav_controller setNavigationBarHidden:true];
  
  if (@available(iOS 13, *))
  {
    [nav_controller setModalPresentationStyle:UIModalPresentationFormSheet];
    nav_controller.modalInPresentation = true;
  }
  else
  {
    [nav_controller setModalPresentationStyle:UIModalPresentationFullScreen];
  }
  
  // Check if the background save state exists
  if (File::Exists(File::GetUserPath(D_STATESAVES_IDX) + "backgroundAuto.sav"))
  {
    DOLReloadFailedReason reload_fail_reason = DOLReloadFailedReasonNone;
    
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"last_game_state_version"] != State::GetVersion())
    {
      reload_fail_reason = DOLReloadFailedReasonOld;
    }
    else if (!File::Exists(FoundationToCppString([[NSUserDefaults standardUserDefaults] stringForKey:@"last_game_path"])))
    {
      reload_fail_reason = DOLReloadFailedReasonFileGone;
    }
    
    if (reload_fail_reason == DOLReloadFailedReasonNone)
    {
      [nav_controller pushViewController:[[ReloadStateNoticeViewController alloc] initWithNibName:@"ReloadStateNotice" bundle:nil] animated:true];
    }
    else
    {
      ReloadFailedNoticeViewController* view_controller = [[ReloadFailedNoticeViewController alloc] initWithNibName:@"ReloadFailedNotice" bundle:nil];
      view_controller.m_reason = reload_fail_reason;
      
      [nav_controller pushViewController:view_controller animated:true];
    }
  }
  
  // Check the CPUCore type if necessary
  bool has_changed_core = [[NSUserDefaults standardUserDefaults] boolForKey:@"did_deliberately_change_cpu_core"];
  
  if (!has_changed_core)
  {
    const std::string config_path = File::GetUserPath(F_DOLPHINCONFIG_IDX);
    
    // Load Dolphin.ini
    IniFile dolphin_config;
    dolphin_config.Load(config_path);
    
    PowerPC::CPUCore core_type;
    dolphin_config.GetOrCreateSection("Core")->Get("CPUCore", &core_type);
    
    PowerPC::CPUCore correct_core;
#if !TARGET_OS_SIMULATOR
    correct_core = PowerPC::CPUCore::JITARM64;
#else
    correct_core = PowerPC::CPUCore::JIT64;
#endif
    
    if (core_type != correct_core)
    {
      // Reset the CPUCore
      SConfig::GetInstance().cpu_core = correct_core;
      Config::SetBaseOrCurrent(Config::MAIN_CPU_CORE, correct_core);
      
      [nav_controller pushViewController:[[InvalidCpuCoreNoticeViewController alloc] initWithNibName:@"InvalidCpuCoreNotice" bundle:nil] animated:true];
    }
  }
  
  // Get the number of launches
  NSInteger launch_times = [[NSUserDefaults standardUserDefaults] integerForKey:@"launch_times"];
  if (launch_times == 0)
  {
    [nav_controller pushViewController:[[UnofficialBuildNoticeViewController alloc] initWithNibName:@"UnofficialBuildNotice" bundle:nil] animated:true];
  }
  else if (launch_times % 10 == 0)
  {
#ifndef PATREON
    bool suppress_donation_message = [[NSUserDefaults standardUserDefaults] boolForKey:@"suppress_donation_message"];
    
    if (!suppress_donation_message)
    {
      [nav_controller pushViewController:[[DonationNoticeViewController alloc] initWithNibName:@"DonationNotice" bundle:nil] animated:true];
    }
#endif
  }
  
  if (!SConfig::GetInstance().m_analytics_permission_asked)
  {
    [nav_controller pushViewController:[[AnalyticsNoticeViewController alloc] initWithNibName:@"AnalyticsNotice" bundle:nil] animated:true];
  }
  
  // Present if the navigation controller isn't empty
  if ([[nav_controller viewControllers] count] != 0)
  {
    [self.window makeKeyAndVisible];
    [self.window.rootViewController presentViewController:nav_controller animated:true completion:nil];
  }
  
  // Check for updates
#ifndef DEBUG
  NSString* update_url_string;
#ifndef PATREON
  update_url_string = @"https://cydia.oatmealdome.me/DolphiniOS/api/update.json";
#else
  update_url_string = @"https://cydia.oatmealdome.me/DolphiniOS/api/update_patreon.json";
#endif
  
  NSURL* update_url = [NSURL URLWithString:update_url_string];
  
  // Create en ephemeral session to avoid caching
  NSURLSession* session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
  [[session dataTaskWithURL:update_url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    if (error != nil)
    {
      return;
    }
    
    // Get the version string
    NSDictionary* info = [[NSBundle mainBundle] infoDictionary];
    NSString* version_str = [NSString stringWithFormat:@"%@ (%@)", [info objectForKey:@"CFBundleShortVersionString"], [info objectForKey:@"CFBundleVersion"]];
    
    // Deserialize the JSON
    NSDictionary* dict = (NSDictionary*)[NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
    
    if (![dict[@"version"] isEqualToString:version_str])
    {
      dispatch_async(dispatch_get_main_queue(), ^{
        UpdateNoticeViewController* update_controller = [[UpdateNoticeViewController alloc] initWithNibName:@"UpdateNotice" bundle:nil];
        update_controller.m_update_json = dict;
        
        if (![nav_controller isBeingPresented])
        {
          [nav_controller setViewControllers:@[update_controller]];
          [self.window makeKeyAndVisible];
          [self.window.rootViewController presentViewController:nav_controller animated:true completion:nil];
        }
        else
        {
          [nav_controller pushViewController:update_controller animated:true];
        }
      });
    }
  }] resume];
#endif
  
  // Increment the launch count
  [[NSUserDefaults standardUserDefaults] setInteger:launch_times + 1 forKey:@"launch_times"];
  
#if !defined(DEBUG) && !TARGET_OS_SIMULATOR
  // Activate AppCenter analytics
  DolphiniOSKeys* keys = [[DolphiniOSKeys alloc] init];
  [MSAppCenter start:[keys appCenterSecret] withServices:@[
    [MSAnalytics class],
    [MSCrashes class]
  ]];
  
  [MSAnalytics setEnabled:SConfig::GetInstance().m_analytics_enabled];
  [MSCrashes setEnabled:[[NSUserDefaults standardUserDefaults] boolForKey:@"crash_reporting_enabled"]];
#endif
  
  return YES;
}

- (void)applicationWillTerminate:(UIApplication*)application
{
  if (Core::IsRunning())
  {
    Core::Stop();
    
    // Spin while Core stops
    while (Core::GetState() != Core::State::Uninitialized);
  }
  
  [[TCDeviceMotion shared] stopMotionUpdates];
  Pad::Shutdown();
  Keyboard::Shutdown();
  Wiimote::Shutdown();
  g_controller_interface.Shutdown();
  
  Config::Save();
  SConfig::GetInstance().SaveSettings();
  
  Core::Shutdown();
  UICommon::Shutdown();
}

- (void)applicationDidBecomeActive:(UIApplication*)application
{
  if (Core::IsRunning())
  {
    Core::SetState(Core::State::Running);
  }
}

- (void)applicationWillResignActive:(UIApplication*)application
{
  if (Core::IsRunning())
  {
    Core::SetState(Core::State::Paused);
  }
}

- (void)applicationDidEnterBackground:(UIApplication*)application
{
  std::string save_state_path = File::GetUserPath(D_STATESAVES_IDX) + "backgroundAuto.sav";

  self.m_save_state_task = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"Save Data" expirationHandler:^{
    // Delete the save state - it's probably corrupt
    File::Delete(save_state_path);
    
    [[UIApplication sharedApplication] endBackgroundTask:self.m_save_state_task];
    self.m_save_state_task = UIBackgroundTaskInvalid;
  }];
  
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // Write out the configuration in case we don't get a chance later
    Config::Save();
    SConfig::GetInstance().SaveSettings();

    if (Core::IsRunning())
    {
     // Save out a save state
     State::SaveAs(save_state_path, true);
    }

    [[UIApplication sharedApplication] endBackgroundTask:self.m_save_state_task];
    self.m_save_state_task = UIBackgroundTaskInvalid;
  });
}

- (BOOL)application:(UIApplication*)app openURL:(NSURL*)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id>*)options
{
  [MainiOS importFiles:[NSSet setWithObject:url]];
  
  return YES;
}

@end