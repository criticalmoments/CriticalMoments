//
//  CMBackgroundHandler.m
//
//
//  Created by Steve Cosman on 2024-07-11.
//

#import "CMBackgroundHandler.h"

#import "../CriticalMoments_private.h"

#import <BackgroundTasks/BackgroundTasks.h>
#import <os/log.h>

@import Appcore;

#define bgFetchTaskId @"io.criticalmoments.bg_fetch"
#define bgProcessingTaskId @"io.criticalmoments.bg_process"
#define allBackgroundIds @[ bgFetchTaskId, bgProcessingTaskId ]

@interface CMBackgroundHandler ()

@property(nonatomic, weak) CriticalMoments *cm;
@property(nonatomic, strong) NSMutableArray<NSString *> *registeredTaskIds;

@end

@implementation CMBackgroundHandler

- (instancetype)initWithCm:(CriticalMoments *)cm {
    self = [super init];
    if (self) {
        self.cm = cm;
        self.registeredTaskIds = [NSMutableArray array];
    }
    return self;
}

- (void)registerBackgroundTasks {
    if (@available(iOS 13.0, *)) {
        for (NSString *taskId in allBackgroundIds) {
            CMBackgroundHandler *__weak weakSelf = self;
            BOOL registered =
                [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:taskId
                                                                    usingQueue:nil
                                                                 launchHandler:^(__kindof BGTask *_Nonnull task) {
                                                                   [weakSelf runBackgroundWorker:task];
                                                                 }];

            // Note: Simulator not supported. Test background tasks on device only.
            if (!registered) {
                [CMBackgroundHandler logSetupError:taskId];
            } else {
                [self.registeredTaskIds addObject:taskId];
            }
        }
    }
}

- (void)scheduleBackgroundTask {
    if (@available(iOS 13.0, *)) {
        BGAppRefreshTaskRequest *fetchRequest = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:bgFetchTaskId];
        // At least 15 mins from now
        fetchRequest.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:15 * 60];

        NSError *error;
        BOOL success = [BGTaskScheduler.sharedScheduler submitTaskRequest:fetchRequest error:&error];
        if (!success || error) {
            [CMBackgroundHandler logSetupError:bgFetchTaskId];
        }

        error = nil;
        BGProcessingTaskRequest *processingRequest =
            [[BGProcessingTaskRequest alloc] initWithIdentifier:bgProcessingTaskId];
        success = [BGTaskScheduler.sharedScheduler submitTaskRequest:processingRequest error:&error];
        if (!success || error) {
            [CMBackgroundHandler logSetupError:bgProcessingTaskId];
        }
    }

    for (NSString *taskId in allBackgroundIds) {
        if (![self.registeredTaskIds containsObject:taskId]) {
            // Don't register if there isn't a handler for this taskId
            continue;
        }
        NSURL *logPath = [CMBackgroundHandler logPath:true withTaskId:taskId];
        NSString *logContents = [NSString stringWithContentsOfURL:logPath encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"BG Debug Log [%@]:\n%@\n\n", taskId, logContents);

        logPath = [CMBackgroundHandler logPath:false withTaskId:taskId];
        logContents = [NSString stringWithContentsOfURL:logPath encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"BG Release Log [%@]:\n%@\n\n", taskId, logContents);
    }
}

- (void)runBackgroundWorker:(BGTask *)task API_AVAILABLE(ios(13.0)) {
    // Schedule next refresh
    [self scheduleBackgroundTask];

    [CMBackgroundHandler logRunTimestamp:task.identifier];
    [self.cm runAppcoreBackgroundWork];
    [self.cm sendEvent:@"background_worker_ran" builtIn:YES handler:nil];
    NSLog(@"CMBackground: worker ran - %@", task.identifier);

    [task setTaskCompletedWithSuccess:YES];
}

// TODO_P0 remove this
+ (NSURL *)logPath:(BOOL)debug withTaskId:(NSString *)taskId {
    NSURL *appSupportDir = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                 inDomains:NSUserDomainMask] lastObject];

    NSURL *criticalMomentsDataDir = [appSupportDir URLByAppendingPathComponent:@"critical_moments_test_data"];
    NSError *error;
    BOOL s = [NSFileManager.defaultManager createDirectoryAtURL:criticalMomentsDataDir
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&error];
    if (!s || error) {
        NSLog(@"error: %@", error);
    }
    NSString *filename = [NSString stringWithFormat:@"%@.log", taskId];
    if (debug) {
        filename = [NSString stringWithFormat:@"%@_debug.log", taskId];
    }
    NSURL *bgLogFile = [criticalMomentsDataDir URLByAppendingPathComponent:filename];
    return bgLogFile;
}

// TODO_P0 remove this
+ (void)logRunTimestamp:(NSString *)taskId {
    NSString *dateString = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                          dateStyle:NSDateFormatterShortStyle
                                                          timeStyle:NSDateFormatterFullStyle];

#ifdef DEBUG
    NSURL *logPath = [CMBackgroundHandler logPath:true withTaskId:taskId];
#else
    NSURL *logPath = [CMBackgroundHandler logPath:false withTaskId:taskId];
#endif
    NSString *logContents = [NSString stringWithContentsOfURL:logPath encoding:NSUTF8StringEncoding error:nil];
    NSString *newContent = dateString;
    if (logContents) {
        newContent = [NSString stringWithFormat:@"%@\n%@", logContents, dateString];
    }
    NSError *error;
    BOOL s = [newContent writeToURL:logPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!s || error) {
        NSLog(@"error: %@", error);
    }
}

+ (BOOL)isSimulator {
    char *simulatorId = getenv("SIMULATOR_MODEL_IDENTIFIER");
    return simulatorId != NULL;
    ;
}

+ (void)logSetupError:(NSString *)taskId {
    // Background tasks aren't supported on simulators. No need to log errors.
    if (self.isSimulator) {
        return;
    }

    NSLog(@"CriticalMoments: failed to register background worker [%@]. Please ensure you follow all the steps in our "
          @"quick "
          @"start guide. https://docs.criticalmoments.io/quick-start",
          taskId);
}

#ifdef DEBUG
// Check everything is setup correctly, and log a warning if not.
// Only compiled in debug mode, won't run on release builds.
+ (void)devModeCheckBackgroundSetupCorrectly {
    // Check our 2 IDs are included in the app's Info.plist
    // Don't simply error in callback because it isn't run on simulators, and we want devs to see this.
    NSArray *permittedIdentifiers =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"];
    for (NSString *requiredTaskId in allBackgroundIds) {
        if (![permittedIdentifiers containsObject:requiredTaskId]) {
            os_log_error(
                OS_LOG_DEFAULT,
                "CriticalMoments: Setup Issue\nYou must add CM background task IDs to your Info.plist. If you don't, "
                "some CM features will not function.\n\nSee our quick start guide for details on how to resolve this "
                "issue: https://docs.criticalmoments.io\n\nThis warning log is only in debug builds.");
            break;
        }
    }

    // Check both background modes are in the Info.plist
    NSArray *permittedBackgroundModes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
    NSArray<NSString *> *requiredModes = @[ @"fetch", @"processing" ];

    for (NSString *requiredMode in requiredModes) {
        if (![permittedBackgroundModes containsObject:requiredMode]) {
            os_log_error(OS_LOG_DEFAULT,
                         "CriticalMoments: Setup Issue\nYou must enable 'Background processing' and 'Background fetch' "
                         "capabilities in your app. Without them, some Critical Moments features will not "
                         "function.\n\nSee our quick start guide for details on how to resolve this issue: "
                         "https://docs.criticalmoments.io\n\nThis warning log is only in debug builds.");
            break;
        }
    }
}
#endif

@end
