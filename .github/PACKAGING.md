# Release packaging

Use **Prepare release** and **Release check** as before. The tag must match `addon.version`, for example `v1.0.1`.

- `.github/release.json` lists every file allowed in the ZIP. Add new runtime modules there; missing files stop packaging.
- Edit the root `README.md` for GitHub. Packaging converts it to plain Markdown inside `addons/playernotes/README.md`, preserving the source.
- Documentation comes from the revision being packaged. Existing ZIPs do not update when documentation changes.
- Internal notes, screenshots, tests, tools, backups, and temporary files are not release files.

Preview the release README in PowerShell:

```powershell
./.github/scripts/export-readme.ps1 -Output "$env:TEMP/PlayerNotes-README.md"
```

Run the packaging checks:

```powershell
./.github/scripts/test-release-package.ps1
```

The six bundled alert sounds are required package files. User databases and exported profiles never enter the release.
