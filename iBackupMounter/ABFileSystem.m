//
//  ABFileSystem.m
//  iBackupMounter
//
//  Created by Антон Буков on 16.04.14.
//  Copyright (c) 2018 Codeless Solutions. All rights reserved.
//

#include <CommonCrypto/CommonDigest.h>
#import <OSXFUSE/OSXFUSE.h>

#import "ABFileSystem.h"

@interface ABFileSystem ()

@property (strong, nonatomic) NSString *backupPath;
@property (strong, nonatomic) NSMutableDictionary *tree;
@property (strong, nonatomic) NSMutableArray *pathsToRemove;

@property (strong, nonatomic) NSArray *networks;

@end

@implementation ABFileSystem

- (NSMutableDictionary *)tree {
    if (_tree == nil) {
        _tree = [NSMutableDictionary dictionary];
        [self growTreeToPath:@"/AppDomain"];
        [self growTreeToPath:@"/AppDomainGroup"];
        [self growTreeToPath:@"/AppDomainPlugin"];
    }

    return _tree;
}

- (NSMutableArray *)pathsToRemove {
    if (_pathsToRemove == nil) {
        _pathsToRemove = [NSMutableArray array];
    }
    return _pathsToRemove;
}

- (NSArray *)networks {
    if (_networks == nil) {
        NSDictionary *node = [self growTreeToPath:@"/SystemPreferencesDomain/SystemConfiguration/com.apple.wifi.plist"];
        NSString *path = node[@"/realPath"];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        
        NSMutableArray *arr = [NSMutableArray array];
        NSArray *nets = [dict[@"List of known networks"] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSDate *adate = a[@"lastJoined"] ?: a[@"lastAutoJoined"];
            NSDate *bdate = b[@"lastJoined"] ?: b[@"lastAutoJoined"];
            if (!adate && !bdate)
                return NSOrderedSame;
            if (!adate)
                return NSOrderedDescending;
            if (!bdate)
                return NSOrderedAscending;
            return [b[@"lastJoined"] compare:a[@"lastJoined"]];
        }];
        
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
        for (id network in nets) {
            [arr addObject:[NSString stringWithFormat:@"%@ => %@",
                            [dateFormatter stringFromDate:network[@"lastJoined"]?:network[@"lastAutoJoined"]],
                            network[@"SSID_STR"]]];
        }
        _networks = arr;
    }
    return _networks;
}

- (NSMutableDictionary *)growTreeToPath:(NSString *)path {
    NSMutableDictionary *node = self.tree;
    for (NSString *token in [path pathComponents]) {
        id nextNode = node[token];
        if (!nextNode) {
            nextNode = [NSMutableDictionary dictionary];
            node[token] = nextNode;
        }
        node = nextNode;
    }
    return node;
}

- (NSDictionary *)nodeForPath:(NSString *)path {
    NSMutableDictionary *node = self.tree;
    for (NSString *token in path.pathComponents) {
        if (!(node = node[token])) {
            return nil;
        }
    }
    return node;
}

- (instancetype)initWithBackupPath:(NSString *)backupPath {
    if (self = [super init]) {
        self.backupPath = backupPath;
        
        NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:[backupPath stringByAppendingPathComponent:@"Status.plist"]];
        if (![status[@"SnapshotState"] isEqualToString:@"finished"]) {
            [NSException raise:@"" format:@"Backup is not finished yet"];
        }
        
        NSString *manifetsDbPath = [backupPath stringByAppendingPathComponent:@"Manifest.db"];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:manifetsDbPath]) {
            [NSException raise:@"" format:@"Manifest.db not found"];
        }
        
        NSData *data = [NSMutableData dataWithContentsOfFile:manifetsDbPath];
        if (((char *)data.bytes)[0] != 'S'
            || ((char *)data.bytes)[1] != 'Q'
            || ((char *)data.bytes)[2] != 'L'
            || ((char *)data.bytes)[3] != 'i'
            || ((char *)data.bytes)[4] != 't'
            || ((char *)data.bytes)[5] != 'e')
        {
            [NSException raise:@"" format:@"Invalid Manifest.db SQLite header"];
        }
        
        NSPipe *pipe = [NSPipe pipe];
        NSFileHandle *file = pipe.fileHandleForReading;
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/sqlite3";
        task.arguments = @[
            manifetsDbPath,
            @"-csv",
            @"-bail",
            @"-cmd", @"select * from Files",
            @"-cmd", @".quit"
        ];
        task.standardOutput = pipe;
        [task launch];
        NSData *outputData = [file readDataToEndOfFile];
        [file closeFile];
        
        NSString *output = [[NSString alloc] initWithData:outputData encoding: NSASCIIStringEncoding];
        //NSLog (@"output:\n%@", output);
        
        for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *tokens = [line componentsSeparatedByString:@","];
            if (tokens.count != 5) {
                continue;
            }
            
            NSString *realPath = [[backupPath stringByAppendingPathComponent:[tokens[0] substringToIndex:2]] stringByAppendingPathComponent:tokens[0]];
            NSString *domain = (tokens[1].length >= 2 && [tokens[1] hasPrefix:@"\""] && [tokens[1] hasSuffix:@"\""]) ? [tokens[1] substringWithRange:NSMakeRange(1, tokens[1].length - 2)] : tokens[1];
            NSString *path = (tokens[2].length >= 2 && [tokens[2] hasPrefix:@"\""] && [tokens[2] hasSuffix:@"\""]) ? [tokens[2] substringWithRange:NSMakeRange(1, tokens[2].length - 2)] : tokens[2];
            NSUInteger length = [[[NSFileManager defaultManager] attributesOfItemAtPath:realPath error:nil] fileSize];
            
            NSString *key = nil;
            if ([tokens[3] isEqualToString:@"1"])
                key = @"/file";
            else if ([tokens[3] isEqualToString:@"2"])
                key = @"/dir";
            else
                continue;
            
//            NSString *plistStr = (tokens[4].length >= 2 && [tokens[4] hasPrefix:@"\""] && [tokens[4] hasSuffix:@"\""]) ? [tokens[4] substringWithRange:NSMakeRange(1, tokens[4].length - 2)] : tokens[4];
//            NSData *plistData = [plistStr dataUsingEncoding:NSNonLossyASCIIStringEncoding];
//            NSError *err;
//            id plist = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:NSPropertyListBinaryFormat_v1_0 error:&err];
//            NSLog(@"%@", err);
//            NSLog(@"%@", plist);
            
            NSString *virtualPath = domain;
            if ([virtualPath hasPrefix:@"AppDomain-"] ||
                [virtualPath hasPrefix:@"AppDomainGroup-"] ||
                [virtualPath hasPrefix:@"AppDomainPlugin-"] ||
                [virtualPath hasPrefix:@"SysContainerDomain-"] ||
                [virtualPath hasPrefix:@"SysSharedContainerDomain-"])
            {
                NSString *ad = [virtualPath componentsSeparatedByString:@"-"].firstObject;
                
                virtualPath = [virtualPath stringByReplacingOccurrencesOfString:[ad stringByAppendingString:@"-"] withString:[ad stringByAppendingString:@"/"]];
                if (self.tree[@"/"][ad] == nil) {
                    NSMutableDictionary *appNode = [self growTreeToPath:[@"/" stringByAppendingString:ad]];
                    appNode[@"/length"] = @(length);
                    //appNode[@"/mode"] = @(mode);
                    appNode[@"/domain"] = domain;
                    appNode[@"/path"] = path;
                    appNode[@"/mdate"] = [NSDate dateWithTimeIntervalSince1970:0];
                    appNode[@"/cdate"] = [NSDate dateWithTimeIntervalSince1970:0];
                    appNode[@"/realPath"] = realPath;
                    appNode[@"/dir"] = @YES;
                }
            }
            
            if (![path isEqualToString:@"\"\""]) {
                virtualPath = [virtualPath stringByAppendingPathComponent:path];
                virtualPath = [@"/" stringByAppendingString:virtualPath];
                NSMutableDictionary *node = [self growTreeToPath:virtualPath];
                node[@"/length"] = @(length);
                //node[@"/mode"] = @(mode);
                node[@"/domain"] = domain;
                node[@"/path"] = path;
                node[@"/mdate"] = [NSDate dateWithTimeIntervalSince1970:0];
                node[@"/cdate"] = [NSDate dateWithTimeIntervalSince1970:0];
                node[@"/realPath"] = realPath;
                node[@"/hash"] = tokens[0];
                node[key] = @YES;
            }
        }
    }
    return self;
}

- (BOOL)saveChanges {
    NSMutableArray *fileIDsArray = [NSMutableArray array];
    for (NSString *path in self.pathsToRemove) {
        NSDictionary *node = [self nodeForPath:path];
        if (node) {
            [fileIDsArray addObject:node[@"/hash"]];
        }
        BOOL deleted = [[NSFileManager defaultManager] removeItemAtPath:node[@"/realPath"] error:NULL];
        NSLog(@"File %@ deleted? %@", node[@"/realPath"], deleted ? @"Y" : @"N");
    }
    NSString *fileIDs = [NSString stringWithFormat:@"\"%@\"", [fileIDsArray componentsJoinedByString:@"\",\""]];
    
    NSString *manifetsDbPath = [self.backupPath stringByAppendingPathComponent:@"Manifest.db"];
    
    NSPipe *pipe = [NSPipe pipe];
    NSFileHandle *file = pipe.fileHandleForReading;
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/sqlite3";
    task.arguments = @[
        manifetsDbPath,
        @"-csv",
        @"-bail",
        @"-cmd", [NSString stringWithFormat:@"delete from Files where fileID in (%@)", fileIDs],
        @"-cmd", @".quit"
    ];
    task.standardOutput = pipe;
    [task launch];
    NSData *outputData = [file readDataToEndOfFile];
    [file closeFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding: NSASCIIStringEncoding];
    NSLog(@"%@", output);
    
    self.pathsToRemove = nil;
    return YES;
}

- (void)discardChanges {
    self.pathsToRemove = nil;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSDictionary *node = [self nodeForPath:path];
    NSArray *arr = [node.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return ![name hasPrefix:@"/"];
    }]];
    return arr;
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error
{
    if ([path isEqualToString:@"/"]) {
        return @{
            NSFileType: NSFileTypeDirectory,
        };
    }
    
    NSDictionary *node = [self nodeForPath:path];
    if (!node || [node[@"/del"] boolValue]) {
        return nil;
    }
    
//    BOOL isFile = [node.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *item, NSDictionary<NSString *,id> * _Nullable bindings) {
//        return ![item hasPrefix:@"/"];
//    }]].count == 0;
    
    return @{
        NSFileType: node[@"/file"] ? NSFileTypeRegular : NSFileTypeDirectory,
        NSFileSize: node[@"/length"] ?: @0,
        NSFileModificationDate: node[@"/mdate"] ?: [NSDate dateWithTimeIntervalSince1970:0],
        NSFileCreationDate: node[@"/cdate"] ?: [NSDate dateWithTimeIntervalSince1970:0],
    };
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    NSMutableDictionary *node = [self growTreeToPath:path];
    node[@"/del"] = @YES;
    [self.pathsToRemove addObject:path];
    if (self.wasModifiedBlock)
        self.wasModifiedBlock();
    return YES;
}

/*
- (NSData *)contentsAtPath:(NSString *)path
{
    NSDictionary *node = [self growTreeToPath:path];
    NSString *filename = [self realPathToNode:node];
    return [NSData dataWithContentsOfFile:filename];
}*/

- (BOOL)openFileAtPath:(NSString *)path
                  mode:(int)mode
              userData:(id *)userData
                 error:(NSError **)error
{
    if (mode == O_RDONLY)
    {
        NSDictionary *node = [self nodeForPath:path];
        int fd = open([node[@"/realPath"] UTF8String], mode);
        if (fd < 0) {
            if (error)
                *error = [NSError errorWithDomain:@"errno" code:errno userInfo:nil];
            return NO;
        }
        *userData = @(fd);
        return YES;
    }
    
    return NO;
}

- (int)readFileAtPath:(NSString *)path
             userData:(id)userData
               buffer:(char *)buffer
                 size:(size_t)size
               offset:(off_t)offset
                error:(NSError **)error
{
    int fd = [userData intValue];
    lseek(fd, offset, SEEK_SET);
    return (int)read(fd, buffer, size);
}

- (void)releaseFileAtPath:(NSString *)path userData:(id)userData
{
    NSNumber* num = (NSNumber *)userData;
    int fd = [num intValue];
    close(fd);
}

@end
