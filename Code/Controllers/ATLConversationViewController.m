//
//  ATLUIConversationViewController.m
//  Atlas
//
//  Created by Kevin Coleman on 8/31/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <AssetsLibrary/AssetsLibrary.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "ATLConversationViewController.h"
#import "ATLConversationCollectionView.h"
#import "ATLConstants.h"
#import "ATLDataSourceChange.h"
#import "ATLMessagingUtilities.h"
#import "ATLTypingIndicatorViewController.h"
#import "LYRQueryController.h"
#import "ATLDataSourceChange.h"
#import "ATLConversationView.h"
#import "ATLConversationDataSource.h"
#import "ATLMediaAttachment.h"
#import "ATLLocationManager.h"

@interface ATLConversationViewController () <UICollectionViewDataSource, UICollectionViewDelegate, ATLMessageInputToolbarDelegate, UIActionSheetDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, LYRQueryControllerDelegate>

@property (nonatomic) ATLConversationCollectionView *collectionView;
@property (nonatomic) ATLConversationDataSource *conversationDataSource;
@property (nonatomic) ATLConversationView *view;
@property (nonatomic) ATLTypingIndicatorViewController *typingIndicatorViewController;
@property (nonatomic) CGFloat keyboardHeight;
@property (nonatomic) BOOL shouldDisplayAvatarItem;
@property (nonatomic) NSLayoutConstraint *typingIndicatorViewBottomConstraint;
@property (nonatomic) NSMutableArray *typingParticipantIDs;
@property (nonatomic) NSMutableArray *objectChanges;
@property (nonatomic) NSHashTable *sectionHeaders;
@property (nonatomic) NSHashTable *sectionFooters;
@property (nonatomic, getter=isFirstAppearance) BOOL firstAppearance;
@property (nonatomic) BOOL showingMoreMessagesIndicator;
@property (nonatomic) BOOL hasAppeared;
@property (nonatomic) ATLLocationManager *locationManager;

@end

@implementation ATLConversationViewController

static CGFloat const ATLTypingIndicatorHeight = 20;
static NSInteger const ATLMoreMessagesSection = 0;
static NSString *const ATLPushNotificationSoundName = @"layerbell.caf";

+ (instancetype)conversationViewControllerWithLayerClient:(LYRClient *)layerClient;
{
    NSAssert(layerClient, @"Layer Client cannot be nil");
    return [[self alloc] initWithLayerClient:layerClient];
}

- (id)initWithLayerClient:(LYRClient *)layerClient
{
    self = [super init];
    if (self) {
        _layerClient = layerClient;
        [self lyr_commonInit];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder:decoder];
    if (self) {
        [self lyr_commonInit];
    }
    return self;
}

- (void)lyr_commonInit
{
    _dateDisplayTimeInterval = 60*60;
    _marksMessagesAsRead = YES;
    _displaysAddressBar = NO;
    _typingParticipantIDs = [NSMutableArray new];
    _sectionHeaders = [NSHashTable weakObjectsHashTable];
    _sectionFooters = [NSHashTable weakObjectsHashTable];
    _firstAppearance = YES;
    _objectChanges = [NSMutableArray new];
}

- (void)loadView
{
    self.view = [ATLConversationView new];
}

- (id)init
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to call designated initializer." userInfo:nil];
    return nil;
}

- (void)setLayerClient:(LYRClient *)layerClient
{
    if (self.hasAppeared) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Layer Client cannot be set after the view has been presented" userInfo:nil];
    }
    _layerClient = layerClient;
}


#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    // Collection View Setup
    self.collectionView = [[ATLConversationCollectionView alloc] initWithFrame:CGRectZero
                                                            collectionViewLayout:[[UICollectionViewFlowLayout alloc] init]];
    self.collectionView.delegate = self;
    self.collectionView.dataSource = self;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.collectionView];
    [self configureCollectionViewLayoutConstraints];
    
    // Add message input tool bar
    self.messageInputToolbar = [ATLMessageInputToolbar new];
    self.messageInputToolbar.inputToolBarDelegate = self;
    // An apparent system bug causes a view controller to not be deallocated
    // if the view controller's own inputAccessoryView property is used.
    self.view.inputAccessoryView = self.messageInputToolbar;
    
    // Add typing indicator
    self.typingIndicatorViewController = [[ATLTypingIndicatorViewController alloc] init];
    [self addChildViewController:self.typingIndicatorViewController];
    [self.view addSubview:self.typingIndicatorViewController.view];
    [self.typingIndicatorViewController didMoveToParentViewController:self];
    [self configureTypingIndicatorLayoutConstraints];
    
    // Add address bar if needed
    if (!self.conversation && self.displaysAddressBar) {
        self.addressBarController = [[ATLAddressBarViewController alloc] init];
        self.addressBarController.delegate = self;
        [self addChildViewController:self.addressBarController];
        [self.view addSubview:self.addressBarController.view];
        [self.addressBarController didMoveToParentViewController:self];
        [self configureAddressBarLayoutConstraints];
    }
    [self registerForNotifications];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!self.conversationDataSource) {
        [self fetchLayerMessages];
    }
    [self updateCollectionViewInsets];
    [self configureControllerForConversation];
    
    // Workaround for a modal dismissal causing the message toolbar to remain offscreen on iOS 8.
    if (self.presentedViewController) {
        [self.view becomeFirstResponder];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    self.hasAppeared = YES;
    if (self.addressBarController && !self.addressBarController.isDisabled) {
        [self.addressBarController.addressBarView.addressBarTextView becomeFirstResponder];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];

    // Workaround for view's content flashing onscreen after pop animation concludes on iOS 8.
    BOOL isPopping = ![self.navigationController.viewControllers containsObject:self];
    if (isPopping) {
        [self.messageInputToolbar.textInputView resignFirstResponder];
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    if (self.addressBarController) {
        [self configureScrollIndicatorInset];
    }
    // To get the toolbar to slide onscreen with the view controller's content, we have to make the view the
    // first responder here. Even so, it will not animate on iOS 8 the first time.
    if (!self.presentedViewController && self.navigationController && !self.view.inputAccessoryView.superview) {
        [self.view becomeFirstResponder];
    }
    if (self.isFirstAppearance) {
        self.firstAppearance = NO;
        [self scrollToBottomOfCollectionViewAnimated:NO];
        // This works around an issue where in some situations iOS 7.1 will crash with 'Auto Layout still required after
        // sending -viewDidLayoutSubviews to the view controller.' apparently due to our usage of the collection view
        // layout's content size when scrolling to the bottom in the above method call.
        [self.view layoutIfNeeded];
    }
}

- (void)dealloc
{
    self.collectionView.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Conversation Setup

- (void)fetchLayerMessages
{
    if (!self.conversation) return;
    self.conversationDataSource = [ATLConversationDataSource dataSourceWithLayerClient:self.layerClient conversation:self.conversation];
    self.conversationDataSource.queryController.delegate = self;
    self.showingMoreMessagesIndicator = [self.conversationDataSource moreMessagesAvailable];
    [self.collectionView reloadData];
}

- (void)setConversation:(LYRConversation *)conversation
{
    if (!conversation && !_conversation) return;
    if ([conversation isEqual:_conversation]) return;

    _conversation = conversation;

    [self.typingParticipantIDs removeAllObjects];
    [self updateTypingIndicatorOverlay:NO];
    
    [self configureControllerForConversation];
    [self configureAddressBarForChangedParticipants];

    if (conversation) {
        [self fetchLayerMessages];
    } else {
        self.conversationDataSource = nil;
        [self.collectionView reloadData];
    }
    CGSize contentSize = self.collectionView.collectionViewLayout.collectionViewContentSize;
    [self.collectionView setContentOffset:[self bottomOffsetForContentSize:contentSize] animated:NO];
}

- (void)configureControllerForConversation
{
    [self configureAvatarImageDisplay];
    [self configureSendButtonEnablement];
    NSError *error;
    [self.conversation markAllMessagesAsRead:&error];
    if (error) {
        NSLog(@"Failed marking all messages as read with error: %@", error);
    }
}

- (void)configureControllerForChangedParticipants
{
    if (self.addressBarController && ![self.addressBarController isDisabled]) {
        [self configureConversationForAddressBar];
        return;
    }
    NSMutableSet *removedParticipantIdentifiers = [NSMutableSet setWithArray:self.typingParticipantIDs];
    [removedParticipantIdentifiers minusSet:self.conversation.participants];
    [self.typingParticipantIDs removeObjectsInArray:removedParticipantIdentifiers.allObjects];
    [self updateTypingIndicatorOverlay:NO];
    [self configureAddressBarForChangedParticipants];
    [self configureControllerForConversation];
    [self.collectionView reloadData];
}

- (void)configureAvatarImageDisplay
{
    NSMutableSet *otherParticipantIDs = [self.conversation.participants mutableCopy];
    if (self.layerClient.authenticatedUserID) [otherParticipantIDs removeObject:self.layerClient.authenticatedUserID];
    self.shouldDisplayAvatarItem = otherParticipantIDs.count > 1;
}

# pragma mark - UICollectionViewDataSource

// LAYER - The `ATLConversationViewController` component uses one `LYRMessage` to represent each row.
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    if (section == ATLMoreMessagesSection) return 0;

    // Each message is represented by one cell no matter how many parts it has.
    return 1;
}
 
// LAYER - The `ATLConversationViewController` component uses `LYRMessages` to represent sections.
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return [self.conversationDataSource.queryController numberOfObjectsInSection:0] + ATLNumberOfSectionsBeforeFirstMessageSection;
}

// LAYER - Configuring a subclass of `ATLMessageCollectionViewCell` to be displayed on screen. `LayerUIKit` supports both
// `ATLIncomingMessageCollectionViewCell` and `ATLOutgoingMessageCollectionViewCell`.
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    NSString *reuseIdentifier = [self reuseIdentifierForMessage:message atIndexPath:indexPath];
    
    UICollectionViewCell<ATLMessagePresenting> *cell =  [self.collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];
    [self configureCell:cell forMessage:message indexPath:indexPath];
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [self notifyDelegateOfMessageSelection:[self.conversationDataSource messageAtCollectionViewIndexPath:indexPath]];
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [self heightForMessageAtIndexPath:indexPath];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == ATLMoreMessagesSection) {
        ATLConversationCollectionViewMoreMessagesHeader *header = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:ATLMoreMessagesHeaderIdentifier forIndexPath:indexPath];
        return header;
    }
    if (kind == UICollectionElementKindSectionHeader) {
        ATLConversationCollectionViewHeader *header = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:ATLConversationViewHeaderIdentifier forIndexPath:indexPath];
        [self configureHeader:header atIndexPath:indexPath];
        [self.sectionHeaders addObject:header];
        return header;
    } else {
        ATLConversationCollectionViewFooter *footer = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:ATLConversationViewFooterIdentifier forIndexPath:indexPath];
        [self configureFooter:footer atIndexPath:indexPath];
        [self.sectionFooters addObject:footer];
        return footer;
    }
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section
{
    if (section == ATLMoreMessagesSection) {
        return self.showingMoreMessagesIndicator ? CGSizeMake(0, 30) : CGSizeZero;
    }
    NSAttributedString *dateString;
    NSString *participantName;
    if ([self shouldDisplayDateLabelForSection:section]) {
        dateString = [self attributedStringForMessageDate:[self.conversationDataSource messageAtCollectionViewSection:section]];
    }
    if ([self shouldDisplaySenderLabelForSection:section]) {
        participantName = [self participantNameForMessage:[self.conversationDataSource messageAtCollectionViewSection:section]];
    }
    CGFloat height = [ATLConversationCollectionViewHeader headerHeightWithDateString:dateString participantName:participantName inView:self.collectionView];
    return CGSizeMake(0, height);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForFooterInSection:(NSInteger)section
{
    if (section == ATLMoreMessagesSection) return CGSizeZero;
    NSAttributedString *readReceipt;
    if ([self shouldDisplayReadReceiptForSection:section]) {
        readReceipt = [self attributedStringForRecipientStatusOfMessage:[self.conversationDataSource messageAtCollectionViewSection:section]];
    }
    BOOL shouldClusterMessage = [self shouldClusterMessageAtSection:section];
    CGFloat height = [ATLConversationCollectionViewFooter footerHeightWithRecipientStatus:readReceipt clustered:shouldClusterMessage];
    return CGSizeMake(0, height);
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    // When the keyboard is being dragged, we need to update the position of the typing indicator.
    [self.view setNeedsUpdateConstraints];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (decelerate) return;
    [self configurePaginationWindow];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self configurePaginationWindow];
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView
{
    [self configurePaginationWindow];
}

#pragma mark - Reusable View Configuration

// LAYER - Extracting the proper message part and analyzing its properties to determine the cell configuration.
- (void)configureCell:(UICollectionViewCell<ATLMessagePresenting> *)cell forMessage:(LYRMessage *)message indexPath:(NSIndexPath *)indexPath
{
    [cell presentMessage:message];
    [cell shouldDisplayAvatarItem:self.shouldDisplayAvatarItem];
    
    if ([self shouldDisplayAvatarItemAtIndexPath:indexPath]) {
        [cell updateWithSender:[self participantForIdentifier:message.sentByUserID]];
    } else {
        [cell updateWithSender:nil];
    }
}

- (void)configureFooter:(ATLConversationCollectionViewFooter *)footer atIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    footer.message = message;
    if ([self shouldDisplayReadReceiptForSection:indexPath.section]) {
        [footer updateWithAttributedStringForRecipientStatus:[self attributedStringForRecipientStatusOfMessage:message]];
    } else {
        [footer updateWithAttributedStringForRecipientStatus:nil];
    }
}

- (void)configureHeader:(ATLConversationCollectionViewHeader *)header atIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    header.message = message;
    if ([self shouldDisplayDateLabelForSection:indexPath.section]) {
        [header updateWithAttributedStringForDate:[self attributedStringForMessageDate:message]];
    }
    if ([self shouldDisplaySenderLabelForSection:indexPath.section]) {
        [header updateWithParticipantName:[self participantNameForMessage:message]];
    }
}

#pragma mark - UI Configuration

- (CGFloat)defaultCellHeightForItemAtIndexPath:(NSIndexPath *)indexPath
{
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    return [ATLMessageCollectionViewCell cellHeightForMessage:message inView:self.view];
}

- (BOOL)shouldDisplayDateLabelForSection:(NSUInteger)section
{
    if (section < ATLNumberOfSectionsBeforeFirstMessageSection) return NO;
    if (section == ATLNumberOfSectionsBeforeFirstMessageSection) return YES;
    
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    LYRMessage *previousMessage = [self.conversationDataSource messageAtCollectionViewSection:section - 1];
    if (!previousMessage.sentAt) return NO;
    
    NSDate *date = message.sentAt ?: [NSDate date];
    NSTimeInterval interval = [date timeIntervalSinceDate:previousMessage.sentAt];
    if (interval > self.dateDisplayTimeInterval) {
        return YES;
    }
    return NO;
}

- (BOOL)shouldDisplaySenderLabelForSection:(NSUInteger)section
{
    if (self.conversation.participants.count <= 2) return NO;
    
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    if ([message.sentByUserID isEqualToString:self.layerClient.authenticatedUserID]) return NO;

    if (section > ATLNumberOfSectionsBeforeFirstMessageSection) {
        LYRMessage *previousMessage = [self.conversationDataSource messageAtCollectionViewSection:section - 1];
        if ([previousMessage.sentByUserID isEqualToString:message.sentByUserID]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)shouldDisplayReadReceiptForSection:(NSUInteger)section
{
    // Only show read receipt if last message was sent by currently authenticated user
    NSInteger lastQueryControllerRow = [self.conversationDataSource.queryController numberOfObjectsInSection:0] - 1;
    NSInteger lastSection = [self.conversationDataSource collectionViewSectionForQueryControllerRow:lastQueryControllerRow];
    if (section != lastSection) return NO;

    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    if (![message.sentByUserID isEqualToString:self.layerClient.authenticatedUserID]) return NO;
    
    return YES;
}

- (BOOL)shouldClusterMessageAtSection:(NSUInteger)section
{
    if (section == self.collectionView.numberOfSections - 1) {
        return NO;
    }
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewSection:section];
    LYRMessage *nextMessage = [self.conversationDataSource messageAtCollectionViewSection:section + 1];
    if (!nextMessage.receivedAt) {
        return NO;
    }
    NSDate *date = message.receivedAt ?: [NSDate date];
    NSTimeInterval interval = [nextMessage.receivedAt timeIntervalSinceDate:date];
    return (interval < 60);
}

- (BOOL)shouldDisplayAvatarItemAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.shouldDisplayAvatarItem) return NO;
   
    LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
    if ([message.sentByUserID isEqualToString:self.layerClient.authenticatedUserID]) {
        return NO;
    }
   
    NSInteger lastQueryControllerRow = [self.conversationDataSource.queryController numberOfObjectsInSection:0] - 1;
    NSInteger lastSection = [self.conversationDataSource collectionViewSectionForQueryControllerRow:lastQueryControllerRow];
    if (indexPath.section < lastSection) {
        LYRMessage *nextMessage = [self.conversationDataSource messageAtCollectionViewSection:indexPath.section + 1];
        // If the next message is sent by the same user, no
        if ([nextMessage.sentByUserID isEqualToString:message.sentByUserID]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - ATLMessageInputToolbarDelegate

- (void)messageInputToolbar:(ATLMessageInputToolbar *)messageInputToolbar didTapLeftAccessoryButton:(UIButton *)leftAccessoryButton
{
    UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:nil
                                                             delegate:self
                                                    cancelButtonTitle:@"Cancel"
                                               destructiveButtonTitle:nil
                                                    otherButtonTitles:@"Take Photo", @"Last Photo Taken", @"Photo Library", nil];
    [actionSheet showInView:self.view];
}

- (void)messageInputToolbar:(ATLMessageInputToolbar *)messageInputToolbar didTapRightAccessoryButton:(UIButton *)rightAccessoryButton
{
    if (!self.conversation) {
        return;
    }
    if (messageInputToolbar.mediaAttachments.count) {
        NSOrderedSet *messages = [self defaultMessagesForMediaAttachments:messageInputToolbar.mediaAttachments];
        for (LYRMessage *message in messages) {
            [self sendMessage:message];
        }
    } else {
        [self shareLocation];
    }
    if (self.addressBarController) [self.addressBarController disable];
}

- (void)messageInputToolbarDidType:(ATLMessageInputToolbar *)messageInputToolbar
{
    if (!self.conversation) return;
    [self.conversation sendTypingIndicator:LYRTypingDidBegin];
}

- (void)messageInputToolbarDidEndTyping:(ATLMessageInputToolbar *)messageInputToolbar
{
    if (!self.conversation) return;
    [self.conversation sendTypingIndicator:LYRTypingDidFinish];
}

#pragma mark - Message Sending

- (NSOrderedSet *)defaultMessagesForMediaAttachments:(NSArray *)mediaAttachments
{
    NSMutableOrderedSet *messages = [NSMutableOrderedSet new];
    for (ATLMediaAttachment *attachment in mediaAttachments){
        NSArray *messageParts = ATLMessagePartsWithMediaAttachment(attachment);
        LYRMessage *message = [self messageForMessageParts:messageParts pushText:attachment.textRepresentation];
        if (message)[messages addObject:message];
    }
    return messages;
}

- (LYRMessage *)messageForMessageParts:(NSArray *)parts pushText:(NSString *)pushText;
{
    NSString *senderName = [[self participantForIdentifier:self.layerClient.authenticatedUserID] fullName];
    NSDictionary *pushOptions = @{LYRMessageOptionsPushNotificationAlertKey : [NSString stringWithFormat:@"%@: %@", senderName, pushText],
                                  LYRMessageOptionsPushNotificationSoundNameKey : ATLPushNotificationSoundName};
    NSError *error;
    LYRMessage *message = [self.layerClient newMessageWithParts:parts options:pushOptions error:&error];
    if (error) {
        return nil;
    }
    return message;
}

- (void)sendMessage:(LYRMessage *)message
{
    NSError *error;
    BOOL success = [self.conversation sendMessage:message error:&error];
    if (success) {
        [self notifyDelegateOfMessageSend:message];
    } else {
        [self notifyDelegateOfMessageSendFailure:message error:error];
    }
}

- (void)shareLocation
{
    if (!self.locationManager) {
        self.locationManager = [[ATLLocationManager alloc] init];
    }
    if ([self.locationManager locationServicesEnabled]) {
        [self.locationManager updateLocation];
    }
    CLLocation *location = self.locationManager.location;
    if (location) {
        ATLMediaAttachment *attachement = [ATLMediaAttachment mediaAttachmentWithLocation:location];
        LYRMessage *message = [self messageForMessageParts:ATLMessagePartsWithMediaAttachment(attachement) pushText:@"Attachement: Location"];
        [self sendMessage:message];
    }
}

#pragma mark - UIActionSheetDelegate

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    switch (buttonIndex) {
        case 0:
            [self displayImagePickerWithSourceType:UIImagePickerControllerSourceTypeCamera];
            break;
            
        case 1:
           [self captureLastPhotoTaken];
            break;
          
        case 2:
            [self displayImagePickerWithSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
            break;
            
        default:
            break;
    }
}

#pragma mark - Image Picking

- (void)displayImagePickerWithSourceType:(UIImagePickerControllerSourceType)sourceType;
{
    [self.messageInputToolbar.textInputView resignFirstResponder];
    BOOL pickerSourceTypeAvailable = [UIImagePickerController isSourceTypeAvailable:sourceType];
    if (pickerSourceTypeAvailable) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.sourceType = sourceType;
        [self.navigationController presentViewController:picker animated:YES completion:nil];
    }
}

- (void)captureLastPhotoTaken
{
    ATLAssetURLOfLastPhotoTaken(^(NSURL *assetURL, NSError *error) {
        if (error) {
            NSLog(@"Failed to capture last photo with error: %@", [error localizedDescription]);
        } else {
            ATLMediaAttachment *mediaAttachment = [ATLMediaAttachment mediaAttachmentWithAssetURL:assetURL thumbnailSize:ATLDefaultThumbnailSize];
            [self.messageInputToolbar insertMediaAttachment:mediaAttachment];
        }
    });
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    NSString *mediaType = info[UIImagePickerControllerMediaType];
    if ([mediaType isEqualToString:(__bridge NSString *)kUTTypeImage]) {
        NSURL *assetURL = (NSURL *)info[UIImagePickerControllerReferenceURL];
        ATLMediaAttachment *mediaAttachment;
        if (assetURL) {
            mediaAttachment = [ATLMediaAttachment mediaAttachmentWithAssetURL:assetURL thumbnailSize:ATLDefaultThumbnailSize];
        } else if (info[UIImagePickerControllerOriginalImage]) {
            mediaAttachment = [ATLMediaAttachment mediaAttachmentWithImage:info[UIImagePickerControllerOriginalImage]
                                                                  metadata:info[UIImagePickerControllerMediaMetadata]
                                                             thumbnailSize:ATLDefaultThumbnailSize];
        } else {
            return;
        }
        [self.messageInputToolbar insertMediaAttachment:mediaAttachment];
    }
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    [self.view becomeFirstResponder];

    // Workaround for collection view not displayed on iOS 7.1.
    [self.collectionView setNeedsLayout];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    [self.view becomeFirstResponder];

    // Workaround for collection view not displayed on iOS 7.1.
    [self.collectionView setNeedsLayout];
}

#pragma mark - Collection View Content Inset

- (void)configureWithKeyboardNotification:(NSNotification *)notification
{
    CGRect keyboardBeginFrame = [notification.userInfo[UIKeyboardFrameBeginUserInfoKey] CGRectValue];
    CGRect keyboardBeginFrameInView = [self.view convertRect:keyboardBeginFrame fromView:nil];
    CGRect keyboardEndFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardEndFrameInView = [self.view convertRect:keyboardEndFrame fromView:nil];
    CGRect keyboardEndFrameIntersectingView = CGRectIntersection(self.view.bounds, keyboardEndFrameInView);
    CGFloat keyboardHeight = CGRectGetHeight(keyboardEndFrameIntersectingView);

    // Workaround for keyboard height inaccuracy on iOS 8.
    if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_7_1) {
        keyboardHeight -= CGRectGetMinY(self.messageInputToolbar.frame);
    }

    self.keyboardHeight = keyboardHeight;

    // Workaround for collection view cell sizes changing/animating when view is first pushed onscreen on iOS 8.
    if (CGRectEqualToRect(keyboardBeginFrameInView, keyboardEndFrameInView)) {
        [UIView performWithoutAnimation:^{
            [self updateCollectionViewInsets];
            self.typingIndicatorViewBottomConstraint.constant = -self.collectionView.scrollIndicatorInsets.bottom;
        }];
        return;
    }

    [self.view layoutIfNeeded];
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]];
    [UIView setAnimationCurve:[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue]];
    [UIView setAnimationBeginsFromCurrentState:YES];
    [self updateCollectionViewInsets];
    self.typingIndicatorViewBottomConstraint.constant = -self.collectionView.scrollIndicatorInsets.bottom;
    [self.view layoutIfNeeded];
    [UIView commitAnimations];
}

- (void)updateCollectionViewInsets
{
    [self.messageInputToolbar layoutIfNeeded];
    UIEdgeInsets insets = self.collectionView.contentInset;
    CGFloat keyboardHeight = MAX(self.keyboardHeight, CGRectGetHeight(self.messageInputToolbar.frame));
    insets.bottom = keyboardHeight;
    self.collectionView.scrollIndicatorInsets = insets;
    self.collectionView.contentInset = insets;
}

- (CGPoint)bottomOffsetForContentSize:(CGSize)contentSize
{
    CGFloat contentSizeHeight = contentSize.height;
    CGFloat collectionViewFrameHeight = self.collectionView.frame.size.height;
    CGFloat collectionViewBottomInset = self.collectionView.contentInset.bottom;
    CGFloat collectionViewTopInset = self.collectionView.contentInset.top;
    CGPoint offset = CGPointMake(0, MAX(-collectionViewTopInset, contentSizeHeight - (collectionViewFrameHeight - collectionViewBottomInset)));
    return offset;
}

#pragma mark - Notification Handlers

- (void)messageInputToolbarDidChangeHeight:(NSNotification *)notification
{
    if (!self.messageInputToolbar.superview) return;
    
    CGPoint existingOffset = self.collectionView.contentOffset;
    CGPoint bottomOffset = [self bottomOffsetForContentSize:self.collectionView.contentSize];
    CGFloat distanceToBottom = bottomOffset.y - existingOffset.y;
    BOOL shouldScrollToBottom = distanceToBottom <= 50;
    
    CGRect toolbarFrame = [self.view convertRect:self.messageInputToolbar.frame fromView:self.messageInputToolbar.superview];
    CGFloat keyboardOnscreenHeight = CGRectGetHeight(self.view.frame) - CGRectGetMinY(toolbarFrame);
    if (keyboardOnscreenHeight == self.keyboardHeight) return;
    self.keyboardHeight = keyboardOnscreenHeight;
    [self updateCollectionViewInsets];
    self.typingIndicatorViewBottomConstraint.constant = -self.collectionView.scrollIndicatorInsets.bottom;
    
    if (shouldScrollToBottom) {
        self.collectionView.contentOffset = existingOffset;
        [self scrollToBottomOfCollectionViewAnimated:YES];
    }
}

- (void)keyboardWillShow:(NSNotification *)notification
{
    [self configureWithKeyboardNotification:notification];
}

- (void)keyboardWillHide:(NSNotification *)notification
{
    if (![self.navigationController.viewControllers containsObject:self]) return;
    [self configureWithKeyboardNotification:notification];
}

- (void)textViewTextDidBeginEditing:(NSNotification *)notification
{
    [self scrollToBottomOfCollectionViewAnimated:YES];
}

- (void)didReceiveTypingIndicator:(NSNotification *)notification
{
    if (!self.conversation) return;
    if (!notification.object) return;
    if (![notification.object isEqual:self.conversation]) return;
    
    NSString *participantID = notification.userInfo[LYRTypingIndicatorParticipantUserInfoKey];
    NSNumber *statusNumber = notification.userInfo[LYRTypingIndicatorValueUserInfoKey];
    LYRTypingIndicator status = statusNumber.unsignedIntegerValue;
    if (status == LYRTypingDidBegin) {
        [self.typingParticipantIDs addObject:participantID];
    } else {
        [self.typingParticipantIDs removeObject:participantID];
    }
    [self updateTypingIndicatorOverlay:YES];
}

- (void)layerClientObjectsDidChange:(NSNotification *)notification
{
    if (!self.conversation) return;
    if (!self.layerClient) return;
    if (!notification.object) return;
    if (![notification.object isEqual:self.layerClient]) return;
    
    NSArray *changes = notification.userInfo[LYRClientObjectChangesUserInfoKey];
    for (NSDictionary *change in changes) {
        id changedObject = change[LYRObjectChangeObjectKey];
        if (![changedObject isEqual:self.conversation]) continue;
        
        LYRObjectChangeType changeType = [change[LYRObjectChangeTypeKey] integerValue];
        NSString *changedProperty = change[LYRObjectChangePropertyKey];
        
        if (changeType == LYRObjectChangeTypeUpdate && [changedProperty isEqualToString:@"participants"]) {
            [self configureControllerForChangedParticipants];
            break;
        }
    }
}

- (void)handleApplicationWillEnterForeground:(NSNotification *)notification
{
    if (self.conversation) {
        NSError *error;
        BOOL success = [self.conversation markAllMessagesAsRead:&error];
        if (!success) {
            NSLog(@"Failed to mark all messages as read with error: %@", error);
        }
    }
}

#pragma mark - Typing Indicator

- (void)updateTypingIndicatorOverlay:(BOOL)animated
{
    NSMutableArray *knownParticipantsTyping = [NSMutableArray array];
    [self.typingParticipantIDs enumerateObjectsUsingBlock:^(NSString *participantID, NSUInteger idx, BOOL *stop) {
        id<ATLParticipant> participant = [self participantForIdentifier:participantID];
        if (participant) [knownParticipantsTyping addObject:participant];
    }];
    [self.typingIndicatorViewController updateWithParticipants:knownParticipantsTyping animated:animated];
}


#pragma mark - Device Rotation

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.collectionView.collectionViewLayout invalidateLayout];
}

#pragma mark - LYRQueryControllerDelegate

- (void)queryController:(LYRQueryController *)controller
        didChangeObject:(id)object
            atIndexPath:(NSIndexPath *)indexPath
          forChangeType:(LYRQueryControllerChangeType)type
           newIndexPath:(NSIndexPath *)newIndexPath
{
    if (self.conversationDataSource.isExpandingPaginationWindow) return;
    NSInteger currentIndex = indexPath ? [self.conversationDataSource collectionViewSectionForQueryControllerRow:indexPath.row] : NSNotFound;
    NSInteger newIndex = newIndexPath ? [self.conversationDataSource collectionViewSectionForQueryControllerRow:newIndexPath.row] : NSNotFound;
    [self.objectChanges addObject:[ATLDataSourceChange changeObjectWithType:type newIndex:newIndex currentIndex:currentIndex]];
}

- (void)queryControllerDidChangeContent:(LYRQueryController *)queryController
{
    if (self.conversationDataSource.isExpandingPaginationWindow) {
        self.showingMoreMessagesIndicator = [self.conversationDataSource moreMessagesAvailable];
        [self reloadCollectionViewAdjustingForContentHeightChange];
        return;
    }

    if (self.objectChanges.count == 0) {
        [self configurePaginationWindow];
        [self configureMoreMessagesIndicatorVisibility];
        return;
    }

    // If we were to use the collection view layout's content size here, it appears that at times it can trigger the layout to contact the data source to update its sections, rows and cells which leads to an 'invalide update' crash because the layout has already been updated with the new data prior to the performBatchUpdates:completion: call.
    CGPoint bottomOffset = [self bottomOffsetForContentSize:self.collectionView.contentSize];
    CGFloat distanceToBottom = bottomOffset.y - self.collectionView.contentOffset.y;
    BOOL shouldScrollToBottom = distanceToBottom <= 50 && !self.collectionView.isTracking && !self.collectionView.isDragging && !self.collectionView.isDecelerating;

    [self.collectionView performBatchUpdates:^{
        for (ATLDataSourceChange *change in self.objectChanges) {
            switch (change.type) {
                case LYRQueryControllerChangeTypeInsert:
                    [self.collectionView insertSections:[NSIndexSet indexSetWithIndex:change.newIndex]];
                    break;
                    
                case LYRQueryControllerChangeTypeMove:
                    [self.collectionView moveSection:change.currentIndex toSection:change.newIndex];
                    break;
                    
                case LYRQueryControllerChangeTypeDelete:
                    [self.collectionView deleteSections:[NSIndexSet indexSetWithIndex:change.currentIndex]];
                    break;
                    
                case LYRQueryControllerChangeTypeUpdate:
                    // If we call reloadSections: for a section that is already being animated due to another move (e.g. moving section 17 to 16 causes section 16 to be moved/animated to 17 and then we also reload section 16), UICollectionView will throw an exception. But since all onscreen sections will be reconfigured (see below) we don't need to reload the sections here anyway.
                    break;
                    
                default:
                    break;
            }
        }
        [self.objectChanges removeAllObjects];
    } completion:nil];

     [self configureCollectionViewElements];

    if (shouldScrollToBottom)  {
        // We can't get the content size from the collection view because it will be out-of-date due to the above updates, but we can get the update-to-date size from the layout.
        CGSize contentSize = self.collectionView.collectionViewLayout.collectionViewContentSize;
        [self.collectionView setContentOffset:[self bottomOffsetForContentSize:contentSize] animated:YES];
    } else {
        [self configurePaginationWindow];
        [self configureMoreMessagesIndicatorVisibility];
    }
}

- (void)configureCollectionViewElements
{
    // Since each section's content depends on other messages, we need to update each visible section even when a section's corresponding message has not changed. This also solves the issue with LYRQueryControllerChangeTypeUpdate (see above).
    for (UICollectionViewCell<ATLMessagePresenting> *cell in [self.collectionView visibleCells]) {
        NSIndexPath *indexPath = [self.collectionView indexPathForCell:cell];
        LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
        [self configureCell:cell forMessage:message indexPath:indexPath];
    }
    
    for (ATLConversationCollectionViewHeader *header in self.sectionHeaders) {
        NSIndexPath *queryControllerIndexPath = [self.conversationDataSource.queryController indexPathForObject:header.message];
        if (!queryControllerIndexPath) continue;
        NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:queryControllerIndexPath];
        [self configureHeader:header atIndexPath:collectionViewIndexPath];
    }

    for (ATLConversationCollectionViewFooter *footer in self.sectionFooters) {
        NSIndexPath *queryControllerIndexPath = [self.conversationDataSource.queryController indexPathForObject:footer.message];
        if (!queryControllerIndexPath) continue;
        NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:queryControllerIndexPath];
        [self configureFooter:footer atIndexPath:collectionViewIndexPath];
    }
}

#pragma mark - ATLAddressBarViewControllerDelegate

- (void)addressBarViewControllerDidBeginSearching:(ATLAddressBarViewController *)addressBarViewController
{
    self.messageInputToolbar.hidden = YES;
}

- (void)addressBarViewControllerDidEndSearching:(ATLAddressBarViewController *)addressBarViewController
{
    self.messageInputToolbar.hidden = NO;
}

- (void)addressBarViewController:(ATLAddressBarViewController *)addressBarViewController didSelectParticipant:(id<ATLParticipant>)participant
{
    [self configureConversationForAddressBar];
}

- (void)addressBarViewController:(ATLAddressBarViewController *)addressBarViewController didRemoveParticipant:(id<ATLParticipant>)participant
{
    [self configureConversationForAddressBar];
}

#pragma mark - Send Button Enablement

- (void)configureSendButtonEnablement
{
    BOOL shouldEnableButton = [self shouldAllowSendButtonEnablement];
    self.messageInputToolbar.rightAccessoryButton.enabled = shouldEnableButton;
    self.messageInputToolbar.leftAccessoryButton.enabled = shouldEnableButton;
}

- (BOOL)shouldAllowSendButtonEnablement
{
    if (!self.conversation) {
        return NO;
    }
    return YES;
}

#pragma mark - Pagination

- (void)configurePaginationWindow
{
    if (CGRectEqualToRect(self.collectionView.frame, CGRectZero)) return;
    if (self.collectionView.isDragging) return;
    if (self.collectionView.isDecelerating) return;

    CGFloat topOffset = -self.collectionView.contentInset.top;
    CGFloat distanceFromTop = self.collectionView.contentOffset.y - topOffset;
    CGFloat minimumDistanceFromTopToTriggerLoadingMore = 200;
    BOOL nearTop = distanceFromTop <= minimumDistanceFromTopToTriggerLoadingMore;
    if (!nearTop) return;

    [self.conversationDataSource expandPaginationWindow];
}

- (void)configureMoreMessagesIndicatorVisibility
{
    if (self.collectionView.isDragging) return;
    if (self.collectionView.isDecelerating) return;
    BOOL moreMessagesAvailable = [self.conversationDataSource moreMessagesAvailable];
    if (moreMessagesAvailable == self.showingMoreMessagesIndicator) return;
    self.showingMoreMessagesIndicator = moreMessagesAvailable;
    [self reloadCollectionViewAdjustingForContentHeightChange];
}

- (void)reloadCollectionViewAdjustingForContentHeightChange
{
    CGFloat priorContentHeight = self.collectionView.contentSize.height;
    [self.collectionView reloadData];
    CGFloat contentHeightDifference = self.collectionView.collectionViewLayout.collectionViewContentSize.height - priorContentHeight;
    CGFloat adjustment = contentHeightDifference;
    self.collectionView.contentOffset = CGPointMake(0, self.collectionView.contentOffset.y + adjustment);
    [self.collectionView flashScrollIndicators];
}

#pragma mark - Conversation Configuration

- (void)configureConversationForAddressBar
{
    NSSet *participants = self.addressBarController.selectedParticipants.set;
    NSSet *participantIdentifiers = [participants valueForKey:@"participantIdentifier"];
    if (!participantIdentifiers && !self.conversation.participants) return;
    if ([participantIdentifiers isEqual:self.conversation.participants]) return;
    LYRConversation *conversation = [self conversationWithParticipants:participants];
    self.conversation = conversation;
}

#pragma mark - Address Bar Configuration 

- (void)configureAddressBarForChangedParticipants
{
    if (!self.addressBarController) return;

    NSOrderedSet *existingParticipants = self.addressBarController.selectedParticipants;
    NSOrderedSet *existingParticipantIdentifiers = [existingParticipants valueForKey:@"participantIdentifier"];
    if (!existingParticipantIdentifiers && !self.conversation.participants) return;
    if ([existingParticipantIdentifiers.set isEqual:self.conversation.participants]) return;

    NSMutableOrderedSet *removedIdentifiers = [NSMutableOrderedSet orderedSetWithOrderedSet:existingParticipantIdentifiers];
    [removedIdentifiers minusSet:self.conversation.participants];

    NSMutableOrderedSet *addedIdentifiers = [NSMutableOrderedSet orderedSetWithSet:self.conversation.participants];
    [addedIdentifiers minusOrderedSet:existingParticipantIdentifiers];
    NSString *authenticatedUserID = self.layerClient.authenticatedUserID;
    if (authenticatedUserID) [addedIdentifiers removeObject:authenticatedUserID];

    NSMutableOrderedSet *participantIdentifiers = [NSMutableOrderedSet orderedSetWithOrderedSet:existingParticipantIdentifiers];
    [participantIdentifiers minusOrderedSet:removedIdentifiers];
    [participantIdentifiers unionOrderedSet:addedIdentifiers];

    NSOrderedSet *participants = [self participantsForIdentifiers:participantIdentifiers];
    self.addressBarController.selectedParticipants = participants;
}

#pragma mark - Public Methods

- (void)registerClass:(Class<ATLMessagePresenting>)cellClass forMessageCellWithReuseIdentifier:(NSString *)reuseIdentifier
{
    [self.collectionView registerClass:cellClass forCellWithReuseIdentifier:reuseIdentifier];
}

- (UICollectionViewCell<ATLMessagePresenting> *)collectionViewCellForMessage:(LYRMessage *)message
{
    NSIndexPath *indexPath = [self.conversationDataSource.queryController indexPathForObject:message];
    if (indexPath) {
        NSIndexPath *collectionViewIndexPath = [self.conversationDataSource collectionViewIndexPathForQueryControllerIndexPath:indexPath];
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:collectionViewIndexPath];
        if (cell) return (UICollectionViewCell<ATLMessagePresenting> *)cell;
    }
    return nil;
}

#pragma mark - Delegate

- (void)notifyDelegateOfMessageSend:(LYRMessage *)message
{
    if ([self.delegate respondsToSelector:@selector(conversationViewController:didSendMessage:)]) {
        [self.delegate conversationViewController:self didSendMessage:message];
    }
}

- (void)notifyDelegateOfMessageSendFailure:(LYRMessage *)message error:(NSError *)error
{
    if ([self.delegate respondsToSelector:@selector(conversationViewController:didFailSendingMessage:error:)]) {
        [self.delegate conversationViewController:self didFailSendingMessage:message error:error];
    }
}

- (void)notifyDelegateOfMessageSelection:(LYRMessage *)message
{
    if ([self.delegate respondsToSelector:@selector(conversationViewController:didSelectMessage:)]) {
        [self.delegate conversationViewController:self didSelectMessage:message];
    }
}

- (CGSize)heightForMessageAtIndexPath:(NSIndexPath *)indexPath
{
    CGFloat width = self.collectionView.bounds.size.width;
    CGFloat height = 0;
    if ([self.delegate respondsToSelector:@selector(conversationViewController:heightForMessage:withCellWidth:)]) {
        LYRMessage *message = [self.conversationDataSource messageAtCollectionViewIndexPath:indexPath];
        height = [self.delegate conversationViewController:self heightForMessage:message withCellWidth:width];
    }
    if (!height) {
        height = [self defaultCellHeightForItemAtIndexPath:indexPath];
    }
    return CGSizeMake(width, height);
}

- (NSOrderedSet *)messagesForMediaAttachments:(NSArray *)mediaAttachments
{
    NSOrderedSet *messages;
    if ([self.delegate respondsToSelector:@selector(conversationViewController:messagesForMediaAttachments:)]) {
        messages = [self.delegate conversationViewController:self messagesForMediaAttachments:mediaAttachments];
        // If delegate returns an empty set, don't send any messages.
        if (messages && !messages.count) return nil;
    }
    // If delegate returns nil, we fall back to default behavior.
    if (!messages) messages = [self defaultMessagesForMediaAttachments:mediaAttachments];
    return messages;
}

#pragma mark - Data Source

- (id<ATLParticipant>)participantForIdentifier:(NSString *)identifier
{
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:participantForIdentifier:)]) {
        return [self.dataSource conversationViewController:self participantForIdentifier:identifier];
    } else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"ATLConversationViewControllerDelegate must return a participant for an identifier" userInfo:nil];
    }
}

- (NSAttributedString *)attributedStringForMessageDate:(LYRMessage *)message
{
    NSAttributedString *dateString;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:attributedStringForDisplayOfDate:)]) {
        NSDate *date = message.sentAt ?: [NSDate date];
        dateString = [self.dataSource conversationViewController:self attributedStringForDisplayOfDate:date];
        NSAssert([dateString isKindOfClass:[NSAttributedString class]], @"Date string must be an attributed string");
    } else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"ATLConversationViewControllerDataSource must return an attributed string for Date" userInfo:nil];
    }
    return dateString;
}

- (NSAttributedString *)attributedStringForRecipientStatusOfMessage:(LYRMessage *)message
{
    NSAttributedString *recipientStatusString;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:attributedStringForDisplayOfRecipientStatus:)]) {
        recipientStatusString = [self.dataSource conversationViewController:self attributedStringForDisplayOfRecipientStatus:message.recipientStatusByUserID];
        NSAssert([recipientStatusString isKindOfClass:[NSAttributedString class]], @"Recipient String must be an attributed string");
    } else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"ATLConversationViewControllerDataSource must return an attributed string for recipient status" userInfo:nil];
    }
    return recipientStatusString;
}

- (NSString *)reuseIdentifierForMessage:(LYRMessage *)message atIndexPath:(NSIndexPath *)indexPath
{
    NSString *reuseIdentifier;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:reuseIdentifierForMessage:)]) {
        reuseIdentifier = [self.dataSource conversationViewController:self reuseIdentifierForMessage:message];
    }
    if (!reuseIdentifier) {
        if ([self.layerClient.authenticatedUserID isEqualToString:message.sentByUserID]) {
            reuseIdentifier = ATLOutgoingMessageCellIdentifier;
        } else {
            reuseIdentifier = ATLIncomingMessageCellIdentifier;
        }
    }
    return reuseIdentifier;
}

- (LYRConversation *)conversationWithParticipants:(NSSet *)participants
{
    if (participants.count == 0) return nil;
    
    LYRConversation *conversation;
    if ([self.dataSource respondsToSelector:@selector(conversationViewController:conversationWithParticipants:)]) {
        conversation = [self.dataSource conversationViewController:self conversationWithParticipants:participants];
        if (conversation) return conversation;
    }
    NSSet *participantIdentifiers = [participants valueForKey:@"participantIdentifier"];
    conversation = [self existingConversationWithParticipantIdentifiers:participantIdentifiers];
    if (conversation) return conversation;
    
    BOOL deliveryReceiptsEnabled = participants.count <= 5;
    NSDictionary *options = @{LYRConversationOptionsDeliveryReceiptsEnabledKey: @(deliveryReceiptsEnabled)};
    conversation = [self.layerClient newConversationWithParticipants:participantIdentifiers options:options error:nil];
    return conversation;
}

- (LYRConversation *)existingConversationWithParticipantIdentifiers:(NSSet *)participantIdentifiers
{
    NSMutableSet *set = [participantIdentifiers mutableCopy];
    [set addObject:self.layerClient.authenticatedUserID];
    LYRQuery *query = [LYRQuery queryWithClass:[LYRConversation class]];
    query.predicate = [LYRPredicate predicateWithProperty:@"participants" operator:LYRPredicateOperatorIsEqualTo value:set];
    query.limit = 1;
    return [self.layerClient executeQuery:query error:nil].lastObject;
}

#pragma mark - Helpers

- (void)configureScrollIndicatorInset
{
    UIEdgeInsets contentInset = self.collectionView.contentInset;
    UIEdgeInsets scrollIndicatorInsets = self.collectionView.scrollIndicatorInsets;
    CGRect frame = [self.view convertRect:self.addressBarController.addressBarView.frame fromView:self.addressBarController.addressBarView.superview];
    contentInset.top = CGRectGetMaxY(frame);
    scrollIndicatorInsets.top = contentInset.top;
    self.collectionView.contentInset = contentInset;
    self.collectionView.scrollIndicatorInsets = scrollIndicatorInsets;
}

- (void)updateViewConstraints
{
    CGFloat typingIndicatorBottomConstraintConstant = -self.collectionView.scrollIndicatorInsets.bottom;
    if (self.messageInputToolbar.superview) {
        CGRect toolbarFrame = [self.view convertRect:self.messageInputToolbar.frame fromView:self.messageInputToolbar.superview];
        CGFloat keyboardOnscreenHeight = CGRectGetHeight(self.view.frame) - CGRectGetMinY(toolbarFrame);
        if (-keyboardOnscreenHeight > typingIndicatorBottomConstraintConstant) {
            typingIndicatorBottomConstraintConstant = -keyboardOnscreenHeight;
        }
    }
    self.typingIndicatorViewBottomConstraint.constant = typingIndicatorBottomConstraintConstant;
    
    [super updateViewConstraints];
}

- (void)scrollToBottomOfCollectionViewAnimated:(BOOL)animated
{
    CGSize contentSize = self.collectionView.contentSize;
    [self.collectionView setContentOffset:[self bottomOffsetForContentSize:contentSize] animated:animated];
}

- (NSOrderedSet *)participantsForIdentifiers:(NSOrderedSet *)identifiers
{
    NSMutableOrderedSet *participants = [NSMutableOrderedSet new];
    for (NSString *participantIdentifier in identifiers) {
        id<ATLParticipant> participant = [self participantForIdentifier:participantIdentifier];
        if (!participant) continue;
        [participants addObject:participant];
    }
    return participants;
}

- (NSString *)participantNameForMessage:(LYRMessage *)message
{
    id<ATLParticipant> participant = [self participantForIdentifier:message.sentByUserID];
    NSString *participantName = participant.fullName ?: @"Unknown User";
    return participantName;
}

#pragma mark - Auto Layout Configuration

- (void)configureCollectionViewLayoutConstraints
{
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeRight multiplier:1.0 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeTop multiplier:1.0 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.collectionView attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom multiplier:1.0 constant:0]];
}

- (void)configureTypingIndicatorLayoutConstraints
{
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.typingIndicatorViewController.view attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.typingIndicatorViewController.view attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeWidth multiplier:1.0 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.typingIndicatorViewController.view attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:ATLTypingIndicatorHeight]];
    self.typingIndicatorViewBottomConstraint = [NSLayoutConstraint constraintWithItem:self.typingIndicatorViewController.view attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom multiplier:1.0 constant:0];
    [self.view addConstraint:self.typingIndicatorViewBottomConstraint];
}

- (void)configureAddressBarLayoutConstraints
{
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.addressBarController.view attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.addressBarController.view attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeWidth multiplier:1.0 constant:0.0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.addressBarController.view attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.topLayoutGuide attribute:NSLayoutAttributeBottom multiplier:1.0 constant:0]];
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:self.addressBarController.view attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeBottom multiplier:1.0 constant:0]];
}

#pragma mark - NSNotification Center Registration

- (void)registerForNotifications
{
    // Keyboard Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    // ATLMessageInputToolbar Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textViewTextDidBeginEditing:) name:UITextViewTextDidBeginEditingNotification object:self.messageInputToolbar.textInputView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(messageInputToolbarDidChangeHeight:) name:ATLMessageInputToolbarDidChangeHeightNotification object:self.messageInputToolbar];
    
    // Layer Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveTypingIndicator:) name:LYRConversationDidReceiveTypingIndicatorNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(layerClientObjectsDidChange:) name:LYRClientObjectsDidChangeNotification object:nil];
    
    // Application State Notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
}
@end