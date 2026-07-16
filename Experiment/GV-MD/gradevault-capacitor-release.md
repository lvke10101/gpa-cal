---
name: gradevault-capacitor-release
description: Use this skill for GradeVault's Capacitor/Android packaging, GitHub Actions CI, APK builds, device fragmentation, safe-area or dvh viewport issues, WebView-specific rendering bugs, or release-readiness checks. Trigger whenever the user mentions building, packaging, signing, testing on a phone, "will this work on Android," CI failures, or anything touching www/index.html as it relates to the app shell rather than page content — even if not phrased as a "release" question.
---

# GradeVault Capacitor / Release

## Stack reality

- The same `www/index.html` that runs as the web frontend is wrapped by Capacitor into the Android app.
- Build path: Capacitor → `android/` Gradle project → GitHub Actions CI → signed APK.
- No iOS target currently in scope. Do not introduce iOS-specific assumptions unless asked.
- This is a WebView, not a browser tab — behavior differs from desktop Chrome in ways that don't show up until it's on a device.

## Checklist for any change that could affect packaging or device behavior

1. **`vh` vs `dvh`.** Any full-height section must use `min-height: 100dvh`, never `100vh` — the project has already done one pass fixing this; don't reintroduce `vh` in new code.
2. **Safe-area insets.** Any fixed/sticky element near a screen edge needs `env(safe-area-inset-*)` handling. Check this on every new fixed nav, bottom bar, or modal.
3. **WebView rendering quirks.** `loading="lazy"` has already been found unreliable in this WebView (this is why images now go through client-side canvas compression before upload). Don't assume standard browser lazy-load behavior works here — verify on-device or fall back to the compression approach already in place.
4. **Touch targets.** Minimum comfortable tap size, not desktop-hover-sized click targets. No feature should assume hover as the only affordance.
5. **Horizontal-scroll rows.** The project has fixed-width horizontal-scroll rows with a fade affordance that has only been stress-tested on two devices — treat this pattern as fragile until proven otherwise on a wider device set, and flag any new use of it as unverified.
6. **Hardware back button / navigation.** Android has a system back gesture/button that web-only testing won't surface. Any new modal, sheet, or nested view needs an explicit answer for what back does.
7. **Signing and versioning.** Any release-bound change needs a version bump plan and confirmation the CI signing step still succeeds — don't treat this as automatic.

## Release readiness checklist

- Build succeeds in GitHub Actions, not just locally.
- Tested on at least the two previously-reported devices at minimum; flag if the change touches the untested horizontal-scroll pattern.
- No `vh`-based full-height sections reintroduced.
- Safe-area handling present on any new edge-anchored UI.
- No dead-end navigation — every new screen has a way back that works with the hardware back button.

## Answer format

1. What's happening / what's being asked
2. Build impact — does this touch the Capacitor/Android build itself or just page content
3. Android packaging impact — Gradle config, permissions, signing
4. CI impact — does the GitHub Actions pipeline need changes
5. Device testing impact — what needs to be checked on-device that a browser won't reveal
6. What to change first, what to avoid
