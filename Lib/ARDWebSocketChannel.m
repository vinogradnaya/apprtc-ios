/*
 * libjingle
 * Copyright 2014, Google Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *  2. Redistributions in binary form must reproduce the above copyright notice,
 *     this list of conditions and the following disclaimer in the documentation
 *     and/or other materials provided with the distribution.
 *  3. The name of the author may not be used to endorse or promote products
 *     derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ARDWebSocketChannel.h"

#import "ARDUtilities.h"
#import "SRWebSocket.h"

// TODO(tkchin): move these to a configuration object.
static NSString const *kARDWSSMessageErrorKey = @"error";
static NSString const *kARDWSSMessagePayloadKey = @"signal";

@interface ARDWebSocketChannel () <SRWebSocketDelegate>
@end

@implementation ARDWebSocketChannel {
  NSURL *_url;
  SRWebSocket *_socket;
}

@synthesize delegate = _delegate;
@synthesize state = _state;

- (instancetype)initWithURL:(NSURL *)url
                   delegate:(id<ARDWebSocketChannelDelegate>)delegate {
  if (self = [super init]) {
    _isInitiator = NO;
    _state = kARDWebSocketChannelStateClosed;
    _url = url;
    _delegate = delegate;
    _socket = [[SRWebSocket alloc] initWithURL:url];
    _socket.delegate = self;
    NSLog(@"Opening WebSocket.");
    [_socket open];
  }
  return self;
}

- (void)dealloc {
  [self disconnect];
}

- (void)setState:(ARDWebSocketChannelState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate channel:self didChangeState:_state];
}

#pragma mark - Public

- (void)registerForRoomId:(NSString *)roomId initiate:(BOOL)initiate {
  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDWebSocketChannelStateOpen);

    NSLog(@"%s", __PRETTY_FUNCTION__);
    NSLog(@"Registering on WSS for rid:%@", roomId);

    NSDictionary *registerMessage = @{
                                      @"signal": initiate? @"create" : @"join",
                                      @"content" : roomId,
                                      @"to" : [NSNull null]
                                      };
    NSData *message =
    [NSJSONSerialization dataWithJSONObject:registerMessage
                                    options:NSJSONWritingPrettyPrinted
                                      error:nil];
    [self sendData:message];
}

- (void)sendData:(NSData *)data {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    if (_socket.readyState == SR_OPEN) {
        NSString *messageString =
        [[NSString alloc] initWithData:data
                              encoding:NSUTF8StringEncoding];

        NSLog(@"C->WSS: %@", messageString);
        [_socket send:messageString];
    }
}

- (void)disconnect {
  if (_state == kARDWebSocketChannelStateClosed ||
      _state == kARDWebSocketChannelStateError) {
    return;
  }
    NSLog(@"C->WSS DELETE rid:%@", _roomId);
  [_socket close];
}

#pragma mark - SRWebSocketDelegate

- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  NSLog(@"WebSocket connection opened.");
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  NSString *messageString = message;
  NSData *messageData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
  id jsonObject = [NSJSONSerialization JSONObjectWithData:messageData
                                                  options:0
                                                    error:nil];
  if (![jsonObject isKindOfClass:[NSDictionary class]]) {
    NSLog(@"Unexpected message: %@", jsonObject);
    return;
  }
  NSDictionary *wssMessage = jsonObject;
  NSString *errorString = wssMessage[kARDWSSMessageErrorKey];
  if (errorString.length) {
    NSLog(@"WSS error: %@", errorString);
    return;
  }

  NSLog(@"WSS->C: %@", message);

  ARDSignalingMessage *signalingMessage =
      [ARDSignalingMessage messageFromJSONString:message];
    if (signalingMessage.type == kARDSignalingMessageTypeCreated ||
        signalingMessage.type == kARDSignalingMessageTypeJoined) {
        self.state = kARDWebSocketChannelStateRegistered;
    }
    if (signalingMessage.type == kARDSignalingMessageTypePing &&
        self.state == kARDWebSocketChannelStateClosed) {
        self.state = kARDWebSocketChannelStateOpen;
    }
  [_delegate channel:self didReceiveMessage:signalingMessage];
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
  NSLog(@"WebSocket error: %@", error);
  self.state = kARDWebSocketChannelStateError;
}

- (void)webSocket:(SRWebSocket *)webSocket
    didCloseWithCode:(NSInteger)code
              reason:(NSString *)reason
            wasClean:(BOOL)wasClean {
  NSLog(@"WebSocket closed with code: %ld reason:%@ wasClean:%d",
      (long)code, reason, wasClean);
  NSParameterAssert(_state != kARDWebSocketChannelStateError);
  self.state = kARDWebSocketChannelStateClosed;
}

@end
