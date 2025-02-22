/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>
#import <XCTestBootstrap/FBCodeCoverageConfiguration.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Describes the client's request for code coverage collection.
 */
@interface FBCodeCoverageRequest : NSObject

/**
 Whether or not to collect code coverage
 */
@property (nonatomic, assign, readonly) BOOL collect;

/**
  Format in which code coverge data should be returned
*/
@property (nonatomic, assign, readonly) FBCodeCoverageFormat format;

- (instancetype)initWithCollect:(BOOL)collect format:(FBCodeCoverageFormat)format;

@end

NS_ASSUME_NONNULL_END
