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

#import "ARDSignalingMessage.h"

#import "ARDUtilities.h"
#import "RTCICECandidate+JSON.h"
#import "RTCSessionDescription+JSON.h"

static NSString const *kARDSignalingMessageTypeKey = @"signal";

@implementation ARDSignalingMessage

@synthesize type = _type;

- (instancetype)initWithType:(ARDSignalingMessageType)type {
  if (self = [super init]) {
    _type = type;
  }
  return self;
}

- (NSString *)description {
  return [[NSString alloc] initWithData:[self JSONData]
                               encoding:NSUTF8StringEncoding];
}

+ (ARDSignalingMessage *)messageFromJSONString:(NSString *)jsonString {
  NSDictionary *values = [NSDictionary dictionaryWithJSONString:jsonString];
  if (!values) {
    NSLog(@"Error parsing signaling message JSON.");
    return nil;
  }

  NSString *typeString = values[kARDSignalingMessageTypeKey];
  ARDSignalingMessage *message = nil;
  if ([typeString isEqualToString:@"candidate"]) {
    RTCICECandidate *candidate =
        [RTCICECandidate candidateFromJSONString:values[@"content"]];
    message = [[ARDICECandidateMessage alloc] initWithCandidate:candidate peer:values[@"from"]];
  } else if ([typeString isEqualToString:@"finalize"]) {
      RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:@"answer" sdp:values[@"content"]];
      message = [[ARDFinalizeMessage alloc] initWithFrom:values[@"from"] description:description];
  } else if ([typeString isEqualToString:@"answerRequest"]) {
      RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:@"offer" sdp:values[@"content"]];
      message = [[ARDAnswerRequestMessage alloc] initWithFrom:values[@"from"] to:values[@"to"] description:description];
  } else if ([typeString isEqualToString:@"left"]) {
    message = [[ARDByeMessage alloc] initWithPeer:values[@"from"]];
  } else if ([typeString isEqualToString:@"ping"]){
      message = [ARDPingMessage new];
  } else if ([typeString isEqualToString:@"created"]) {
      message = [ARDCreatedMessage new];
  } else if ([typeString isEqualToString:@"joined"]) {
      message = [ARDJoinedMessage new];
  } else if ([typeString isEqualToString:@"offerRequest"]) {
      message = [[ARDOfferRequestMessage alloc] initWithDictionary:values];
  } else {
      NSLog(@"Unexpected type: %@", typeString);
  }
  return message;
}

- (NSData *)JSONData {
  return nil;
}

@end

@implementation ARDICECandidateMessage

@synthesize candidate = _candidate;
@synthesize peer = _peer;
- (instancetype)initWithCandidate:(RTCICECandidate *)candidate peer:(NSString *)peerID{
  if (self = [super initWithType:kARDSignalingMessageTypeCandidate]) {
    _candidate = candidate;
    _peer = peerID;
  }
  return self;
}

- (NSData *)JSONData {
    NSError *err;
    NSDictionary *candidateDict = [_candidate JSONDictionary];
    NSData * jsonData = [NSJSONSerialization  dataWithJSONObject:candidateDict options:0 error:&err];
    NSString * myString = [[NSString alloc] initWithData:jsonData   encoding:NSUTF8StringEncoding];
    NSDictionary *message = [NSDictionary dictionaryWithObjects:@[@"candidate",_peer, myString] forKeys:@[@"signal", @"to", @"content"]];
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

//@implementation ARDSessionDescriptionMessage
//
//@synthesize sessionDescription = _sessionDescription;
//
//- (instancetype)initWithDescription:(RTCSessionDescription *)description {
//  ARDSignalingMessageType type = kARDSignalingMessageTypeOffer;
//  NSString *typeString = description.type;
//  if ([typeString isEqualToString:@"offer"]) {
//    type = kARDSignalingMessageTypeOffer;
//  } else if ([typeString isEqualToString:@"answer"]) {
//    type = kARDSignalingMessageTypeAnswer;
//  } else {
//    NSAssert(NO, @"Unexpected type: %@", typeString);
//  }
//  if (self = [super initWithType:type]) {
//    _sessionDescription = description;
//  }
//  return self;
//}
//
//- (NSData *)JSONData {
//  return [_sessionDescription JSONData];
//}
//
//@end

@implementation ARDByeMessage
@synthesize peer = _peer;
- (instancetype)init {
  return [super initWithType:kARDSignalingMessageTypePeerLeft];
}

- (instancetype)initWithPeer:(NSString *)peerID {
    if (self = [super initWithType:kARDSignalingMessageTypePeerLeft]) {
        _peer = peerID;
    }
    return self;
}


- (NSData *)JSONData {
  NSDictionary *message = @{
    @"signal": @"left",
    @"to" : _peer
  };
  return [NSJSONSerialization dataWithJSONObject:message
                                         options:NSJSONWritingPrettyPrinted
                                           error:NULL];
}

@end

@implementation ARDPingMessage

- (instancetype)init {
    return [super initWithType:kARDSignalingMessageTypePing];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"ping"
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

@implementation ARDCreatedMessage

- (instancetype)init {
    return [super initWithType:kARDSignalingMessageTypeCreated];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"created"
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

@implementation ARDJoinedMessage

- (instancetype)init {
    return [super initWithType:kARDSignalingMessageTypeJoined];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"joined"
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

@implementation ARDOfferRequestMessage
@synthesize to = _to;
@synthesize from = _from;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if (self = [super initWithType:kARDSignalingMessageTypeOfferRequest]) {
        if (dictionary != nil) {
            _to = dictionary[@"to"];
            _from = dictionary[@"from"];
        }
    }
    return self;
}

- (instancetype)init {
    return [self initWithDictionary:nil];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"offerRequest"
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

@implementation ARDOfferResponseMessage
@synthesize to = _to;
@synthesize sessionDescription = _sessionDescription;

- (instancetype)initWithTo:(NSString *)to
                 description:(RTCSessionDescription *)description {
    if (self = [super initWithType:kARDSignalingMessageTypeOfferResponse]) {
        _to = to;
        _sessionDescription = description;
    }
    return self;
}

- (instancetype)init {
    return [self initWithTo:nil description:nil];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"offerResponse",
                              @"to" : _to,
                              @"content" : _sessionDescription.description
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

@implementation ARDFinalizeMessage

@synthesize from = _from;
@synthesize sessionDescription = _sessionDescription;

- (instancetype)initWithFrom:(NSString *)from
                 description:(RTCSessionDescription *)description {
    if (self = [super initWithType:kARDSignalingMessageTypeFinalize]) {
        _from = from;
        _sessionDescription = description;
    }
    return self;
}

- (instancetype)init {
    return [self initWithFrom:nil description:nil];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"finalize",
                              @"from" : _from,
                              @"content" : _sessionDescription.description
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

@implementation ARDAnswerRequestMessage

@synthesize from = _from;
@synthesize to = _to;
@synthesize sessionDescription = _sessionDescription;

- (instancetype)initWithFrom:(NSString *)from
                          to:(NSString *)to
                 description:(RTCSessionDescription *)description {
    if (self = [super initWithType:kARDSignalingMessageTypeAnswerRequest]) {
        _from = from;
        _to = to;
        _sessionDescription = description;
    }
    return self;
}

- (instancetype)init {
    return [self initWithFrom:nil to:nil description:nil];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"answerRequest",
                              @"from" : _from,
                              @"content" : _sessionDescription.description
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}


@end

@implementation ARDAnswerResponseMessage

@synthesize to = _to;
@synthesize description = _description;

- (instancetype)initWithTo:(NSString *)to
               description:(RTCSessionDescription *)description {
    if (self = [super initWithType:kARDSignalingMessageTypeAnswerResponse]) {
        _to = to;
        _sessionDescription = description;
    }
    return self;
}

- (instancetype)init {
    return [self initWithTo:nil description:nil];
}

- (NSData *)JSONData {
    NSDictionary *message = @{
                              @"signal": @"answerResponse",
                              @"to" : _to,
                              @"content" : _sessionDescription.description
                              };
    return [NSJSONSerialization dataWithJSONObject:message
                                           options:NSJSONWritingPrettyPrinted
                                             error:NULL];
}

@end

