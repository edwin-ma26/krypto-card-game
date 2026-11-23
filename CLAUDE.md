# Krypto — working agreements

iOS app (SwiftUI, `Krypto/`) + Firebase backend (`functions/`, `firestore.rules`,
`firestore.indexes.json`, `remoteconfig.template.json`) for project `krypto-game-em26`.

## Branching (several sessions work on this repo at once)

- **Never commit to `main` directly.** Every piece of work gets its own branch
  from `main`: `feature/<topic>`, `fix/<topic>`.
- **One worktree per session.** A branch alone does not isolate files: two
  sessions in the same folder overwrite each other's edits even on different
  branches. Start parallel work in its own checkout:

  ```sh
  git worktree add ../Krypto-worktrees/<topic> -b feature/<topic> main
  ```

  Worktrees live in `Dev/Krypto-worktrees/`, one folder per topic, so the
  `Dev` folder holds only `Krypto` and that one directory. (Claude Code: use
  the worktree isolation option when launching work.) Remove it with
  `git worktree remove ../Krypto-worktrees/<topic>` once merged.
- Commit small and often on the branch, then open a PR (or merge) to `main`.
  Rebase on `main` before merging. Delete the branch after.
- Only stage files you changed for the task. Leave another session's edits
  alone, even if they are in the same file.
- **Stay in your own lane.** Never rebase, cherry-pick onto, reset, or
  delete a branch or worktree you did not create in this session, even to
  "help" another session along. If you need another branch's unmerged code,
  say so and wait for it to be merged into `main`; do not stack its commits
  on your branch. `main` is the only hand-off point between sessions.
- **Removing worktrees and deleting branches is the user's job**, after the
  merge. Sessions create them; they do not clean them up unless asked.
- **The `Krypto/` folder stays on `main`.** Never check out a feature branch
  there; every other session reads it as the clean baseline. Feature work
  always lives in a sibling worktree.

## Project file

- `project.yml` is the source of truth; `Krypto.xcodeproj` is generated. After
  adding or removing a Swift file run `xcodegen generate`. On a
  `project.pbxproj` merge conflict, take either side and regenerate rather than
  resolving by hand.

## Backend deploys

- Deploy rules / indexes / functions / Remote Config **from `main` after the
  branch is merged**, not from a feature branch, so the deployed backend
  always matches `main`. The one exception is an additive rule a feature needs
  to be testable on device; say so in the commit message.
- Client changes only reach players with a new App Store build.

## Build check

```sh
xcodebuild -project Krypto.xcodeproj -scheme Krypto \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "BUILD|error:"
```

Debug env `KRYPTO_DEMO_STATS=1` opens the profile hub and Stats signed out with seeded data.

## Android client (`android/`, Kotlin + Compose, package `com.edwinma.krypto`)

- Shares the same Firebase project; `android/app/google-services.json` is the
  Android app's config. Game rules in `KryptoEngine.kt`/`Fraction.kt` must stay
  in step with `Krypto/GameEngine.swift` and `functions/src/krypto.ts`.
- Build check (needs `brew install openjdk@17 android-commandlinetools`, SDK in
  `~/Library/Android/sdk`):

  ```sh
  cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew testDebugUnitTest assembleDebug
  ```
