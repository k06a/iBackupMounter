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

@interface ABAppDelegate () <NSWindowDelegate>
@property (weak, nonatomic) IBOutlet NSPopUpButton *backupPopUpButton;
@property (weak) IBOutlet NSButton *readOnlyButton;
@property (weak) IBOutlet NSButton *saveButton;

@property (strong, nonatomic) NSArray *backups;
@property (strong, nonatomic) GMUserFileSystem *fs;
@property (strong, nonatomic) ABFileSystem *fsObject;
@property (assign, nonatomic) NSInteger selectedIndex;
@property (assign, nonatomic) NSInteger indexToSelectAfterSaveOrDiscard;
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

- (void)save:(id)sender
{
    [self savePressed:nil];
    [self.backupPopUpButton selectItemAtIndex:self.indexToSelectAfterSaveOrDiscard];
}

- (void)discard:(id)sender
{
    self.saveButton.enabled = NO;
    [self.backupPopUpButton selectItemAtIndex:self.indexToSelectAfterSaveOrDiscard];
}

- (IBAction)backupSelected:(NSPopUpButton *)sender
{
    if (self.saveButton.isEnabled) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Save or discard changes of backup?";
        NSButton *discard = [alert addButtonWithTitle:@"Discard"];
        discard.target = self;
        discard.action = @selector(discard:);
        NSButton *save = [alert addButtonWithTitle:@"Save"];
        save.target = self;
        save.action = @selector(save:);
        [alert addButtonWithTitle:@"Cancel"];
        [alert runModal];
        
        self.indexToSelectAfterSaveOrDiscard = sender.indexOfSelectedItem;
        [self.backupPopUpButton selectItemAtIndex:self.selectedIndex];
        return;
    }
    
    self.selectedIndex = sender.indexOfSelectedItem;
    NSString *path = [[self backupsPath] stringByAppendingPathComponent:self.backups[sender.indexOfSelectedItem]];
    
    if (self.fs)
        [self unmount];
    
    @try {
        self.fsObject = [[ABFileSystem alloc] initWithBackupPath:path];
        __weak typeof(self) this = self;
        self.fsObject.wasModifiedBlock = ^{
            this.saveButton.enabled = YES;
        };
    }
    @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [@"Unable to mount this backup because of " stringByAppendingString:exception.name];
        [alert runModal];
        return;
    }
    
    NSString* mountPath = @"/Volumes/iBackupMounter";
    self.fs = [[GMUserFileSystem alloc] initWithDelegate:self.fsObject isThreadSafe:YES];
    if (self.readOnlyButton.state == NSOnState) {
        [self.fs mountAtPath:mountPath withOptions:@[@"rdonly", @"volname=iBackupMounter"]];
        self.saveButton.hidden = YES;
    } else {
        [self.fs mountAtPath:mountPath withOptions:@[@"volname=iBackupMounter"]];
        self.saveButton.hidden = NO;
    }
    
    //[NSString stringWithFormat:@"volicon=%@",[[NSBundle mainBundle] pathForResource:@"Fuse" ofType:@"icns"]]]];
}

- (IBAction)readOnlyToggled:(NSButton *)sender
{
    [self backupSelected:self.backupPopUpButton];
}

- (IBAction)savePressed:(id)sender
{
    [self.fsObject saveChanges];
    self.saveButton.enabled = NO;
}

- (void)unmount
{
    [self.fs unmount];
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
    if (self.saveButton.isEnabled) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Save or discard changes of backup?";
        NSButton *discard = [alert addButtonWithTitle:@"Discard"];
        discard.target = self;
        discard.action = @selector(discardAndQuit:);
        NSButton *save = [alert addButtonWithTitle:@"Save"];
        save.target = self;
        save.action = @selector(saveAndQuit:);
        [alert addButtonWithTitle:@"Cancel"];
        [alert runModal];
        
        return NSTerminateCancel;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self unmount];
    return NSTerminateNow;
}

- (void)saveAndQuit:(NSButton *)sender
{
    [self savePressed:nil];
    [[NSApplication sharedApplication] terminate:nil];
}

- (void)discardAndQuit:(NSButton *)sender
{
    self.saveButton.enabled = NO;
    [[NSApplication sharedApplication] terminate:nil];
}

#pragma mark - Window

- (BOOL)windowShouldClose:(id)sender
{
    return [self applicationShouldTerminate:[NSApplication sharedApplication]];
}

@end
