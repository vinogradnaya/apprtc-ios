//
//  ARTCRoomViewController.h
//  AppRTC
//
//  Created by Kelly Chu on 3/7/15.
//  Copyright (c) 2015 ISBX. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "ARTCRoomTextInputViewCell.h"
#import <AppRTC/ARDAppClient.h>

@interface ARTCRoomViewController : UITableViewController <ARTCRoomTextInputViewCellDelegate>
@property (strong, nonatomic) ARDAppClient *client;
@end
