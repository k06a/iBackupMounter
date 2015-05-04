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

@interface ABAppDelegate () <NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate>
@property (weak, nonatomic) IBOutlet NSPopUpButton *backupPopUpButton;
@property (weak) IBOutlet NSButton *readOnlyButton;
@property (weak) IBOutlet NSButton *saveButton;
@property (weak) IBOutlet NSButton *discardButton;
@property (weak) IBOutlet NSTableView *sourceTableView;
@property (weak) IBOutlet NSTableView *dataTableView;

@property (strong, nonatomic) NSArray *backups;
@property (strong, nonatomic) GMUserFileSystem *fs;
@property (strong, nonatomic) ABFileSystem *fileSystem;
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
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Status.plist"]];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateStyle = NSDateFormatterLongStyle;
    dateFormatter.timeStyle = NSDateFormatterLongStyle;
    return [NSString stringWithFormat:@"%@ with iOS %@ (%@)",
            info[@"Display Name"],
            info[@"Product Version"],
            [dateFormatter stringFromDate:status[@"Date"]]];
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
    self.discardButton.enabled = NO;
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
        self.fileSystem = [[ABFileSystem alloc] initWithBackupPath:path];
        __weak typeof(self) this = self;
        self.fileSystem.wasModifiedBlock = ^{
            this.saveButton.enabled = YES;
            this.discardButton.enabled = YES;
        };
    }
    @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [@"Unable to mount this backup because: " stringByAppendingString:exception.description];
        [alert runModal];
        return;
    }
    
    NSString* mountPath = @"/Volumes/iBackupMounter";
    self.fs = [[GMUserFileSystem alloc] initWithDelegate:self.fileSystem isThreadSafe:YES];
    if (self.readOnlyButton.state == NSOnState) {
        [self.fs mountAtPath:mountPath withOptions:@[@"rdonly", @"volname=iBackupMounter"]];
        self.saveButton.hidden = YES;
        self.discardButton.hidden = YES;
    } else {
        [self.fs mountAtPath:mountPath withOptions:@[@"volname=iBackupMounter"]];
        self.saveButton.hidden = NO;
        self.discardButton.hidden = NO;
    }
    
    [self.sourceTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self sourceSelected:self.sourceTableView];
    //[NSString stringWithFormat:@"volicon=%@",[[NSBundle mainBundle] pathForResource:@"Fuse" ofType:@"icns"]]]];
}

- (IBAction)readOnlyToggled:(NSButton *)sender
{
    [self backupSelected:self.backupPopUpButton];
}

- (IBAction)savePressed:(id)sender
{
    [self.fileSystem saveChanges];
    self.saveButton.enabled = NO;
    self.discardButton.enabled = NO;
}

- (IBAction)discardPressed:(id)sender
{
    [self.fileSystem discardChanges];
    self.saveButton.enabled = NO;
    self.discardButton.enabled = NO;
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
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSWorkspace sharedWorkspace] selectFile:mountPath
                         inFileViewerRootedAtPath:parentPath];
    });
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

#pragma mark - Table View

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == self.sourceTableView)
    {
        return 3;
    }
    else
    {
        switch (self.sourceTableView.selectedRow)
        {
            case 0: return self.fileSystem.networks.count;
            case 1: return 0;
            case 2: return 0;
            default:
                return 0;
        }
    }
}

- (NSString *)sourceForRow:(NSInteger)row
{
    switch (row)
    {
        case 0: return @"Networks";
        case 1: return @"Contacts";
        case 2: return @"Messages";
        default:
            return nil;
    }
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == self.sourceTableView)
    {
        NSTextField *cell = [tableView makeViewWithIdentifier:@"cell_1" owner:self];
        if (cell == nil) {
            cell = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,tableView.frame.size.width,10)];
            cell.bordered = NO;
            cell.editable = NO;
            cell.backgroundColor = [NSColor clearColor];
            cell.identifier = @"cell_1";
        }
        
        cell.stringValue = [self sourceForRow:row];
        return cell;
    }
    else
    {
        NSTextField *cell = [tableView makeViewWithIdentifier:@"cell_1" owner:self];
        if (cell == nil) {
            cell = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,tableView.frame.size.width,10)];
            cell.bordered = NO;
            cell.editable = NO;
            cell.backgroundColor = [NSColor clearColor];
            cell.identifier = @"cell_1";
        }
        
        cell.stringValue = self.fileSystem.networks[row];
        return cell;
    }
}

- (IBAction)sourceSelected:(id)sender
{
    [self.dataTableView reloadData];
}

@end
