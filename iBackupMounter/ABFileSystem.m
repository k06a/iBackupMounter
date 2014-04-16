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
@end

@implementation ABFileSystem

- (NSMutableDictionary *)tree
{
    if (_tree == nil)
        _tree = [NSMutableDictionary dictionary];
    return _tree;
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
        if (!node[token])
            node[token] = [NSMutableDictionary dictionary];
        node = node[token];
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
        
        NSData *data = [NSData dataWithContentsOfFile:[backupPath stringByAppendingPathComponent:@"Manifest.mbdb"]];
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
        while (offset < data.length) {
            NSString *domain = [self readString:data offset:&offset];
            NSString *path = [self readString:data offset:&offset];
            NSString *linkTarget = [self readString:data offset:&offset];
            NSString *dataHash = [self readString:data offset:&offset];
            NSString *encryptionKey = [self readString:data offset:&offset];
            NSInteger mode = [self readWord:data offset:&offset];
            NSInteger inode = [self readInt:data offset:&offset];
            NSInteger unknown = [self readInt:data offset:&offset];
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
                */NSLog(@"Property %@ = %@",name,value);
            }
            
            NSString *virtualPath = domain;
            if ([virtualPath rangeOfString:@"AppDomain-"].location != NSNotFound)
                virtualPath = [virtualPath stringByReplacingOccurrencesOfString:@"AppDomain-" withString:@"AppDomain/"];
            virtualPath = [virtualPath stringByAppendingPathComponent:path];
            NSMutableDictionary *node = [self growTreeToPath:virtualPath];
            node[@"/length"] = @(length);
            node[@"/mode"] = @(mode);
            node[@"/domain"] = domain;
            node[@"/path"] = path;
            NSLog(@"File %@ %@ %@", path, @(length), @(propertyCount));
        }
        
    }
    return self;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSDictionary *node = [self growTreeToPath:path];
    NSArray *arr = [[node allKeys] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return [name characterAtIndex:0] != '/';
    }]];
    return arr;
    //return [NSArray arrayWithObject:[helloPath lastPathComponent]];
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error
{
    if ([path isEqualToString:@"/"])
        return @{NSFileType:NSFileTypeDirectory};
    
    NSDictionary *node = [self growTreeToPath:path];
    if ([node[@"/length"] integerValue] > 0)
        return @{NSFileType:NSFileTypeRegular,
                 NSFileSize:node[@"/length"]};
    
    return @{NSFileType:NSFileTypeDirectory};
}

- (NSData *)contentsAtPath:(NSString *)path {
    NSDictionary *node = [self growTreeToPath:path];
    NSString *filename = [self sha1:[NSString stringWithFormat:@"%@-%@",node[@"/domain"],node[@"/path"]]];
    return [NSData dataWithContentsOfFile:[self.backupPath stringByAppendingPathComponent:filename]];
}

@end
