// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OpenArcCore.framework umbrella header.
//
// The Chromium bridge's public Objective-C API (plan C7). The Swift target `OpenArcChromium`
// (plan C8) imports this module and implements `BrowserEngine` on top of it. Architecture,
// threading and ownership rules: chromium-bridge/README.md.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACBrowserApplication.h>
#import <OpenArcCore/OACApplication.h>
#import <OpenArcCore/OACProfile.h>
#import <OpenArcCore/OACTab.h>
#import <OpenArcCore/OACTabDelegate.h>
#import <OpenArcCore/OACDialogDelegate.h>
#import <OpenArcCore/OACAutofill.h>
#import <OpenArcCore/OACSiteSettings.h>
#import <OpenArcCore/OACDownloads.h>
#import <OpenArcCore/OACExtensions.h>
#import <OpenArcCore/OACImport.h>
#import <OpenArcCore/OACTranslation.h>
