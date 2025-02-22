/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBDataConsumer.h"

#import "FBCollectionInformation.h"
#import "FBControlCoreError.h"
#import "FBControlCoreLogger.h"
#import "FBDataBuffer.h"

@interface FBDataConsumerAdaptor ()

+ (dispatch_data_t)adaptNSData:(NSData *)dispatchData;

@end

@interface FBDataConsumerAdaptor_ToNSData : NSObject <FBDispatchDataConsumer>

@property (nonatomic, strong, readonly) id<FBDataConsumer> consumer;

@end

@implementation FBDataConsumerAdaptor_ToNSData

#pragma mark Initializers

- (instancetype)initWithConsumer:(id<FBDataConsumer>)consumer
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _consumer = consumer;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(dispatch_data_t)dispatchData
{
  NSData *data = [FBDataConsumerAdaptor adaptDispatchData:dispatchData];
  [self.consumer consumeData:data];
}

- (void)consumeEndOfFile
{
  [self.consumer consumeEndOfFile];
}

@end

@interface FBDataConsumerAdaptor_ToDispatchData : NSObject <FBDataConsumer, FBDataConsumerLifecycle>

@property (nonatomic, strong, readonly) id<FBDispatchDataConsumer, FBDataConsumerLifecycle> consumer;

@end

@implementation FBDataConsumerAdaptor_ToDispatchData

#pragma mark Initializers

- (instancetype)initWithConsumer:(id<FBDispatchDataConsumer, FBDataConsumerLifecycle>)consumer
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _consumer = consumer;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  dispatch_data_t dispatchData = [FBDataConsumerAdaptor adaptNSData:data];
  [self.consumer consumeData:dispatchData];
}

- (void)consumeEndOfFile
{
  [self.consumer consumeEndOfFile];
}

- (FBFuture<NSNull *> *)finishedConsuming
{
  return self.consumer.finishedConsuming;
}

@end

@implementation FBDataConsumerAdaptor

#pragma mark Initializers

+ (id<FBDispatchDataConsumer>)dispatchDataConsumerForDataConsumer:(id<FBDataConsumer>)consumer;
{
  return [[FBDataConsumerAdaptor_ToNSData alloc] initWithConsumer:consumer];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle>)dataConsumerForDispatchDataConsumer:(id<FBDispatchDataConsumer, FBDataConsumerLifecycle>)consumer;
{
  return [[FBDataConsumerAdaptor_ToDispatchData alloc] initWithConsumer:consumer];
}

#pragma mark Public

+ (NSData *)adaptDispatchData:(dispatch_data_t)dispatchData
{
  // One-way bridging of dispatch_data_t to NSData is permitted.
  // Since we can't safely assume all consumers of the NSData work discontiguous ranges, we have to make the dispatch_data contiguous.
  // This is done with dispatch_data_create_map, which is 0-copy for a contiguous range but copies for non-contiguous ranges.
  // https://twitter.com/catfish_man/status/393032222808100864
  // https://developer.apple.com/library/archive/releasenotes/Foundation/RN-Foundation-older-but-post-10.8/
  return (NSData *) dispatch_data_create_map(dispatchData, NULL, NULL);
}

#pragma mark Private

+ (dispatch_data_t)adaptNSData:(NSData *)data __attribute__((no_sanitize("nullability-arg")))
{
  // The safest possible way of adapting the NSData to dispatch_data_t is to ensure that buffer backing the dispatch_data_t data is:
  // 1) Immutable
  // 2) Is not freed until the dispatch_data_t is destroyed.
  // There are two ways of doing this:
  // 1) Copy the NSData, and retain it for the lifecycle of the dispatch_data_t.
  // 2) Use DISPATCH_DATA_DESTRUCTOR_DEFAULT which will copy the underlying buffer.
  // This uses #2 as it's preferable to let libdispatch do the management itself and avoids an object copy (NSData) as well as a potential buffer copy in `-[NSData copy]`.
  // It can be quite surprising how many methods result in the creation of NSMutableData, for example `-[NSString dataUsingEncoding:]` can result in NSConcreteMutableData.
  // By copying the buffer we are sure that the data in the dispatch wrapper is completely immutable.
  return dispatch_data_create(
    data.bytes,
    data.length,
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
    DISPATCH_DATA_DESTRUCTOR_DEFAULT
  );
}

@end

typedef void (^dataBlock)(NSData *);
static inline dataBlock FBDataConsumerToStringConsumer (void(^consumer)(NSString *)) {
  return ^(NSData *data){
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (line == nil) {
      line = @"non-utf8";
    }
    consumer(line);
  };
}

@interface FBBlockDataConsumer_Dispatcher : NSObject <FBDataConsumer>

@property (nonatomic, strong, nullable, readwrite) dispatch_queue_t queue;
@property (nonatomic, strong, nullable, readwrite) dispatch_group_t group;
@property (nonatomic, copy, nullable, readwrite) void (^consumer)(NSData *);
@property (atomic, readonly) int64_t numPendingTasks;

@end

@implementation FBBlockDataConsumer_Dispatcher

- (instancetype)initWithQueue:(dispatch_queue_t)queue consumer:(void (^)(NSData *))consumer
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _queue = queue;
  _group = dispatch_group_create();
  _consumer = consumer;
  _numPendingTasks = 0;

  return self;
}

- (void)consumeData:(NSData *)data
{
  void (^consumer)(NSData *) = nil;
  dispatch_queue_t queue;
  dispatch_group_t group;
  OSAtomicIncrement64(&_numPendingTasks);
  @synchronized (self)
  {
    consumer = self.consumer;
    queue = self.queue;
    group = self.group;
    if (!consumer) {
      return;
    }
    if (queue) {
      dispatch_group_async(group, queue, ^{
        consumer(data);
        OSAtomicDecrement64(&self->_numPendingTasks);
      });
    } else {
      consumer(data);
      OSAtomicDecrement64(&_numPendingTasks);
    }
  }
}

- (void)consumeEndOfFile
{
  dispatch_group_t group;
  @synchronized (self)
  {
    group = self.group;
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    self.group = nil;
    self.consumer = nil;
    self.queue = nil;
  }
}

@end

@interface FBBlockDataConsumer () <FBDataConsumer, FBDataConsumerLifecycle>

@property (nonatomic, strong, readonly) FBBlockDataConsumer_Dispatcher *dispatcher;

@end

@interface FBBlockDataConsumerAsync : NSObject <FBDataConsumer, FBDataConsumerLifecycle, FBDataConsumerAsync>

@property (nonatomic, strong, readonly) FBBlockDataConsumer_Dispatcher *dispatcher;

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher;

@end

@interface FBBlockDataConsumer_Buffered : FBBlockDataConsumer

@property (nonatomic, strong, readonly) id<FBConsumableBuffer> buffer;

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher terminal:(NSData *)terminal;

@end

@interface FBBlockDataConsumer_Unbuffered : FBBlockDataConsumer

@property (nonatomic, strong, readonly) FBMutableFuture<NSNull *> *finishedConsumingFuture;

@end

@interface FBBlockDataConsumerAsync_Unbuffered : FBBlockDataConsumerAsync

@property (nonatomic, strong, readonly) FBMutableFuture<NSNull *> *finishedConsumingFuture;

@end

@implementation FBBlockDataConsumer

#pragma mark Initializers

+ (id<FBDataConsumer, FBDataConsumerLifecycle>)synchronousDataConsumerWithBlock:(void (^)(NSData *))consumer
{
  FBBlockDataConsumer_Dispatcher *dispatcher = [[FBBlockDataConsumer_Dispatcher alloc] initWithQueue:nil consumer:consumer];
  return [[FBBlockDataConsumer_Unbuffered alloc] initWithDispatcher:dispatcher];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle>)synchronousLineConsumerWithBlock:(void (^)(NSString *))consumer
{
  FBBlockDataConsumer_Dispatcher *dispatcher = [[FBBlockDataConsumer_Dispatcher alloc] initWithQueue:nil consumer:FBDataConsumerToStringConsumer(consumer)];
  return [[FBBlockDataConsumer_Buffered alloc] initWithDispatcher:dispatcher terminal:FBDataBuffer.newlineTerminal];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle, FBDataConsumerAsync>)asynchronousDataConsumerOnQueue:(dispatch_queue_t)queue consumer:(void (^)(NSData *))consumer
{
  FBBlockDataConsumer_Dispatcher *dispatcher = [[FBBlockDataConsumer_Dispatcher alloc] initWithQueue:queue consumer:consumer];
  return [[FBBlockDataConsumerAsync_Unbuffered alloc] initWithDispatcher:dispatcher];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle, FBDataConsumerAsync>)asynchronousDataConsumerWithBlock:(void (^)(NSData *))consumer
{
  dispatch_queue_t queue = dispatch_queue_create("com.facebook.FBControlCore.BlockDataConsumer.data", DISPATCH_QUEUE_SERIAL);
  return [self asynchronousDataConsumerOnQueue:queue consumer:consumer];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle>)asynchronousLineConsumerWithBlock:(void (^)(NSString *))consumer
{
  dispatch_queue_t queue = dispatch_queue_create("com.facebook.FBControlCore.BlockDataConsumer.lines", DISPATCH_QUEUE_SERIAL);
  FBBlockDataConsumer_Dispatcher *dispatcher = [[FBBlockDataConsumer_Dispatcher alloc] initWithQueue:queue consumer:FBDataConsumerToStringConsumer(consumer)];
  return [[FBBlockDataConsumer_Buffered alloc] initWithDispatcher:dispatcher terminal:FBDataBuffer.newlineTerminal];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle>)asynchronousLineConsumerWithQueue:(dispatch_queue_t)queue consumer:(void (^)(NSString *))consumer
{
  FBBlockDataConsumer_Dispatcher *dispatcher = [[FBBlockDataConsumer_Dispatcher alloc] initWithQueue:queue consumer:FBDataConsumerToStringConsumer(consumer)];
  return [[FBBlockDataConsumer_Buffered alloc] initWithDispatcher:dispatcher terminal:FBDataBuffer.newlineTerminal];
}

+ (id<FBDataConsumer, FBDataConsumerLifecycle>)asynchronousLineConsumerWithQueue:(dispatch_queue_t)queue dataConsumer:(void (^)(NSData *))consumer
{
  FBBlockDataConsumer_Dispatcher *dispatcher = [[FBBlockDataConsumer_Dispatcher alloc] initWithQueue:queue consumer:consumer];
  return [[FBBlockDataConsumer_Buffered alloc] initWithDispatcher:dispatcher terminal:FBDataBuffer.newlineTerminal];
}

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _dispatcher = dispatcher;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
}

- (void)consumeEndOfFile
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
}

#pragma mark FBDataConsumerLifecycle

- (FBFuture<NSNull *> *)finishedConsuming
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
  return nil;
}

@end


@implementation FBBlockDataConsumerAsync

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _dispatcher = dispatcher;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
}

- (void)consumeEndOfFile
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
}

#pragma mark FBDataConsumerLifecycle

- (FBFuture<NSNull *> *)finishedConsuming
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
  return nil;
}

#pragma mark FBDataConsumerAsync

- (NSInteger)unprocessedDataCount
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
  return 0;
}

@end


@implementation FBBlockDataConsumer_Buffered

#pragma mark Initializers

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher terminal:(NSData *)terminal
{
  self = [super initWithDispatcher:dispatcher];
  if (!self) {
    return nil;
  }

  _buffer = [FBDataBuffer consumableBufferForwardingToConsumer:dispatcher onQueue:nil terminal:terminal];

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  @synchronized (self) {
    [self.buffer consumeData:data];
  }
}

- (void)consumeEndOfFile
{
  @synchronized (self) {
    [self.buffer consumeEndOfFile];
  }
}

#pragma mark FBDataConsumerLifecycle

- (FBFuture<NSNull *> *)finishedConsuming
{
  return self.buffer.finishedConsuming;
}

@end

@implementation FBBlockDataConsumer_Unbuffered

#pragma mark Initializers

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher
{
  self = [super initWithDispatcher:dispatcher];
  if (!self) {
    return nil;
  }

  _finishedConsumingFuture = FBMutableFuture.future;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  @synchronized (self) {
    [self.dispatcher consumeData:data];
  }
}

- (void)consumeEndOfFile
{
  @synchronized (self) {
    [self.dispatcher consumeEndOfFile];
    [self.finishedConsumingFuture resolveWithResult:NSNull.null];
  }
}

#pragma mark FBDataConsumerLifecycle

- (FBFuture<NSNull *> *)finishedConsuming
{
  return self.finishedConsumingFuture;
}

@end

@implementation FBBlockDataConsumerAsync_Unbuffered

#pragma mark Initializers

- (instancetype)initWithDispatcher:(FBBlockDataConsumer_Dispatcher *)dispatcher
{
  self = [super initWithDispatcher:dispatcher];
  if (!self) {
    return nil;
  }

  _finishedConsumingFuture = FBMutableFuture.future;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  @synchronized (self) {
    [self.dispatcher consumeData:data];
  }
}

- (void)consumeEndOfFile
{
  @synchronized (self) {
    [self.dispatcher consumeEndOfFile];
    [self.finishedConsumingFuture resolveWithResult:NSNull.null];
  }
}

#pragma mark FBDataConsumerLifecycle

- (FBFuture<NSNull *> *)finishedConsuming
{
  return self.finishedConsumingFuture;
}

#pragma mark FBDataConsumerAsync

- (NSInteger)unprocessedDataCount
{
  // not synchronized on purpose
  // as processing data happens on a different thread
  // so we cannot be accurate anyway
  return self.dispatcher.numPendingTasks;
}

@end

@implementation FBLoggingDataConsumer

#pragma mark Initializers

+ (instancetype)consumerWithLogger:(id<FBControlCoreLogger>)logger
{
  return [[self alloc] initWithLogger:logger];
}

- (instancetype)initWithLogger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _logger = logger;

  return self;
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!string) {
    return;
  }
  string = [string stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
  if (string.length < 1) {
    return;
  }
  [self.logger log:string];
}

- (void)consumeEndOfFile
{

}

@end

@interface FBCompositeDataConsumer ()

@property (nonatomic, copy, readonly) NSArray<id<FBDataConsumer>> *consumers;
@property (nonatomic, strong, readonly) FBMutableFuture<NSNull *> *finishedConsumingFuture;

@end

@implementation FBCompositeDataConsumer

#pragma mark Initializers

+ (instancetype)consumerWithConsumers:(NSArray<id<FBDataConsumer>> *)consumers
{
  return [[self alloc] initWithConsumers:consumers];
}

- (instancetype)initWithConsumers:(NSArray<id<FBDataConsumer>> *)consumers
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _consumers = consumers;
  _finishedConsumingFuture = FBMutableFuture.future;

  return self;
}

#pragma mark NSObject

- (NSString *)description
{
  return [NSString stringWithFormat:@"Composite Consumer %@", [FBCollectionInformation oneLineDescriptionFromArray:self.consumers]];
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  for (id<FBDataConsumer> consumer in self.consumers) {
    [consumer consumeData:data];
  }
}

- (void)consumeEndOfFile
{
  for (id<FBDataConsumer> consumer in self.consumers) {
    [consumer consumeEndOfFile];
  }
  [self.finishedConsumingFuture resolveWithResult:NSNull.null];
}

#pragma mark FBDataConsumerLifecycle

- (FBFuture<NSNull *> *)finishedConsuming
{
  return self.finishedConsumingFuture;
}

@end

@implementation FBNullDataConsumer

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
}

- (void)consumeEndOfFile
{

}

@end
