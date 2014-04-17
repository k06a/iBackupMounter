//
//  ABFileSystem.h
//  iBackupMounter
//
//  Created by Антон Буков on 16.04.14.
//  Copyright (c) 2014 Codeless Solutions. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface ABFileSystem : NSObject

- (instancetype)initWithBackupPath:(NSString *)backupPath;

@property (strong, nonatomic) void(^wasModifiedBlock)();
@property (readonly, nonatomic) NSArray *networks;

- (BOOL)saveChanges;
- (void)discardChanges;

@end
