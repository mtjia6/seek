# Contributing to Seek

Thanks for helping. Bug reports, ranking complaints ("I typed X and the file I wanted was #7") and pull requests are all welcome.

## Build and run

Requirements: macOS 14+, Xcode command-line tools (Swift 6).

```sh
./build.sh                 # release build, bundle, sign, install to ~/Applications, launch
swift build -c release     # just compile
```

`build.sh` signs with your first "Apple Development" identity if you have one, otherwise ad hoc. A stable identity matters: macOS ties folder-access grants to the signature, so ad-hoc builds re-prompt after every rebuild.

## Test

There is no XCTest suite yet; the binary has command-line modes that exercise each layer without the UI:

```sh
.build/release/Seek --query "exact name" "q3report"        # name index + matcher
.build/release/Seek --content "lease agreement" --hybrid    # full text + semantic + fusion
.build/release/Seek --watch-test                            # create/rename/move/delete is picked up live
```

Before opening a PR, run `--watch-test`, and for ranking changes paste the before/after output of `--query` / `--content` for the queries you changed.

## Where things live

The README's [component table](README.md#how-it-works) maps each layer to a file. A few rules that keep the code coherent:

- **Search is keystroke-latency code.** Nothing on the search path may read files, touch the disk, or allocate per entry. Do that work at index time.
- **Exact names always rank first.** Tiers are never crossed by frecency, recency or content scores. A change that lets a content hit outrank an exact name match is a regression.
- **UI values come from `Theme.swift`.** No raw colors, font sizes, radii or durations in view code. Text colors are WCAG AA checked in both appearances; keep them that way.
- **Privacy.** No network access at runtime, and no telemetry. Don't index anything the user excluded or hidden folders.

## Screenshots

README screenshots are taken against a fake home folder so no personal files appear:

```sh
scripts/demo/make-home.sh                                  # writes demo-home/
swift build -c release
scripts/demo/shot.sh home ""                               # home screen
APPEARANCE=light scripts/demo/shot.sh pdf "lease agreement"
```

Images land in `build/shots/`. `shot.sh` presses ⌥Space with `osascript`, so your terminal needs Accessibility permission, and any installed Seek must be quit first. The first run needs a longer `WAIT=15` while the demo home is indexed.

## Releases

Write the notes in `docs/releases/vX.Y.Z.md`, then tag and push:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The Release workflow builds a universal `Seek.app` (`./build.sh --release`), zips it with a `SHA256SUMS` file, and publishes the GitHub Release. The version number comes from the tag.

## Pull requests

- One topic per PR, with a description of what changed and why.
- Commit messages in the imperative ("Rank exact phrases first"), explaining the reason in the body when it isn't obvious.
- UI changes: include a screenshot in light and dark.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE), and that you'll follow the [Code of Conduct](CODE_OF_CONDUCT.md).
