//
// Copyright © 2019 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <Foundation/Foundation.h>
#import "QEMUHelperProtocol.h"

typedef void * _Nullable (* _Nonnull UTMQemuThreadEntry)(void * _Nullable args);

@class UTMQemuConfiguration;
@class UTMLogging;

NS_ASSUME_NONNULL_BEGIN

@interface UTMQemu : NSObject

@property (nonatomic, readonly) BOOL hasRemoteProcess;
@property (nonatomic, readonly) NSURL *libraryURL;
@property (nonatomic) NSArray<NSString *> *argv;
@property (nonatomic) dispatch_semaphore_t done;
@property (nonatomic) NSInteger status;
@property (nonatomic) NSInteger fatal;
@property (nonatomic) UTMQemuThreadEntry entry;
@property (nonatomic, nullable) UTMLogging *logging;

- (instancetype)init;
- (instancetype)initWithArgv:(NSArray<NSString *> *)argv;
- (instancetype)initWithArgv:(NSArray<NSString *> *)argv  printArgv:(bool)printArgv NS_DESIGNATED_INITIALIZER;
- (void)pushArgv:(nullable NSString *)arg;
- (void)clearArgv;
- (void)startQemu:(nonnull NSString *)name completion:(void(^)(BOOL,NSString * _Nullable))completion;
- (void)stopQemu;
- (void)accessDataWithBookmark:(NSData *)bookmark;
- (void)accessDataWithBookmark:(NSData *)bookmark securityScoped:(BOOL)securityScoped completion:(void(^)(BOOL, NSData * _Nullable, NSString * _Nullable))completion;
- (void)stopAccessingPath:(nullable NSString *)path;

@end

NS_ASSUME_NONNULL_END
