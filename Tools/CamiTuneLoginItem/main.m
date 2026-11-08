#import <AppKit/AppKit.h>
#import <os/log.h>

// The launcher owns no audio state. Resolve its containing app, let Launch
// Services start that bundle once, and finish without a resident background task.
void CamiTuneLaunchAtLogin(NSURL *helperURL, NSWorkspace *workspace,
                          void (^completion)(NSError *)) {
    NSURL *parent = helperURL;
    for (NSString *component in @[@"LoginItems", @"Library", @"Contents"]) {
        parent = parent.URLByDeletingLastPathComponent;
        if (![parent.lastPathComponent isEqualToString:component]) {
            completion([NSError errorWithDomain:@"local.camilla.login-item" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"The login launcher is outside its application bundle."}]);
            return;
        }
    }
    parent = parent.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
    NSBundle *app = [NSBundle bundleWithURL:parent];
    if (![app.bundleIdentifier isEqualToString:@"local.camilla.app"] || !app.executableURL ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:app.executableURL.path]) {
        completion([NSError errorWithDomain:@"local.camilla.login-item" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The containing CamiTune application is missing."}]);
        return;
    }
    for (NSRunningApplication *running in workspace.runningApplications) {
        if ([running.bundleIdentifier isEqualToString:app.bundleIdentifier]) {
            completion(nil);
            return;
        }
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = NO;
    configuration.activates = NO;
    [workspace openApplicationAtURL:parent configuration:configuration
                 completionHandler:^(NSRunningApplication *application, NSError *error) {
        completion(error);
    }];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Exit successfully even after a logged launch failure so launchd does
        // not repeatedly restart a helper that cannot open its parent app.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            os_log_error(OS_LOG_DEFAULT, "CamiTune login launch timed out.");
            exit(0);
        });
        CamiTuneLaunchAtLogin(NSBundle.mainBundle.bundleURL, NSWorkspace.sharedWorkspace, ^(NSError *error) {
            if (error) { os_log_error(OS_LOG_DEFAULT, "CamiTune login launch failed: %{public}@", error.localizedDescription); }
            exit(0);
        });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
