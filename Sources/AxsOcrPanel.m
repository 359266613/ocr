#import "AxsOcrPanel.h"
#import <UIKit/UIKit.h>

static UIWindow *axs_ocr_panelWindow;

static void axs_ocr_dismissPanel(void) {
    axs_ocr_panelWindow.hidden = YES;
    axs_ocr_panelWindow = nil;
}

// A UIWindow without a scene does not show on iOS 13+, so bind to the SpringBoard scene.
static UIWindowScene *axs_ocr_activeScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if ([windowScene.session.persistentIdentifier containsString:@"SystemAperture"]) continue;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) return windowScene;
        if (!fallback) fallback = windowScene;
    }
    return fallback;
}

@interface AxsOcrPanelController : UIViewController
@property (nonatomic, copy) NSString *axs_ocr_text;
@property (nonatomic, assign) BOOL axs_ocr_copyable;
- (void)axs_ocr_buildInterface;
@end

@implementation AxsOcrPanelController

- (UIButton *)axs_ocr_buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// Called once by the panel after the text is set; avoids overriding system lifecycle methods.
- (void)axs_ocr_buildInterface {
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    [self.view addSubview:card];

    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.text = self.axs_ocr_text;
    textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    textView.adjustsFontForContentSizeCategory = YES;
    textView.textColor = [UIColor labelColor];
    textView.backgroundColor = [UIColor clearColor];
    textView.accessibilityLabel = @"识别结果";

    UIStackView *buttons = [[UIStackView alloc] init];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    if (self.axs_ocr_copyable) {
        [buttons addArrangedSubview:[self axs_ocr_buttonWithTitle:@"复制全部" action:@selector(axs_ocr_copy:)]];
    }
    [buttons addArrangedSubview:[self axs_ocr_buttonWithTitle:@"关闭" action:@selector(axs_ocr_close)]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[textView, buttons]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.88],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.7],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
        [textView.heightAnchor constraintGreaterThanOrEqualToConstant:80],
        [buttons.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
}

- (void)axs_ocr_copy:(UIButton *)sender {
    [UIPasteboard generalPasteboard].string = self.axs_ocr_text;
    [sender setTitle:@"已复制" forState:UIControlStateNormal];
}

- (void)axs_ocr_close {
    axs_ocr_dismissPanel();
}

@end

@implementation AxsOcrPanel

+ (void)axs_ocr_dismiss {
    axs_ocr_dismissPanel();
}

+ (void)axs_ocr_showText:(NSString *)text copyable:(BOOL)copyable {
    axs_ocr_dismissPanel();

    AxsOcrPanelController *controller = [[AxsOcrPanelController alloc] init];
    controller.axs_ocr_text = text;
    controller.axs_ocr_copyable = copyable;
    [controller axs_ocr_buildInterface];

    UIWindowScene *scene = axs_ocr_activeScene();
    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                             : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = UIScreen.mainScreen.bounds;
    window.windowLevel = UIWindowLevelAlert + 10;
    window.rootViewController = controller;
    axs_ocr_panelWindow = window;
    [window makeKeyAndVisible];
}

@end
