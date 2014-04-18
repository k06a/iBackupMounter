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
@property (strong, nonatomic) NSMutableArray *pathsToRemove;
@property (strong, nonatomic) NSMutableArray *rangesToRemove;

@property (strong, nonatomic) NSArray *networks;
@end

@implementation ABFileSystem

- (NSMutableDictionary *)tree
{
    if (_tree == nil)
        _tree = [NSMutableDictionary dictionary];
    return _tree;
}

- (NSMutableArray *)pathsToRemove
{
    if (_pathsToRemove == nil)
        _pathsToRemove = [NSMutableArray array];
    return _pathsToRemove;
}

- (NSMutableArray *)rangesToRemove
{
    if (_rangesToRemove == nil)
        _rangesToRemove = [NSMutableArray array];
    return _rangesToRemove;
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
            return [b[@"lastJoined"] compare:a[@"lastJoined"]];
        }];
        
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
        for (id network in nets) {
            [arr addObject:[NSString stringWithFormat:@"%@ => %@",
                            [dateFormatter stringFromDate:network[@"lastJoined"]],
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
    if ([path isEqualToString:@"/"])
        return self.tree;
    if (path.length > 1 && [path characterAtIndex:0] == '/')
        path = [path substringFromIndex:1];
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
            if ([virtualPath rangeOfString:@"AppDomain-"].location != NSNotFound)
                virtualPath = [virtualPath stringByReplacingOccurrencesOfString:@"AppDomain-" withString:@"AppDomain/"];
            virtualPath = [virtualPath stringByAppendingPathComponent:path];
            NSMutableDictionary *node = [self growTreeToPath:virtualPath];
            node[@"/length"] = @(length);
            node[@"/mode"] = @(mode);
            node[@"/domain"] = domain;
            node[@"/path"] = path;
            node[@"/mdate"] = @(mtime);
            node[@"/cdate"] = @(ctime);
            node[@"/rec_offset"] = @(begin_offset);
            node[@"/rec_length"] = @(offset-begin_offset);
            node[key] = @YES;
            //NSLog(@"File %@ %@ %@", path, @(length), @(propertyCount));
        }
    }
    return self;
}

- (BOOL)saveChanges
{
    [self.rangesToRemove sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [@([b rangeValue].location) compare:@([a rangeValue].location)];
    }];
    NSString *manifestPath = [self.backupPath stringByAppendingPathComponent:@"Manifest.mbdb"];
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:manifestPath];
    for (NSValue *value in self.rangesToRemove)
        [data replaceBytesInRange:value.rangeValue withBytes:NULL length:0];
    if (![data writeToFile:manifestPath atomically:YES])
        return NO;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *filename in self.pathsToRemove)
        [fileManager removeItemAtPath:filename error:NULL];
    
    self.rangesToRemove = nil;
    self.pathsToRemove = nil;
    return YES;
}

- (void)discardChanges
{
    self.rangesToRemove = nil;
    self.pathsToRemove = nil;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary *node = [self growTreeToPath:path];
    NSArray *arr = [[node allKeys] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return [name characterAtIndex:0] != '/';
    }]];
    return arr;
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error
{
    if ([path isEqualToString:@"/"])
        return @{NSFileType:NSFileTypeDirectory};
    if ([path isEqualToString:@"/AppDomain"])
        return @{NSFileType:NSFileTypeDirectory};
    
    NSDictionary *node = [self growTreeToPath:path];
    return @{NSFileType:node[@"/file"] ? NSFileTypeRegular : NSFileTypeDirectory,
             NSFileSize:node[@"/length"],
             NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:[node[@"/mdate"] doubleValue]],
             NSFileCreationDate:[NSDate dateWithTimeIntervalSince1970:[node[@"/cdate"] doubleValue]]};
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary *node = [self growTreeToPath:path];
    NSInteger offset = [node[@"/rec_offset"] integerValue];
    NSInteger length = [node[@"/rec_length"] integerValue];
    if (length == 0)
        return NO;
    
    [self.rangesToRemove addObject:[NSValue valueWithRange:NSMakeRange(offset, length)]];
    [self.pathsToRemove addObject:[self realPathToNode:node]];
    NSMutableDictionary *parentNode = [self growTreeToPath:[path stringByDeletingLastPathComponent]];
    if (parentNode != node)
        [parentNode removeObjectForKey:[path lastPathComponent]];
    if (self.wasModifiedBlock)
        self.wasModifiedBlock();
    return YES;
}

- (NSString *)realPathToNode:(NSDictionary *)node
{
    return [self.backupPath stringByAppendingPathComponent:[self sha1:[NSString stringWithFormat:@"%@-%@",node[@"/domain"],node[@"/path"]]]];
}

- (NSData *)contentsAtPath:(NSString *)path
{
    NSDictionary *node = [self growTreeToPath:path];
    NSString *filename = [self realPathToNode:node];
    return [NSData dataWithContentsOfFile:filename];
}

@end
