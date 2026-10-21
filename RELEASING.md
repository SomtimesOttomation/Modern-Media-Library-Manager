# Releasing

A release is built by GitHub, not on a laptop, so the zip, its hash and the scan all describe exactly the same file.

## One-time setup

1. Create a free VirusTotal account and copy your API key (profile menu, API key).
2. In the repository: Settings, Secrets and variables, Actions, New repository secret. Name it `VT_API_KEY` and paste the key.
   Without it the release still publishes, and the notes say the zip was not scanned.
3. Settings, Actions, General: leave Workflow permissions on read-only. The release workflow asks for the write access it needs (`contents: write`, attestations) inside its own file, which takes precedence.
4. Optional hardening: tick "Require actions to be pinned to a full-length commit SHA". The workflow already complies, and `.github/dependabot.yml` opens a monthly pull request when a newer version of an action is out.

## Each release

Bump `$script:AppVersion` near the top of `Modern-Media-Library-Manager.ps1` to the new version (for tag `v1.2.0` it is `'1.2.0'`) and merge that to the default branch. The release workflow stops with a clear message if the number and the tag disagree, because the in-app updater compares them.

Merge or commit the changes to the default branch first. Then pick one way to start the release. Both end the same way.

**In the browser (no command line)**

1. On the repository's main page, click Releases in the right-hand column, then "Draft a new release".
2. Click "Choose a tag", type a version such as `v1.2.0`, and click "Create new tag: v1.2.0 on publish".
3. Give it the title `v1.2.0` and describe what changed in the description box.
4. Click "Publish release".

**From a command line**

    git tag -a v1.2.0 -m "Collections, release-date order, popup"
    git push origin v1.2.0

Either way, open the Actions tab and watch the "Release" run. When it finishes (a green tick), the release has:
- the zip, named `Modern-Media-Library-Manager-v1.2.0.zip`
- `SHA256SUMS.txt`
- your description, followed by the zip's SHA-256, the VirusTotal link and result, and the attestation command

If you created the release in the browser, the workflow keeps what you wrote and adds the files and the verification block to it.

## Checking a release yourself

    Get-FileHash .\Modern-Media-Library-Manager-v1.2.0.zip -Algorithm SHA256
    gh attestation verify .\Modern-Media-Library-Manager-v1.2.0.zip --repo OWNER/REPO

The hash must match the release notes (case does not matter). The attestation command needs the GitHub CLI.

## Notes

- Only the files listed in the "Build the zip" step go into the release zip. Add new user-facing files there.
- VirusTotal's free API allows a few requests a minute and a few hundred a day, which is plenty for releases.
- Heuristic antivirus engines sometimes flag unsigned PowerShell scripts that download files. The notes show the real count; the README explains why.
