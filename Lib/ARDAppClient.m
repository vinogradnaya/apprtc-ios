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

#import "ARDAppClient.h"

#import <AVFoundation/AVFoundation.h>

#import "ARDMessageResponse.h"
#import "ARDRegisterResponse.h"
#import "ARDSignalingMessage.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCICECandidate+JSON.h"
#import "RTCICEServer+JSON.h"
#import "RTCMediaConstraints.h"
#import "RTCMediaStream.h"
#import "RTCPair.h"
#import "RTCPeerConnection.h"
#import "RTCPeerConnectionDelegate.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCSessionDescription+JSON.h"
#import "RTCSessionDescriptionDelegate.h"
#import "RTCVideoCapturer.h"
#import "RTCVideoTrack.h"
#import "RTCDataChannel.h"

// needed to make TURN work
static NSString *kARDServerHostURL = @"https://apprtc.appspot.com";

static NSString *kARDDefaultSTUNServerUrl =
    @"stun:stun.l.google.com:19302";
// TODO(tkchin): figure out a better username for CEOD statistics.

static NSString *kARDTurnRequestUrl =
@"https://computeengineondemand.appspot.com"
@"/turn?username=iapprtc&key=4080218913";

#warning PROVIDE YOUR SIGNALING SERVER URL
static NSString *kARDWebSocketUrl = ;

static NSString *kARDAppClientErrorDomain = @"ARDAppClient";
static NSInteger kARDAppClientErrorCreateSDP = -1;
static NSInteger kARDAppClientErrorSetSDP = -2;
static NSInteger kARDAppClientErrorNetwork = -3;

@interface ARDAppClient () <ARDWebSocketChannelDelegate,
    RTCPeerConnectionDelegate, RTCSessionDescriptionDelegate>
@property(nonatomic, strong) RTCDataChannel *dataChannel;
@property(nonatomic, strong) ARDWebSocketChannel *channel;
@property(nonatomic, strong) RTCPeerConnection *peerConnection;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) NSMutableArray *messageQueue;

@property(nonatomic, assign) BOOL hasReceivedSdp;
@property(nonatomic, assign) BOOL isTURNComplete;
@property(nonatomic, readonly) BOOL isRegisteredWithRoomServer;

@property(nonatomic, strong) NSString *roomId;
@property(nonatomic, strong) NSString *clientId;
@property(nonatomic, strong) NSError *webSocketError;
@property(nonatomic, strong) NSString *peerId;
@property(nonatomic, assign) BOOL isInitiator;
@property(nonatomic, assign) BOOL isSpeakerEnabled;
@property(nonatomic, strong) NSMutableArray *iceServers;
@property(nonatomic, strong) RTCAudioTrack *defaultAudioTrack;
@property(nonatomic, strong) RTCVideoTrack *defaultVideoTrack;
@property(nonatomic, strong) dispatch_group_t initGroup;
@end

@implementation ARDAppClient

@synthesize delegate = _delegate;
@synthesize state = _state;
@synthesize channel = _channel;
@synthesize peerConnection = _peerConnection;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize isSpeakerEnabled = _isSpeakerEnabled;
@synthesize iceServers = _iceServers;
@synthesize initGroup = _initGroup;

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
  if (self = [super init]) {
    _delegate = delegate;
    _factory = [[RTCPeerConnectionFactory alloc] init];
    _messageQueue = [NSMutableArray array];
    _iceServers = [NSMutableArray arrayWithObject:[self defaultSTUNServer]];
    _isSpeakerEnabled = YES;

      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(orientationChanged:)
                                                   name:@"UIDeviceOrientationDidChangeNotification"
                                                 object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIDeviceOrientationDidChangeNotification" object:nil];
  [self disconnect];
}

- (void)orientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsLandscape(orientation) || UIDeviceOrientationIsPortrait(orientation)) {
        //Remove current video track
        RTCMediaStream *localStream = _peerConnection.localStreams[0];
        [localStream removeVideoTrack:localStream.videoTracks[0]];
        
        RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
        if (localVideoTrack) {
            [localStream addVideoTrack:localVideoTrack];
            [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
        }
        [_peerConnection removeStream:localStream];
        [_peerConnection addStream:localStream];
    }
}


- (void)setState:(ARDAppClientState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate appClient:self didChangeState:_state];
}

- (void)connectToRoomWithId:(NSString *)roomId isInitiator:(BOOL)isInitiator{
    NSLog(@"%s", __PRETTY_FUNCTION__);

  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDAppClientStateDisconnected);

    // Create connection
    self.state = kARDAppClientStateConnecting;
    self.isInitiator = isInitiator;
    self.roomId = roomId;

    __block NSError *turnRequestError = nil;

    dispatch_group_t downloadGroup = _initGroup = dispatch_group_create();

    //Open WebSocket Connection
    dispatch_group_enter(downloadGroup);
    [self openWebSocketConnection];

    //Request TURN.
    dispatch_group_enter(downloadGroup);
    __weak ARDAppClient *weakSelf = self;
    NSURL *turnRequestURL = [NSURL URLWithString:kARDTurnRequestUrl];
    [self requestTURNServersWithURL:turnRequestURL
                  completionHandler:^(NSArray *turnServers, NSError *error) {
                      ARDAppClient *strongSelf = weakSelf;
                      [strongSelf.iceServers addObjectsFromArray:turnServers];
                      strongSelf.isTURNComplete = YES;
                      if (error) {
                          NSDictionary *userInfo = @{
                                                     NSLocalizedDescriptionKey:
                                                         @"Failed to receive TURN servers.",
                                                     };
                          turnRequestError =
                          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                                     code:kARDAppClientErrorNetwork
                                                 userInfo:userInfo];
                      }
                      NSLog(@"RECEIVED TURN %@ error %@", turnServers, turnRequestError);
                      dispatch_group_leave(downloadGroup);
                  }];

    dispatch_group_notify(downloadGroup, dispatch_get_main_queue(), ^{
        // Register with room server.
        if (!turnRequestError && !self.webSocketError) {
            [self registerForRoom];
        } else {
        // Error occured. Disconnecting
            NSLog(@"Failed to establish connection");
            [self disconnect];
            [self.delegate appClient:self
                            didError:turnRequestError? turnRequestError : self.webSocketError];
        }
    });
}

- (void)disconnect {
  if (_state == kARDAppClientStateDisconnected) {
    return;
  }
  if (_channel) {
    if (_channel.state == kARDWebSocketChannelStateRegistered) {
      // Tell the other client we're hanging up.
      ARDByeMessage *byeMessage = [[ARDByeMessage alloc] initWithPeer:self.peerId];
      NSData *byeData = [byeMessage JSONData];
      [_channel sendData:byeData];
    }
    // Disconnect from collider.
    _channel = nil;
  }
  _clientId = nil;
  _roomId = nil;
  _peerId = nil;
  _isInitiator = NO;
  _hasReceivedSdp = NO;
  _isTURNComplete = NO;
  _messageQueue = [NSMutableArray array];
  _peerConnection = nil;
  _initGroup = nil;
  _webSocketError = nil;
  self.state = kARDAppClientStateDisconnected;
}

#pragma mark - ARDWebSocketChannelDelegate

- (void)channel:(ARDWebSocketChannel *)channel
    didReceiveMessage:(ARDSignalingMessage *)message {
    NSLog(@"%s", __PRETTY_FUNCTION__);

  switch (message.type) {
      case kARDSignalingMessageTypeOfferRequest:
          self.isInitiator = YES;
          self.peerId = ((ARDOfferRequestMessage *)message).from;
          self.clientId = ((ARDOfferRequestMessage *)message).to;
          [self startSignalingIfReady];
          return;
    case kARDSignalingMessageTypeAnswerRequest:
          _hasReceivedSdp = YES;
          self.peerId = ((ARDAnswerRequestMessage *)message).from;
          self.clientId = ((ARDAnswerRequestMessage *)message).to;
          if (!_peerConnection) {
              [self createPeerConnection];
          }
          [_messageQueue insertObject:message atIndex:0];
          break;
    case kARDSignalingMessageTypeCandidate:
          [_messageQueue addObject:message];
          break;
    case kARDSignalingMessageTypeFinalize:
          _hasReceivedSdp = YES;
          [_messageQueue insertObject:message atIndex:0];
          break;
    case kARDSignalingMessageTypePeerLeft:
          [self processSignalingMessage:message];
          return;
    default:
          return;
  }
  [self drainMessageQueueIfReady];
}

- (void)channel:(ARDWebSocketChannel *)channel
    didChangeState:(ARDWebSocketChannelState)state {
    NSLog(@"%s", __PRETTY_FUNCTION__);

  switch (state) {
    case kARDWebSocketChannelStateOpen:
          if (self.state == kARDAppClientStateConnecting) {
              self.state = kARDAppClientStateConnected;
              dispatch_group_leave(_initGroup);
          }
      break;
    case kARDWebSocketChannelStateClosed:
    case kARDWebSocketChannelStateError:
      // TODO(tkchin): reconnection scenarios. Right now we just disconnect
      // completely if the websocket connection fails.
          NSLog(@"disconnected");
          if (self.state == kARDAppClientStateConnecting) {
              self.state = kARDAppClientStateFailedToConnect;
              NSDictionary *userInfo = @{
                                         NSLocalizedDescriptionKey:
                                             @"Failed to establish WebSocket connection.",
                                         };
              self.webSocketError =
              [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorNetwork
                                     userInfo:userInfo];
              dispatch_group_leave(_initGroup);
          } else {
              [self disconnect];
          }
      break;
    default:
          break;
  }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    signalingStateChanged:(RTCSignalingState)stateChanged {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
           addedStream:(RTCMediaStream *)stream {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"Received %lu video tracks and %lu audio tracks",
        (unsigned long)stream.videoTracks.count,
        (unsigned long)stream.audioTracks.count);
    if (stream.videoTracks.count) {
      RTCVideoTrack *videoTrack = stream.videoTracks[0];
      [_delegate appClient:self didReceiveRemoteVideoTrack:videoTrack];
      if (_isSpeakerEnabled) [self enableSpeaker]; //Use the "handsfree" speaker instead of the ear speaker.

    }
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
        removedStream:(RTCMediaStream *)stream {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  NSLog(@"Stream was removed.");
}

- (void)peerConnectionOnRenegotiationNeeded:
    (RTCPeerConnection *)peerConnection {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  NSLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    iceConnectionChanged:(RTCICEConnectionState)newState {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    NSLog(@"ICE state changed: %@", newState == 4? @"ICE FAILED" : @"NEW STATE");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    iceGatheringChanged:(RTCICEGatheringState)newState {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  NSLog(@"ICE gathering state changed: %d", newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
       gotICECandidate:(RTCICECandidate *)candidate {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateMessage *message =
        [[ARDICECandidateMessage alloc] initWithCandidate:candidate peer:self.peerId];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection*)peerConnection
    didOpenDataChannel:(RTCDataChannel*)dataChannel {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

#pragma mark - RTCSessionDescriptionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didCreateSessionDescription:(RTCSessionDescription *)sdp
                          error:(NSError *)error {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    NSLog(@"%@", sdp);

  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to create session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to create session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorCreateSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    [_peerConnection setLocalDescriptionWithDelegate:self
                                  sessionDescription:sdp];
//    ARDSessionDescriptionMessage *message =
//        [[ARDSessionDescriptionMessage alloc] initWithDescription:sdp];
      ARDSignalingMessage *message = nil;
      if (self.isInitiator) {
          message = [[ARDOfferResponseMessage alloc] initWithTo:self.peerId description:sdp];
      } else {
          message = [[ARDAnswerResponseMessage alloc] initWithTo:self.peerId description:sdp];
      }
      //send offer
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didSetSessionDescriptionWithError:(NSError *)error {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to set session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to set session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorSetSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    // If we're answering and we've just set the remote offer we need to create
    // an answer and set the local description.
    if (!_isInitiator && !_peerConnection.localDescription) {
        NSLog(@"Peer Connection Create answer");
      RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
      [_peerConnection createAnswerWithDelegate:self
                                    constraints:constraints];

    }
  });
}

#pragma mark - RTCDataChannelDelegate

- (void)channelDidChangeState:(RTCDataChannel*)channel {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

// Called when a data buffer was successfully received.
- (void)channel:(RTCDataChannel*)channel
didReceiveMessageWithBuffer:(RTCDataBuffer*)buffer {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    NSString* message = [[NSString alloc] initWithData:buffer.data encoding:NSUTF8StringEncoding];

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"NEW MESSAGE"
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles: nil];
    [alert show];
}

#pragma mark - Private

- (BOOL)isRegisteredWithRoomServer {
    return _channel.state == kARDWebSocketChannelStateRegistered;
}

- (void)startSignalingIfReady {
  if (!self.isInitiator ||
      !self.isTURNComplete ||
      ![self isRegisteredWithRoomServer]) {
      return;
  }

    NSLog(@"%s", __PRETTY_FUNCTION__);
    [self createPeerConnection];
    [self sendOffer];
}

- (void)createPeerConnection
{
    if (_peerConnection != nil) {
        return;
    }

    // Create peer connection.
    RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
    _peerConnection = [_factory peerConnectionWithICEServers:_iceServers
                                                 constraints:constraints
                                                    delegate:self];
    RTCMediaStream *localStream = [self createLocalMediaStream];
    [_peerConnection addStream:localStream];

//    [self setupDataChannelWithPeerConnection:_peerConnection];
}

- (void)sendOffer {
    NSLog(@"%s", __PRETTY_FUNCTION__);
  [_peerConnection createOfferWithDelegate:self
                               constraints:[self defaultOfferConstraints]];
}

//- (void)waitForAnswer {
//    NSLog(@"%s", __PRETTY_FUNCTION__);
//  [self drainMessageQueueIfReady];
//}

- (void)drainMessageQueueIfReady {
  if (!_peerConnection || !_hasReceivedSdp) {
    return;
  }
    NSLog(@"%s", __PRETTY_FUNCTION__);
  for (ARDSignalingMessage *message in _messageQueue) {
    [self processSignalingMessage:message];
  }
  [_messageQueue removeAllObjects];
}

- (void)processSignalingMessage:(ARDSignalingMessage *)message {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    NSLog(@"%i", message.type);

  NSParameterAssert(_peerConnection ||
      message.type == kARDSignalingMessageTypePeerLeft);
  switch (message.type) {
    case kARDSignalingMessageTypeAnswerRequest:
    case kARDSignalingMessageTypeFinalize:{
        RTCSessionDescription *description = nil;
        if (self.isInitiator) {
            ARDAnswerRequestMessage *sdpMessage = (ARDAnswerRequestMessage *)message;
            description = sdpMessage.sessionDescription;
        } else {
            ARDFinalizeMessage *sdpMessage = (ARDFinalizeMessage *)message;
            description = sdpMessage.sessionDescription;
        }
      [_peerConnection setRemoteDescriptionWithDelegate:self
                                     sessionDescription:description];
      break;
    }
    case kARDSignalingMessageTypeCandidate: {
      ARDICECandidateMessage *candidateMessage =
          (ARDICECandidateMessage *)message;
        NSLog(@"DID RECEIVE CANDIDATE %@", candidateMessage.candidate);
      [_peerConnection addICECandidate:candidateMessage.candidate];
      break;
    }
    case kARDSignalingMessageTypePeerLeft:
      // Other client disconnected.
      // TODO(tkchin): support waiting in room for next client. For now just
      // disconnect.
      [self disconnect];
      break;
    default:
          break;

  }
}

- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    [self sendSignalingMessageToCollider:message];
}

- (RTCVideoTrack *)createLocalVideoTrack {
    // The iOS simulator doesn't provide any sort of camera capture
    // support or emulation (http://goo.gl/rHAnC1) so don't bother
    // trying to open a local stream.
    // TODO(tkchin): local video capture for OSX. See
    // https://code.google.com/p/webrtc/issues/detail?id=3417.

    RTCVideoTrack *localVideoTrack = nil;
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE

    NSString *cameraID = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionFront) {
            cameraID = [captureDevice localizedName];
            break;
        }
    }
    NSAssert(cameraID, @"Unable to get the front camera id");
    
    RTCVideoCapturer *capturer = [RTCVideoCapturer capturerWithDeviceName:cameraID];
    RTCMediaConstraints *mediaConstraints = [self defaultMediaStreamConstraints];
    RTCVideoSource *videoSource = [_factory videoSourceWithCapturer:capturer constraints:mediaConstraints];
    localVideoTrack = [_factory videoTrackWithID:@"ARDAMSv0" source:videoSource];
#endif
    return localVideoTrack;
}

- (RTCMediaStream *)createLocalMediaStream {
    RTCMediaStream* localStream = [_factory mediaStreamWithLabel:@"ARDAMS"];

    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    
    [localStream addAudioTrack:[_factory audioTrackWithID:@"ARDAMSa0"]];
    if (_isSpeakerEnabled) [self enableSpeaker];
    return localStream;
}

- (void)requestTURNServersWithURL:(NSURL *)requestURL
    completionHandler:(void (^)(NSArray *turnServers, NSError *turnError))completionHandler {
  NSParameterAssert([requestURL absoluteString].length);
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:requestURL];
  // We need to set origin because TURN provider whitelists requests based on
  // origin.
  [request addValue:@"Mozilla/5.0" forHTTPHeaderField:@"user-agent"];
  [request addValue:kARDServerHostURL forHTTPHeaderField:@"origin"];

  [NSURLConnection sendAsyncRequest:request
                  completionHandler:^(NSURLResponse *response,
                                      NSData *data,
                                      NSError *error) {
    NSArray *turnServers = [NSArray array];
    if (error) {
      NSLog(@"Unable to get TURN server.");
      completionHandler(turnServers, error);
      return;
    }
    NSDictionary *dict = [NSDictionary dictionaryWithJSONData:data];
    turnServers = [RTCICEServer serversFromCEODJSONDictionary:dict];
    completionHandler(turnServers, error);
  }];
}

#pragma mark - Collider methods

- (void)openWebSocketConnection {
    NSLog(@"%s", __PRETTY_FUNCTION__);

  // Open WebSocket connection.
    NSURL *websocketURL = [NSURL URLWithString:kARDWebSocketUrl];
  _channel = [[ARDWebSocketChannel alloc] initWithURL:websocketURL
                                             delegate:self];
}

- (void)registerForRoom {
    [_channel registerForRoomId:_roomId initiate:self.isInitiator];
}

- (void)sendSignalingMessageToCollider:(ARDSignalingMessage *)message {
  NSData *data = [message JSONData];
  [_channel sendData:data];
}

#pragma mark - Defaults

- (RTCMediaConstraints *)defaultMediaStreamConstraints {
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultAnswerConstraints {
  return [self defaultOfferConstraints];
}

- (RTCMediaConstraints *)defaultOfferConstraints {
  NSArray *mandatoryConstraints = @[
      [[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"],
      [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"true"]
  ];
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:mandatoryConstraints
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
  NSArray *optionalConstraints = @[
      [[RTCPair alloc] initWithKey:@"DtlsSrtpKeyAgreement" value:@"true"]
  ];
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:optionalConstraints];
  return constraints;
}

- (RTCICEServer *)defaultSTUNServer {
  NSURL *defaultSTUNServerURL = [NSURL URLWithString:kARDDefaultSTUNServerUrl];
  return [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL
                                  username:@""
                                  password:@""];
}

#pragma mark - Audio mute/unmute
- (void)muteAudioIn {
    NSLog(@"audio muted");
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    self.defaultAudioTrack = localStream.audioTracks[0];
    [localStream removeAudioTrack:localStream.audioTracks[0]];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}
- (void)unmuteAudioIn {
    NSLog(@"audio unmuted");
    RTCMediaStream* localStream = _peerConnection.localStreams[0];
    [localStream addAudioTrack:self.defaultAudioTrack];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
    if (_isSpeakerEnabled) [self enableSpeaker];
}

#pragma mark - Video mute/unmute
- (void)muteVideoIn {
    NSLog(@"video muted");
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    self.defaultVideoTrack = localStream.videoTracks[0];
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}
- (void)unmuteVideoIn {
    NSLog(@"video unmuted");
    RTCMediaStream* localStream = _peerConnection.localStreams[0];
    [localStream addVideoTrack:self.defaultVideoTrack];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}

#pragma mark - swap camera
- (RTCVideoTrack *)createLocalVideoTrackBackCamera {
    RTCVideoTrack *localVideoTrack = nil;
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE
    //AVCaptureDevicePositionFront
    NSString *cameraID = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionBack) {
            cameraID = [captureDevice localizedName];
            break;
        }
    }
    NSAssert(cameraID, @"Unable to get the back camera id");
    
    RTCVideoCapturer *capturer = [RTCVideoCapturer capturerWithDeviceName:cameraID];
    RTCMediaConstraints *mediaConstraints = [self defaultMediaStreamConstraints];
    RTCVideoSource *videoSource = [_factory videoSourceWithCapturer:capturer constraints:mediaConstraints];
    localVideoTrack = [_factory videoTrackWithID:@"ARDAMSv0" source:videoSource];
#endif
    return localVideoTrack;
}
- (void)swapCameraToFront{
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    
    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];

    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}
- (void)swapCameraToBack{
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    
    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrackBackCamera];
    
    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}

#pragma mark - enable/disable speaker

- (void)enableSpeaker {
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
    _isSpeakerEnabled = YES;
}

- (void)disableSpeaker {
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
    _isSpeakerEnabled = NO;
}

#pragma mark - Data Transfer

- (void)setupDataChannelWithPeerConnection:(RTCPeerConnection *)peerConnection {
    if (!peerConnection) {
        return;
    }

    RTCDataChannelInit *dcInit = [RTCDataChannelInit new];
    self.dataChannel = [peerConnection createDataChannelWithLabel:@"label" config:dcInit];
    if (self.dataChannel == nil) {
        NSLog(@"PluginRTCDataChannel#init() | rtcPeerConnection.createDataChannelWithLabel() failed !!!");
        return;
    }
}

- (void)sendData {
    NSData *data = [@"message" dataUsingEncoding:NSUTF8StringEncoding];
    RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:data isBinary:NO];

    BOOL sent = [self.dataChannel sendData:buffer];
    if (sent) {
        NSLog(@"DID SEND DATA");
    } else {
        NSLog(@"FAILED TO SEND DATA");
    }
}


@end
