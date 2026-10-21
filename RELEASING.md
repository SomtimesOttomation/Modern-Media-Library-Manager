# Releasing

A release is built by GitHub, not on a laptop, so the zip, its hash and the scan all describe exactly the same file.

## One-time setup

1. Create a free VirusTotal account and copy your API key (profile menu, API key).
2. In the repository: Settings, Secrets and variables, Actions, New repository secret. Name it `VT_API_KEY` and paste the key.
   Without it the release still publishes, and the notes say the zip was not scanned.
3. Settings, Actions, General: leave Workflow permissions on read-only. The release workflow asks for the write access it needs (`contents: write`, attestations) inside its own file, which takes precedence.
4. Optional hardening: tick "Require actions to be pinned to a full-length commit SHA". The workflow already complies, and `.github/dependabot.yml` opens a monthly pull request when a newer version of an action is out.

## Each release

1. Merge or commit the changes to the default branch.
2. Tag the commit and push the tag. The tag message becomes the top of the release notes, so write what changed:

       git tag -a v1.2.0 -m "Collections, release-date order, popup"
       git push origin v1.2.0

3. Open the Actions tab and watch the "Release" run. When it finishes, the release appears with:
   - the zip, named `Modern-Media-Library-Manager-v1.2.0.zip`
   - `SHA256SUMS.txt`
   - the zip's SHA-256, the VirusTotal link and result, and the attestation command in the notes

## Checking a release yourself

    Get-FileHash .\Modern-Media-Library-Manager-v1.2.0.zip -Algorithm SHA256
    gh attestation verify .\Modern-Media-Library-Manager-v1.2.0.zip --repo OWNER/REPO

The hash must match the release notes (case does not matter). The attestation command needs the GitHub CLI.

## Notes

- Only the files listed in the "Build the zip" step go into the release zip. Add new user-facing files there.
- VirusTotal's free API allows a few requests a minute and a few hundred a day, which is plenty for releases.
- Heuristic antivirus engines sometimes flag unsigned PowerShell scripts that download files. The notes show the real count; the README explains why.
