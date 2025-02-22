/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBDeviceDebugServer.h"

#import <FBControlCore/FBControlCore.h>

#import "FBAMDServiceConnection.h"

@interface FBDeviceDebugServer_TwistedPairFiles : NSObject

@property (nonatomic, assign, readonly) int source;
@property (nonatomic, strong, readonly) FBAMDServiceConnection *sink;
@property (nonatomic, strong, readonly) dispatch_queue_t queue;
@property (nonatomic, strong, readonly) dispatch_queue_t sinkWriteQueue;
@property (nonatomic, strong, readonly) dispatch_queue_t sinkReadQueue;

@property (nonatomic, strong, nullable, readwrite) id<FBDataConsumer> sourceWriter;
@property (nonatomic, strong, nullable, readwrite) id<FBFileReader> sourceReader;
@property (nonatomic, strong, nullable, readwrite) id<FBDataConsumer> sinkWriter;
@property (nonatomic, strong, nullable, readwrite) id<FBFileReader> sinkReader;

@end

@implementation FBDeviceDebugServer_TwistedPairFiles

- (instancetype)initWithSource:(int)source sink:(FBAMDServiceConnection *)sink queue:(dispatch_queue_t)queue
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _source = source;
  _sink = sink;
  _queue = queue;
  _sinkWriteQueue = dispatch_queue_create("com.facebook.fbdevicecontrol.debugserver_sink_write", DISPATCH_QUEUE_SERIAL);
  _sinkReadQueue = dispatch_queue_create("com.facebook.fbdevicecontrol.debugserver_sink_read", DISPATCH_QUEUE_SERIAL);

  return self;
}

- (FBFuture<FBFuture<NSNull *> *> *)start
{
  NSError *error = nil;
  id<FBDataConsumer, FBDataConsumerLifecycle> sourceWriter = [FBFileWriter asyncWriterWithFileDescriptor:self.source closeOnEndOfFile:NO error:&error];
  if (!sourceWriter) {
    return [FBFuture futureWithError:error];
  }
  self.sourceWriter = sourceWriter;
  self.sinkWriter = [self.sink writeWithConsumerWritingOnQueue:self.sinkWriteQueue];
  self.sourceReader = [FBFileReader readerWithFileDescriptor:self.source closeOnEndOfFile:NO consumer:self.sinkWriter logger:nil];
  self.sinkReader = [self.sink readFromConnectionWritingToConsumer:self.sourceWriter onQueue:self.sinkReadQueue];
  return [[FBFuture
    futureWithFutures:@[
      [self.sourceReader startReading],
      [self.sinkReader startReading],
    ]]
    onQueue:self.queue map:^(id _) {
      return [[FBFuture
        race:@[
          self.sourceReader.finishedReading,
          self.sinkReader.finishedReading,
        ]]
        mapReplace:NSNull.null];
    }];
}

@end

@interface FBDeviceDebugServer () <FBSocketServerDelegate>

@property (nonatomic, strong, readonly) FBAMDServiceConnection *serviceConnection;
@property (nonatomic, strong, readonly) FBSocketServer *tcpServer;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;

@property (nonatomic, strong, readwrite) FBMutableFuture<NSNull *> *teardown;
@property (nonatomic, strong, nullable, readwrite) FBDeviceDebugServer_TwistedPairFiles *twistedPair;

@end

@implementation FBDeviceDebugServer

@synthesize queue = _queue;
@synthesize lldbBootstrapCommands = _lldbBootstrapCommands;

#pragma mark Initializers

+ (FBFuture<FBDeviceDebugServer *> *)debugServerForServiceConnection:(FBFutureContext<FBAMDServiceConnection *> *)service port:(in_port_t)port lldbBootstrapCommands:(NSArray<NSString *> *)lldbBootstrapCommands queue:(dispatch_queue_t)queue logger:(id<FBControlCoreLogger>)logger
{
  return [[service
    onQueue:queue push:^(FBAMDServiceConnection *serviceConnection) {
      FBDeviceDebugServer *server = [[FBDeviceDebugServer alloc] initWithServiceConnection:serviceConnection port:port lldbBootstrapCommands:lldbBootstrapCommands queue:queue logger:logger];
      return [server startListening];
    }]
    onQueue:queue enter:^(FBDeviceDebugServer *server, FBMutableFuture<NSNull *> *teardown) {
      server.teardown = teardown;
      return server;
    }];
}

- (instancetype)initWithServiceConnection:(FBAMDServiceConnection *)serviceConnection port:(in_port_t)port lldbBootstrapCommands:(NSArray<NSString *> *)lldbBootstrapCommands queue:(dispatch_queue_t)queue logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _serviceConnection = serviceConnection;
  _tcpServer = [FBSocketServer socketServerOnPort:port delegate:self];
  _lldbBootstrapCommands = lldbBootstrapCommands;
  _queue = queue;
  _logger = logger;

  return self;
}

#pragma mark FBSocketReaderDelegate

- (void)socketServer:(FBSocketServer *)server clientConnected:(struct in6_addr)address fileDescriptor:(int)fileDescriptor
{
  if (self.twistedPair) {
    [self.logger log:@"Rejecting connection, we have an existing pair"];
    NSData *data = [@"$NEUnspecified#00" dataUsingEncoding:NSASCIIStringEncoding];
    write(fileDescriptor, data.bytes, data.length);
    close(fileDescriptor);
    return;
  }
  [self.logger log:@"Client connected, connecting all file handles"];
  self.twistedPair = [[FBDeviceDebugServer_TwistedPairFiles alloc] initWithSource:fileDescriptor sink:self.serviceConnection queue:self.queue];
  [[[self.twistedPair
    start]
    onQueue:self.queue fmap:^(FBFuture<NSNull *> *finished) {
      [self.logger log:@"File handles connected"];
      return finished;
    }]
    onQueue:self.queue notifyOfCompletion:^(id _) {
      [self.logger log:@"Client Disconnected"];
      self.twistedPair = nil;
    }];
}

#pragma mark FBiOSTargetOperation

- (FBFuture<NSNull *> *)completed
{
  return self.teardown;
}

#pragma mark Private Methods

- (FBFutureContext<FBDeviceDebugServer *> *)startListening
{
  return [[self.tcpServer
    startListeningContext]
    onQueue:self.queue pend:^(NSNull *_) {
      [self.logger logFormat:@"TCP Server now running, boostrap commands for lldb are %@", [self.lldbBootstrapCommands componentsJoinedByString:@"\n"]];
      return [FBFuture futureWithResult:self];
    }];
}


@end
