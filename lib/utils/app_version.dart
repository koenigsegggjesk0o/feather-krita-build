// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// app_version.dart — Single source of truth for the user-facing version
// label.
//
// Keep this in sync with the `version:` field in `pubspec.yaml`. We use a
// plain const (rather than `package_info_plus`) so the About card renders
// synchronously with no native-plugin dependency — important for the
// headless widget tests and for instant first paint on low-end Android.

/// The full `major.minor.patch+build` version string (matches pubspec).
const String kAppVersion = '0.18.0+1';

/// Short `vX.Y.Z` label for display in the About card and release toasts.
const String kAppVersionLabel = 'v0.18.0';
