//
//  ARTCRoomViewController.m
//  AppRTC
//
//  Created by Kelly Chu on 3/7/15.
//  Copyright (c) 2015 ISBX. All rights reserved.
//

#import "ARTCRoomViewController.h"
#import "ARTCVideoChatViewController.h"

@interface ARTCRoomViewController ()
@property (nonatomic, assign) BOOL isInitiator;
@end

@implementation ARTCRoomViewController

- (void)viewDidLoad {
    self.isInitiator = NO;
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[self navigationController] setNavigationBarHidden:NO animated:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        ARTCRoomTextInputViewCell *cell = (ARTCRoomTextInputViewCell *)[tableView dequeueReusableCellWithIdentifier:@"RoomInputCell" forIndexPath:indexPath];
        [cell setDelegate:self];
        
        return cell;
    }
    
    return nil;
}



#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    ARTCVideoChatViewController *viewController = (ARTCVideoChatViewController *)[segue destinationViewController];
    viewController.isInitiator = self.isInitiator;
    [viewController setRoomName:sender];
}

#pragma mark - ARTCRoomTextInputViewCellDelegate Methods

- (void)roomTextInputViewCell:(ARTCRoomTextInputViewCell *)cell shouldCreateRoom:(NSString *)room {
    self.isInitiator = YES;
    [self performSegueWithIdentifier:@"ARTCVideoChatViewController" sender:room];
}

- (void)roomTextInputViewCell:(ARTCRoomTextInputViewCell *)cell shouldJoinRoom:(NSString *)room {
    self.isInitiator = NO;
    [self performSegueWithIdentifier:@"ARTCVideoChatViewController" sender:room];
}

@end
