//
//  ABAppDelegate.m
//  iBackupMounter
//
//  Created by Антон Буков on 16.04.14.
//  Copyright (c) 2014 Codeless Solutions. All rights reserved.
//

#import <OSXFUSE/OSXFUSE.h>
#import "ABAppDelegate.h"
#import "ABFileSystem.h"

@interface ABAppDelegate ()
@property (weak, nonatomic) IBOutlet NSPopUpButton *backupPopUpButton;

@property (strong, nonatomic) NSArray *backups;
@property (strong, nonatomic) GMUserFileSystem *fs;
@property (strong, nonatomic) ABFileSystem *fsObject;
@end

@implementation ABAppDelegate

- (NSString *)backupsPath
{
    return [@"~/Library/Application Support/MobileSync/Backup/" stringByExpandingTildeInPath];
}

- (NSArray *)backups
{
    if (_backups == nil) {
        _backups = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self backupsPath] error:NULL] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *filename, NSDictionary *bindings) {
            return [filename characterAtIndex:0] != '.';
        }]];
    }
    return _backups;
}

- (NSString *)titleForBackup:(NSString *)backup
{
    NSString *path = [[self backupsPath] stringByAppendingPathComponent:backup];
    NSString *info = [NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@"info.plist"] encoding:NSUTF8StringEncoding error:NULL];
    
    NSRange range = [info rangeOfString:@"<key>Display Name</key>"];
    NSInteger begin = [info rangeOfString:@">" options:0 range:NSMakeRange(range.location+range.length, 100)].location + 1;
    NSInteger end = [info rangeOfString:@"<" options:0 range:NSMakeRange(begin, 100)].location;
    NSString *name = [info substringWithRange:NSMakeRange(begin, end-begin)];
    
    range = [info rangeOfString:@"<key>Last Backup Date</key>"];
    begin = [info rangeOfString:@">" options:0 range:NSMakeRange(range.location+range.length, 100)].location + 1;
    end = [info rangeOfString:@"<" options:0 range:NSMakeRange(begin, 100)].location;
    NSString *date = [[[info substringWithRange:NSMakeRange(begin, end-begin)]
                      stringByReplacingOccurrencesOfString:@"T" withString:@" "]
                      stringByReplacingOccurrencesOfString:@"Z" withString:@""];
    
    range = [info rangeOfString:@"<key>Product Version</key>"];
    begin = [info rangeOfString:@">" options:0 range:NSMakeRange(range.location+range.length, 100)].location + 1;
    end = [info rangeOfString:@"<" options:0 range:NSMakeRange(begin, 100)].location;
    NSString *version = [info substringWithRange:NSMakeRange(begin, end-begin)];
    
    return [NSString stringWithFormat:@"%@ with iOS %@ (%@)",name,version,date];
}

- (void)updateBackupPopUp
{
    [self.backupPopUpButton removeAllItems];
    for (NSString *backup in self.backups) {
        [self.backupPopUpButton addItemWithTitle:[self titleForBackup:backup]];
    }
}

- (IBAction)backupSelected:(NSPopUpButton *)sender
{
    NSString *path = [[self backupsPath] stringByAppendingPathComponent:self.backups[sender.indexOfSelectedItem]];
    
    if (self.fs)
        [self.fs unmount];
    
    @try {
        self.fsObject = [[ABFileSystem alloc] initWithBackupPath:path];
    }
    @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [@"Unable to mount this backup because of " stringByAppendingString:exception.name];
        [alert runModal];
        return;
    }
    
    NSString* mountPath = @"/Volumes/iBackupMounter";
    self.fs = [[GMUserFileSystem alloc] initWithDelegate:self.fsObject isThreadSafe:YES];
    [self.fs mountAtPath:mountPath withOptions:@[@"rdonly", @"volname=iBackupMounter"]];//, [NSString stringWithFormat:@"volicon=%@",[[NSBundle mainBundle] pathForResource:@"Fuse" ofType:@"icns"]]]];
}

- (void)didMount:(NSNotification *)notification
{
    NSDictionary* userInfo = [notification userInfo];
    NSString* mountPath = [userInfo objectForKey:kGMUserFileSystemMountPathKey];
    NSString* parentPath = [mountPath stringByDeletingLastPathComponent];
    [[NSWorkspace sharedWorkspace] selectFile:mountPath
                     inFileViewerRootedAtPath:parentPath];
}

- (void)didUnmount:(NSNotification*)notification
{
    //[[NSApplication sharedApplication] terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(didMount:)
                   name:kGMUserFileSystemDidMount object:nil];
    [center addObserver:self selector:@selector(didUnmount:)
                   name:kGMUserFileSystemDidUnmount object:nil];
    
    [self updateBackupPopUp];
    if (self.backups.count > 0)
        [self backupSelected:self.backupPopUpButton];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.fs unmount];
    return NSTerminateNow;
}

@end
