// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The password manager's save prompt and the autofill dropdown, drawn by the shell (plan C13), and
// Autofill's address and payment-card save prompts (plan C30).
//
// Maps to: `EngineDialogRequest.passwordSave`, `.autofillPopup`, `.addressSave` and `.cardSave`
// (app/Sources/OpenArcEngine/DialogRequests.swift).
//
// Why shell-drawn (README §Keeping //chrome without its UI): Chrome draws its password bubble and
// its autofill popup with Views anchored to a `Browser` window, which our tabs do not have. We keep
// //chrome's controllers: the password manager decides WHEN to offer saving (a successful login
// form submission, its blocklist and dismissal counts) and fills credentials into the form; the
// autofill controller decides WHAT to suggest for the focused field (saved passwords, addresses,
// cards, previously typed values) and fills the form. The bridge replaces only their views (two
// Open Arc hooks into //chrome) and hands each prompt to the tab's `OACDialogDelegate` as a
// request, like the C12 dialogs (OACDialogDelegate.h: answer once; the engine may withdraw it;
// releasing it unanswered answers with its default).
//
// The look of both is not in docs/arc-spec (00 §A records "password, autofill, payments: inherited
// from the engine; prompts drawn by the shell, style not captured"): unknown.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACDialogDelegate.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Password save prompt

typedef NS_ENUM(NSInteger, OACPasswordSavePromptKind) {
    /// A new credential for the site ("Save password?").
    OACPasswordSavePromptKindSave = 0,
    /// A new password for a saved username ("Update password?").
    OACPasswordSavePromptKindUpdate = 1,
};

/// The password manager offers to save (or update) the credential the user just signed in with.
/// Shown after the login form was submitted and the page navigated on. The password itself never
/// leaves the engine; the shell shows `passwordLength` dots.
///
/// Default answer (dropped or cancelled): closed without a choice. Chrome counts such dismissals
/// and stops offering automatically on a site after a few.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACPasswordSavePrompt : OACDialogRequest
@property (nonatomic, readonly) OACPasswordSavePromptKind kind;
/// The username the form submitted (may be empty; the user can edit it before saving).
@property (nonatomic, readonly, copy) NSString *username;
/// Number of characters of the password, for the masked field.
@property (nonatomic, readonly) NSUInteger passwordLength;

/// Save (or update). `username` replaces the submitted username when non-nil.
- (void)saveWithUsername:(nullable NSString *)username NS_SWIFT_NAME(save(username:));
/// "Never for this site": the site goes on the profile's blocklist (save prompts only; an update
/// prompt treats it as `-decline`).
- (void)neverForThisSite;
/// "Not now" / "No thanks": declined this time.
- (void)decline;
@end

// MARK: - Address save prompt (plan C30)

typedef NS_ENUM(NSInteger, OACAddressSavePromptKind) {
    /// A new address ("Save address?").
    OACAddressSavePromptKindSave = 0,
    /// New values for a saved address ("Update address?"); `changes` lists them.
    OACAddressSavePromptKindUpdate = 1,
};

typedef NS_ENUM(NSInteger, OACAddressFieldKind) {
    OACAddressFieldKindName = 0,
    /// The postal address (street, city, region, postal code, country), as one block.
    OACAddressFieldKindAddress = 1,
    OACAddressFieldKindEmail = 2,
    OACAddressFieldKindPhone = 3,
};

/// One changed value of an update prompt.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACAddressChange : NSObject
@property (nonatomic, readonly) OACAddressFieldKind field;
/// The saved value (empty when the saved address had none).
@property (nonatomic, readonly, copy) NSString *oldValue;
/// The value the form submitted.
@property (nonatomic, readonly, copy) NSString *updatedValue;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Autofill offers to save the address the user just submitted in a form (or to update a saved
/// one with the submitted values). Chrome decides when to offer (a complete address, not saved
/// yet, the site and the address not refused too often); the shell draws the prompt. Texts are
/// formatted by the engine for the app's locale.
///
/// Default answer (dropped or cancelled): closed without a choice (Chrome counts it as ignored).
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACAddressSavePrompt : OACDialogRequest
@property (nonatomic, readonly) OACAddressSavePromptKind kind;
/// The address as it would be saved: name and postal address in the country's envelope style,
/// several lines. For an update, the address after the update.
@property (nonatomic, readonly, copy) NSString *addressSummary;
/// May be empty.
@property (nonatomic, readonly, copy) NSString *email;
/// Formatted for display; may be empty.
@property (nonatomic, readonly, copy) NSString *phone;
/// Update prompts: the values that change (name, address, email, phone order). Empty for save.
@property (nonatomic, readonly, copy) NSArray<OACAddressChange *> *changes;

/// Save (or update) the address in the profile.
- (void)save;
/// "No thanks": refused this time (Chrome stops offering for this address, or on this site,
/// after a few refusals).
- (void)decline;
@end

// MARK: - Payment card save prompt (plan C30)

typedef NS_ENUM(NSInteger, OACCardSavePromptKind) {
    /// A new card, without its security code.
    OACCardSavePromptKindCard = 0,
    /// A new card with the security code the form submitted.
    OACCardSavePromptKindCardWithSecurityCode = 1,
    /// Only the security code of a card saved earlier.
    OACCardSavePromptKindSecurityCodeOnly = 2,
};

/// Autofill offers to save the payment card the user just submitted in a form, on this Mac, in
/// the profile (never uploaded: Open Arc has no Google Payments). The card number stays in the
/// engine; the shell gets what Chrome's own bubble shows.
///
/// Default answer (dropped or cancelled): closed without a choice (Chrome counts it as ignored
/// and stops offering a card after a few).
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACCardSavePrompt : OACDialogRequest
@property (nonatomic, readonly) OACCardSavePromptKind kind;
/// The card network for display ("Visa", "Mastercard"; may be empty).
@property (nonatomic, readonly, copy) NSString *network;
/// The last four digits of the number.
@property (nonatomic, readonly, copy) NSString *lastFourDigits;
/// "MM/YY"; may be empty.
@property (nonatomic, readonly, copy) NSString *expiration;
/// The name on the card; may be empty.
@property (nonatomic, readonly, copy) NSString *cardholderName;

/// Save the card (or its security code) in the profile.
- (void)save;
/// "No thanks": refused this time.
- (void)decline;
@end

// MARK: - Autofill dropdown

typedef NS_ENUM(NSInteger, OACAutofillSuggestionKind) {
    /// A saved credential (`mainText` is the username).
    OACAutofillSuggestionKindPassword = 0,
    /// A saved address.
    OACAutofillSuggestionKindAddress = 1,
    /// A saved payment card.
    OACAutofillSuggestionKindCreditCard = 2,
    /// A value typed earlier into a field with the same name.
    OACAutofillSuggestionKindAutocomplete = 3,
    /// A `<datalist>` option.
    OACAutofillSuggestionKindDataList = 4,
    /// A row that does something else ("Manage passwords…", "Clear form", a notice).
    OACAutofillSuggestionKindAction = 5,
    /// A heading row (not selectable).
    OACAutofillSuggestionKindTitle = 6,
    /// A divider line (not selectable).
    OACAutofillSuggestionKindSeparator = 7,
};

/// One row of the dropdown.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACAutofillSuggestion : NSObject
@property (nonatomic, readonly) OACAutofillSuggestionKind kind;
/// First line: the value that would be filled (username, name, card label…).
@property (nonatomic, readonly, copy) NSString *mainText;
/// More text on the first line, after `mainText` (may be empty).
@property (nonatomic, readonly, copy) NSString *minorText;
/// Second line (masked password, address summary, card expiry…; may be empty).
@property (nonatomic, readonly, copy) NSString *label;
/// The row can be highlighted (keyboard, hover).
@property (nonatomic, readonly, getter=isSelectable) BOOL selectable;
/// The row can be chosen (`-acceptSuggestionAtIndex:` is ignored otherwise).
@property (nonatomic, readonly, getter=isAcceptable) BOOL acceptable;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// The autofill dropdown for the focused form field. Keyboard focus stays in the page: the engine
/// handles ↑ / ↓ (highlight; the form previews the highlighted row), Return (choose), Tab (choose
/// and move on) and Escape (close) itself and reports the result with
/// `-tab:didUpdateAutofillPopup:`. The shell draws the rows under `elementBounds`, highlights
/// `selectedIndex`, and forwards pointer hover (`-selectSuggestionAtIndex:`) and clicks
/// (`-acceptSuggestionAtIndex:`). The suggestions change while the user types (same object,
/// `-tab:didUpdateAutofillPopup:`). The engine withdraws the request when the field loses focus,
/// the page scrolls or navigates, or a row was chosen.
///
/// Default answer (dropped or cancelled): closed.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACAutofillPopup : OACDialogRequest
@property (nonatomic, readonly, copy) NSArray<OACAutofillSuggestion *> *suggestions;
/// The form field, in points, in the coordinates of the tab's `nativeView` with the origin at its
/// top left (y down).
@property (nonatomic, readonly) CGRect elementBounds;
/// The field's text runs right to left (align the dropdown to the field's right edge).
@property (nonatomic, readonly) BOOL isRightToLeft;
/// The highlighted row, or -1.
@property (nonatomic, readonly) NSInteger selectedIndex;
/// Set by the shell while the pointer is over the dropdown. The engine then keeps the dropdown open
/// when the page loses keyboard focus (a click on the shell's view may take it), so the click that
/// follows can still choose a row. Choosing a row gives the page its focus back.
@property (nonatomic) BOOL containsPointer;

/// Highlights a row and previews it in the form; -1 clears the highlight. Ignored for rows that
/// are not selectable.
- (void)selectSuggestionAtIndex:(NSInteger)index;
/// Chooses a row (fills the form). Clicks within half a second of the dropdown appearing are
/// ignored, as in Chrome (protection against accidental clicks).
- (void)acceptSuggestionAtIndex:(NSInteger)index;
@end

NS_ASSUME_NONNULL_END
