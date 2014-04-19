//
//  ABFileSystem.m
//  iBackupMounter
//
//  Created by Антон Буков on 16.04.14.
//  Copyright (c) 2014 Codeless Solutions. All rights reserved.
//

#include <CommonCrypto/CommonDigest.h>
#import <OSXFUSE/OSXFUSE.h>
#import "ABFileSystem.h"

static NSString *helloStr = @"Hello World!\n";
static NSString *helloPath = @"/hello.txt";

@implementation NSData (ByteAt)
- (NSInteger)byteAt:(NSInteger)index
{
    return ((unsigned char *)self.bytes)[index];
}
- (NSInteger)wordAt:(NSInteger)index
{
    return ([self byteAt:index] << 8) + [self byteAt:index+1];
}
- (NSInteger)intAt:(NSInteger)index
{
    return ([self wordAt:index] << 16) + [self wordAt:index+2];
}
- (int64_t)longAt:(NSInteger)index
{
    return (((uint64_t)[self intAt:index]) << 32) + [self intAt:index+4];
}
- (NSString *)stringWithHex
{
    NSString *result = [[self description] stringByReplacingOccurrencesOfString:@" " withString:@""];
    result = [result substringWithRange:NSMakeRange(1, [result length] - 2)];
    return result;
}
@end

@interface ABFileSystem ()
@property (strong, nonatomic) NSString *backupPath;
@property (strong, nonatomic) NSMutableDictionary *tree;
@property (strong, nonatomic) NSMutableDictionary *treeReadOnly;
@property (strong, nonatomic) NSMutableArray *pathsToRemove;
@property (strong, nonatomic) NSMutableArray *nodesToRemove;
@property (strong, nonatomic) NSMutableDictionary *datasToAdd;

@property (strong, nonatomic) NSArray *networks;
@end

@implementation ABFileSystem

- (NSMutableDictionary *)tree
{
    if (_tree == nil)
        _tree = [NSMutableDictionary dictionary];
    return _tree;
}

- (NSMutableDictionary *)treeReadOnly
{
    if (_treeReadOnly == nil) {
        _treeReadOnly = [NSMutableDictionary dictionary];
        _treeReadOnly[@"/"] = self.tree[@"/"];
    }
    return _treeReadOnly;
}

- (NSMutableArray *)pathsToRemove
{
    if (_pathsToRemove == nil)
        _pathsToRemove = [NSMutableArray array];
    return _pathsToRemove;
}

- (NSMutableArray *)nodesToRemove
{
    if (_nodesToRemove == nil)
        _nodesToRemove = [NSMutableArray array];
    return _nodesToRemove;
}

- (NSMutableDictionary *)datasToAdd
{
    if (_datasToAdd == nil)
        _datasToAdd = [NSMutableDictionary dictionary];
    return _datasToAdd;
}

- (NSArray *)networks
{
    if (_networks == nil)
    {
        NSDictionary *node = [self growTreeToPath:@"/SystemPreferencesDomain/SystemConfiguration/com.apple.wifi.plist"];
        NSString *path = [self realPathToNode:node];
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

- (NSString *)sha1:(NSString *)text
{
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *stringBytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (CC_SHA1(stringBytes.bytes, (uint32_t)stringBytes.length, digest))
        return [[NSData dataWithBytes:digest length:sizeof(digest)] stringWithHex];
    return nil;
}

- (NSMutableDictionary *)growTreeToPath:(NSString *)path
{
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

- (NSDictionary *)nodeForPath:(NSString *)path
{
    //return [self growTreeToPath:path];
    return self.treeReadOnly[path];
}

- (NSString *)readString:(NSData *)data offset:(NSInteger *)offset
{
    NSInteger length = [self readWord:data offset:offset];
    if (length == 0xFFFF)
        return @"";
    *offset += length;
    return [[NSString alloc] initWithBytes:data.bytes+*offset-length length:length encoding:NSUTF8StringEncoding];
}

- (NSInteger)readByte:(NSData *)data offset:(NSInteger *)offset
{
    *offset += 1;
    return [data byteAt:*offset-1];
}

- (NSInteger)readWord:(NSData *)data offset:(NSInteger *)offset
{
    *offset += 2;
    return [data wordAt:*offset-2];
}

- (NSInteger)readInt:(NSData *)data offset:(NSInteger *)offset
{
    *offset += 4;
    return [data intAt:*offset-4];
}

- (NSInteger)readLong:(NSData *)data offset:(NSInteger *)offset
{
    *offset += 8;
    return [data longAt:*offset-8];
}

- (instancetype)initWithBackupPath:(NSString *)backupPath
{
    if (self = [super init])
    {
        self.backupPath = backupPath;
        
        NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:[backupPath stringByAppendingPathComponent:@"Status.plist"]];
        if (![status[@"SnapshotState"] isEqualToString:@"finished"])
            [NSException raise:@"Backup is not finished yet" format:@""];
        
        NSData *data = [NSMutableData dataWithContentsOfFile:[backupPath stringByAppendingPathComponent:@"Manifest.mbdb"]];
        if ([data byteAt:0] != 'm'
            || [data byteAt:1] != 'b'
            || [data byteAt:2] != 'd'
            || [data byteAt:3] != 'b'
            || [data byteAt:4] != '\x05'
            || [data byteAt:5] != '\x00')
        {
            [NSException raise:@"Invalid Manifest.mbdb magic header" format:@""];
        }
        
        NSInteger offset = 6;
        while (offset < data.length)
        {
            NSInteger begin_offset = offset;
            NSString *domain = [self readString:data offset:&offset];
            NSString *path = [self readString:data offset:&offset];
            NSString *linkTarget = [self readString:data offset:&offset];
            NSString *dataHash = [self readString:data offset:&offset];
            NSString *encryptionKey = [self readString:data offset:&offset];
            NSInteger mode = [self readWord:data offset:&offset];
            uint64_t inode = [self readLong:data offset:&offset];
            NSInteger uid = [self readInt:data offset:&offset];
            NSInteger gid = [self readInt:data offset:&offset];
            NSInteger mtime = [self readInt:data offset:&offset];
            NSInteger atime = [self readInt:data offset:&offset];
            NSInteger ctime = [self readInt:data offset:&offset];
            
            uint64_t length = [self readLong:data offset:&offset];
            NSInteger protection = [self readByte:data offset:&offset];
            NSInteger propertyCount = [self readByte:data offset:&offset];
            
            for (NSInteger i = 0; i < propertyCount; i++) {
                NSString *name = [self readString:data offset:&offset];
                NSString *value = [self readString:data offset:&offset];
                
                /*NSMutableDictionary *node = [self growTreeToPath:[path stringByAppendingPathComponent:name]];
                node[@"/mode"] = @(mode);
                node[@"/file"] = @YES;
                */
                //NSLog(@"Property %@ = %@",name,value);
            }
            
            NSString *key = nil;
            if (mode & 0x8000)
                key = @"/file";
            else if (mode & 0x4000)
                key = @"/dir";
            else
                continue;
            
            NSString *virtualPath = domain;
            if ([virtualPath rangeOfString:@"AppDomain-"].location != NSNotFound) {
                virtualPath = [virtualPath stringByReplacingOccurrencesOfString:@"AppDomain-" withString:@"AppDomain/"];
                if (self.tree[@"/"][@"AppDomain"] == nil) {
                    NSMutableDictionary *appNode = [self growTreeToPath:@"/AppDomain"];
                    self.treeReadOnly[virtualPath] = appNode;
                    appNode[@"/length"] = @(length);
                    appNode[@"/mode"] = @(mode);
                    appNode[@"/domain"] = domain;
                    appNode[@"/path"] = path;
                    appNode[@"/mdate"] = [NSDate dateWithTimeIntervalSince1970:mtime];
                    appNode[@"/cdate"] = [NSDate dateWithTimeIntervalSince1970:ctime];
                    appNode[@"/rec_offset"] = @(begin_offset);
                    appNode[@"/rec_length"] = @(offset-begin_offset);
                    appNode[@"/dir"] = @YES;
                }
            }
            virtualPath = [virtualPath stringByAppendingPathComponent:path];
            virtualPath = [@"/" stringByAppendingString:virtualPath];
            NSMutableDictionary *node = [self growTreeToPath:virtualPath];
            self.treeReadOnly[virtualPath] = node;
            node[@"/length"] = @(length);
            node[@"/mode"] = @(mode);
            node[@"/domain"] = domain;
            node[@"/path"] = path;
            node[@"/mdate"] = [NSDate dateWithTimeIntervalSince1970:mtime];
            node[@"/cdate"] = [NSDate dateWithTimeIntervalSince1970:ctime];
            node[@"/rec_offset"] = @(begin_offset);
            node[@"/rec_length"] = @(offset-begin_offset);
            node[key] = @YES;
            //NSLog(@"File %@ %@ %@", path, @(length), @(propertyCount));
        }
        self.tree[@"/"][@"AppDomain"][@"/dir"] = @YES;
        self.tree[@"/"][@"AppDomain"][@"/dir"] = @YES;
        self.tree[@"/"][@"AppDomain"][@"/dir"] = @YES;
        self.tree[@"/"][@"AppDomain"][@"/dir"] = @YES;
        self.treeReadOnly[@"/AppDomain"] = self.tree[@"/"][@"AppDomain"];
    }
    return self;
}

- (BOOL)saveChanges
{
    [self.nodesToRemove sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [b[@"/rec_offset"] compare:a[@"/rec_offset"]];
    }];
    NSString *manifestPath = [self.backupPath stringByAppendingPathComponent:@"Manifest.mbdb"];
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:manifestPath];
    for (NSDictionary *node in self.nodesToRemove) {
        [data replaceBytesInRange:NSMakeRange([node[@"rec_offset"] integerValue], [node[@"rec_length"] integerValue]) withBytes:NULL length:0];
    }
    if (![data writeToFile:manifestPath atomically:YES])
        return NO;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSDictionary *node in self.nodesToRemove)
        [fileManager removeItemAtPath:[self realPathToNode:node] error:NULL];
    
    self.nodesToRemove = nil;
    self.pathsToRemove = nil;
    return YES;
}

- (void)discardChanges
{
    self.nodesToRemove = nil;
    self.pathsToRemove = nil;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary *node = [self nodeForPath:path];
    NSArray *arr = [[node allKeys] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return [name characterAtIndex:0] != '/';
    }]];
    NSArray *arr2 = [self.datasToAdd.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        NSRange range = [name rangeOfString:path];
        return (range.location == 0)
            && ([[name substringFromIndex:range.length]
                 componentsSeparatedByString:@"/"].count-1 == 1);
    }]];
    return [arr arrayByAddingObjectsFromArray:arr2];
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error
{
    if ([path isEqualToString:@"/"])
        return @{NSFileType:NSFileTypeDirectory};
    
    //NSLog(@"Attributes for file %@", path);
    NSDictionary *node = [self nodeForPath:path];
    if (!node) {
        NSData *data = self.datasToAdd[path];
        if (data == nil)
            return nil;
        node = [self growTreeToPath:path];
        return @{NSFileType:node[@"/file"] ? NSFileTypeRegular : NSFileTypeDirectory,
                 NSFileSize:@(data.length),
                 NSFileModificationDate:[NSDate date],
                 NSFileCreationDate:node[@"/cdate"]};
    }
    return @{NSFileType:node[@"/file"] ? NSFileTypeRegular : NSFileTypeDirectory,
             NSFileSize:node[@"/length"],
             NSFileModificationDate:node[@"/mdate"],
             NSFileCreationDate:node[@"/cdate"]};
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary *node = [self nodeForPath:path];
    NSInteger offset = [node[@"/rec_offset"] integerValue];
    NSInteger length = [node[@"/rec_length"] integerValue];
    if (length == 0)
        return NO;
    
    NSLog(@"Delete file %@", path);
    [self.nodesToRemove addObject:node];
    [self.pathsToRemove addObject:path];
    [self.treeReadOnly removeObjectForKey:path];
    
    if (self.wasModifiedBlock)
        self.wasModifiedBlock();
    return YES;
}

- (NSString *)realPathToNode:(NSDictionary *)node
{
    return [self.backupPath stringByAppendingPathComponent:[self sha1:[NSString stringWithFormat:@"%@-%@",node[@"/domain"],node[@"/path"]]]];
}
/*
- (NSData *)contentsAtPath:(NSString *)path
{
    NSDictionary *node = [self growTreeToPath:path];
    NSString *filename = [self realPathToNode:node];
    return [NSData dataWithContentsOfFile:filename];
}
*/
- (BOOL)createFileAtPath:(NSString *)path
              attributes:(NSDictionary *)attributes
                userData:(id *)userData
                   error:(NSError **)error
{
    NSInteger index = [self.pathsToRemove indexOfObject:path];
    if (index == NSNotFound) {
        NSString *lpc = [path lastPathComponent];
        path = [path stringByDeletingLastPathComponent];
        path = [path stringByAppendingPathComponent:[lpc substringFromIndex:2]];
        index = [self.pathsToRemove indexOfObject:path];
        if (index != NSNotFound) {
            NSLog(@"Create file hidden %@", path);
            return YES;
        }
        return NO;
    }
    
    NSLog(@"Create file %@", path);
    //NSDictionary *node = self.nodesToRemove[index];
    //int fd = open([[self realPathToNode:node] UTF8String], O_WRONLY);
    char name[] = "/tmp/iBackupMounter.XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) {
        if (error)
            *error = [NSError errorWithDomain:@"errno" code:errno userInfo:nil];
        return NO;
    }
    *userData = @(fd);
    self.datasToAdd[path] = [NSMutableData data];
    return YES;
}

- (BOOL)moveItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 error:(NSError **)error
{
    return NO;
}

- (BOOL)exchangeDataOfItemAtPath:(NSString *)path1
                  withItemAtPath:(NSString *)path2
                           error:(NSError **)error
{
    return NO;
}

- (BOOL)openFileAtPath:(NSString *)path
                  mode:(int)mode
              userData:(id *)userData
                 error:(NSError **)error
{
    if (mode == O_RDONLY)
    {
        NSLog(@"Open file read %@", path);
        NSDictionary *node = [self nodeForPath:path];
        if (node == nil && self.datasToAdd[path])
            return YES;
        int fd = open([[self realPathToNode:node] UTF8String], mode);
        if (fd < 0) {
            if (error)
                *error = [NSError errorWithDomain:@"errno" code:errno userInfo:nil];
            return NO;
        }
        *userData = @(fd);
        return YES;
    }
    
    if (mode == O_WRONLY)
    {
        NSInteger index = [self.pathsToRemove indexOfObject:path];
        if (index == NSNotFound) {
            /*
             NSString *lpc = [path lastPathComponent];
             path = [path stringByDeletingLastPathComponent];
             path = [path stringByAppendingPathComponent:[lpc substringFromIndex:2]];
             index = [self.pathsToRemove indexOfObject:path];
             if (index != NSNotFound) {
             NSLog(@"Create file hidden %@", path);
             return YES;
             }*/
            return NO;
        }
        
        NSLog(@"Open file write %@", path);
        //NSDictionary *node = self.nodesToRemove[index];
        //int fd = open([[self realPathToNode:node] UTF8String], O_WRONLY);
        char name[] = "/tmp/iBackupMounter.XXXXXX";
        int fd = mkstemp(name);
        if (fd < 0) {
            if (error)
                *error = [NSError errorWithDomain:@"errno" code:errno userInfo:nil];
            return NO;
        }
        *userData = @(fd);
        self.datasToAdd[path] = [NSMutableData data];
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
    NSLog(@"Read file %@", path);
    int fd = [userData intValue];
    lseek(fd, offset, SEEK_SET);
    return (int)read(fd, buffer, size);
}

- (int)writeFileAtPath:(NSString *)path
              userData:(id)userData
                buffer:(const char *)buffer
                  size:(size_t)size
                offset:(off_t)offset
                 error:(NSError **)error
{
    NSMutableData *data = self.datasToAdd[path];
    if (data == nil)
        return -1;
    
    NSLog(@"Write file %@", path);
    [data replaceBytesInRange:NSMakeRange(offset,0) withBytes:buffer length:size];
    return (int)size;
}

- (void)releaseFileAtPath:(NSString *)path userData:(id)userData
{
    NSLog(@"Close file %@", path);
    NSNumber* num = (NSNumber *)userData;
    int fd = [num intValue];
    close(fd);
}


@end
