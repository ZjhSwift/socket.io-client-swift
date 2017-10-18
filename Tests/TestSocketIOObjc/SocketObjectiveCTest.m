//
//  SocketObjectiveCTest.m
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/25/16.
//
//  Merely tests whether the Objective-C api breaks
//

@import Dispatch;
@import Foundation;
@import XCTest;
@import SocketIO;

@interface SocketObjectiveCTest : XCTestCase

@property SocketIOClient* socket;
@property SocketManager* manager;

@end

// TODO Manager interface tests

@implementation SocketObjectiveCTest

- (void)setUp {
    [super setUp];
    NSURL* url = [[NSURL alloc] initWithString:@"http://localhost"];
    self.manager = [[SocketManager alloc] initWithSocketURL:url config:nil];
    self.socket = [self.manager defaultSocket];
}

- (void)testProperties {
    self.socket.nsp = @"/objective-c";
    if (self.socket.status == SocketIOStatusConnected) { }
}

- (void)testOnSyntax {
    [self.socket on:@"someCallback" callback:^(NSArray* data, SocketAckEmitter* ack) {
        [ack with:@[@1]];
    }];
}

- (void)testConnectSyntax {
    [self.socket connect];
}

- (void)testConnectTimeoutAfterSyntax {
    [self.socket connectWithTimeoutAfter:1 withHandler: ^() { }];
}

- (void)testDisconnectSyntax {
    [self.socket disconnect];
}

- (void)testLeaveNamespaceSyntax {
    [self.socket leaveNamespace];
}

- (void)testJoinNamespaceSyntax {
    [self.socket joinNamespace];
}

- (void)testOnAnySyntax {
    [self.socket onAny:^(SocketAnyEvent* any) {
        NSString* event = any.event;
        NSArray* data = any.items;

        [self.socket emit:event with:data];
    }];
}

- (void)testRemoveAllHandlersSyntax {
    [self.socket removeAllHandlers];
}

- (void)testEmitSyntax {
    [self.socket emit:@"testEmit" with:@[@YES]];
}

- (void)testEmitWithAckSyntax {
    [[self.socket emitWithAck:@"testAckEmit" with:@[@YES]] timingOutAfter:0 callback:^(NSArray* data) { }];
}

- (void)testOffSyntax {
    [self.socket off:@"test"];
}

- (void)testSocketManager {
    SocketClientManager* manager = [SocketClientManager sharedManager];
    [manager addSocket:self.socket labeledAs:@"test"];
    [manager removeSocketWithLabel:@"test"];
}

- (void)testSSLSecurity {
    SSLSecurity* sec = [[SSLSecurity alloc] initWithUsePublicKeys:0];
    sec = nil;
}

@end
