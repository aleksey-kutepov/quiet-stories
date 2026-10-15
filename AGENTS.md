# Repository workflow

- Preserve existing uncommitted work. A build includes local edits, even before they are committed or pushed.
- In the maintainer's primary checkout, work directly on `main`. Do not create or switch branches or linked worktrees there unless the owner explicitly requests it. Do not force push.
- The maintainer can enforce that local workflow with `git config --local stories.requirePrimaryMain true`. This setting is local and is not inherited by clones. Community forks, feature branches, detached CI checkouts, and source archives build without opting in.
- Build using the current checkout's `Stories.xcodeproj` and shared `Stories` scheme. Run `sh scripts/check-main.sh` to verify the source, or `sh scripts/open-main.sh` to open it in Xcode.
- Keep command-line build artifacts in this checkout's ignored `DerivedData/` directory. Use `sh scripts/test.sh` for the unsigned simulator suite.
- Keep personal signing settings in ignored `Config/Local.xcconfig`; never add credentials, account sessions, build outputs, or recovery backups to Git.
- Read `CONTRIBUTING.md` and `SECURITY.md` before changing authentication, navigation, the script bridge, or session handling.
