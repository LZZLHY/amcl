# Contributing to AMCL

[简体中文](CONTRIBUTING.md) · [Project overview](README.en.md)

We welcome issue reports, steps to reproduce a problem, documentation improvements, and code fixes. A good first contribution is a small change you can explain and verify on its own. Before designing a feature or changing a third-party dependency, open an issue with your goal and proposed approach so maintainers can discuss it with you.

## How source releases work

Day-to-day development takes place in a private upstream repository. When a maintainer publishes a release, they sync the corresponding source, required third-party inputs, and build instructions to this public repository. Features under development may therefore first appear here in a later release. The app source is in [`MyApplication/`](MyApplication/). The [snapshot manifest](MyApplication/SOURCE_SNAPSHOT.json) records the version and its source.

You can study, build, and modify a public version and submit your changes as a pull request. App code contributions usually follow this sequence.

1. You open a public PR and include your verification results.
2. A maintainer reviews the change and imports accepted code into the private upstream repository.
3. The PR is marked accepted, pending release.
4. A later release brings the change back to the public repository. The maintainer links the public release and closes the PR.

An accepted app code PR can stay open while it waits for release. Maintainers will indicate whether they have accepted, requested changes to, deferred, or declined a contribution. Changes specific to the public repository, such as its contribution guide, README, and CI, can be merged independently. [Maintainer guide to accepting contributions and syncing them back](docs/maintainers/contributions.md)

## Where to start

| What you want to do | First step |
| --- | --- |
| Report a crash, unexpected behavior, or a build failure | [Open an issue](https://github.com/LZZLHY/amcl/issues/new/choose) with the version, environment, and a minimal reproduction. |
| Propose a feature or a substantial architectural change | Open a feature request describing the use case, expected behavior, and what can be verified. |
| Fix a specific problem | Read the related issue, then follow the steps below to create a branch and PR. |
| Improve wording, build instructions, or contributor guidance | Open a focused PR that identifies the affected documents and explains what you checked. |
| Modify a third-party component or update a dependency | Identify the upstream source, pinned commit, patches, license, and affected build steps. |

Search existing issues and pull requests before submitting. Keep each PR focused on one problem. Separate functional fixes, repository-wide formatting, dependency upgrades, and directory reorganization when they serve different purposes.

## 1. Fork, clone, and create a branch

Fork [LZZLHY/amcl](https://github.com/LZZLHY/amcl) on GitHub, then clone your fork. Replace `YOUR_NAME` with your GitHub username. After cloning, run the repository commands from the outer `amcl` directory. The app project is one directory below it in `MyApplication/`.

```powershell
git -c core.longpaths=true clone https://github.com/YOUR_NAME/amcl.git amcl
Set-Location amcl
git remote add upstream https://github.com/LZZLHY/amcl.git
git fetch upstream main
git switch -c fix/describe-the-problem upstream/main
git config core.longpaths true
```

Choose a short local path to stay within the path limits of native tools on Windows. Keep the outer Git repository intact. GitHub’s source ZIP omits the third-party submodule working trees and Git history needed by the checks below.

Before editing, you can check the inputs for the official snapshot you just cloned.

```powershell
node MyApplication/scripts/check-public-snapshot.mjs
```

This command verifies files against the original snapshot. Once you edit them, their hashes will naturally differ. Use the PR checks in section 4 to validate your contribution.

## 2. Prepare the environment for your change

**For public documentation or templates**, check the wording, relative links, examples, and rendered template. You can do that without setting up all the app dependencies.

**For app source changes or app tests**, read the [public build guide](docs/en/build.md) first. It gives the SDK, JDK, and Rust requirements, tool paths, signing requirements, and HAP build steps.

From the repository root, enter the app project and prepare its dependencies.

```powershell
Set-Location MyApplication
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

The preparation script restores the pinned third-party sources and other inputs required by a normal build. A recursive submodule update alone leaves some of these steps undone. If you have edited a third-party working tree, save your changes before preparing it again or switching revisions.

Use your own local configuration and signing materials. Building an unsigned HAP verifies compilation. Installing and running it on a device also requires your own valid signature and matching provisioning profile. [Build and signing instructions](docs/en/build.md)

## 3. Make the change

- Check the existing implementation, its callers, and its tests. Explain when the problem occurs and how your change handles that case.
- Keep the diff focused and follow the surrounding code style. For new or modified AMCL-owned logic, write accurate **Chinese comments** explaining responsibilities, key conditions, failure handling, and any relevant threading or resource constraints. Existing third-party code and comments can stay in their original language.
- For a behavior fix, prefer a focused test that distinguishes the original behavior from the fix. For small wording or link changes, you can verify the documents directly.
- When adding or changing a third-party adaptation, supply the upstream URL, exact commit or tag, patches and their application order, build instructions, and license source. A commit referenced by a submodule must be available from a public URL.
- Include the necessary source files, fixed test inputs, and build recipes in the PR. Keep local SDKs, caches, device private keys, account tokens, and raw personal data out of the repository. Review any log excerpts and include only what helps explain the issue.

Ordinary fixes do not require edits to these release records.

- `MyApplication/SOURCE_SNAPSHOT.json` and the official snapshot hashes.
- The official app version, update feeds, and public release notes.
- Official signing materials, device capability approvals, or release identifiers.

If your change specifically concerns a dependency lock, the version mechanism, or one of those records, explain why in the PR and describe the expected handling. For dependency upgrades, include the required lockfile and patch changes. If an input cannot be traced to its source or its build fails, report the failure and keep the original hash available for investigation.

## 4. Verify the change and describe what you tested

Return to the repository root and run the public contribution check and the whitespace check.

```powershell
$BaseCommit = git merge-base HEAD upstream/main
node tools/check-public-contribution.mjs --base $BaseCommit
git diff --check
```

`$BaseCommit` should be the full 40-character hash of the common ancestor of your branch and the `upstream/main` you fetched. The contribution check verifies the public baseline, the scope of the changes, and basic repository requirements. ArkTS or native compilation, building a HAP, and running it on a device each need their own checks. A maintainer may ask for additional verification specific to the change.

| Scope of change | Suggested verification |
| --- | --- |
| Documentation or issue and PR templates | Check relative links, example commands, rendered output, and template fields. |
| Node.js, Python, or build tools | Run the relevant script checks and targeted regression tests. Describe the failure cases you checked. |
| ArkTS, Java, native code, or app resources | Run the relevant tests and the applicable HAP build from the [build guide](docs/en/build.md). |
| Input, windows, graphics, audio, installation, or lifecycle behavior | Along with the build result, list the devices, versions, and steps actually tested. Identify any cases still unverified. |
| Third-party sources, patches, or artifacts | Identify the source revision, report how preparation or patch application went, and verify the corresponding build. Report source rebuild success and byte-for-byte artifact comparison separately. |

In your PR, say what you ran, what happened, and what still needs verification. For example, “The public checks and targeted tests passed. I had no HarmonyOS device available to test installation or launch the game.” If your environment prevents further testing, you can open a draft PR and describe what is missing, or contribute a minimal reproduction and your findings.

Builds can generate JARs, product metadata, and other files. Review the diff before committing. Include the sources, fixed inputs, and documentation needed for the change. Leave incidental generated changes out of the PR and identify unfamiliar files before deleting them.

## 5. Commit and open a pull request

Check your working tree, stage the specific files, commit them to your branch, and push to your fork. Replace the example paths below with the files you actually changed.

```powershell
git status --short
git add -- path/to/changed-file path/to/related-test
git diff --cached --check
git diff --cached --stat
git commit -m "fix: describe the corrected behavior"
git push -u origin fix/describe-the-problem
```

Open a PR targeting `LZZLHY/amcl:main` on GitHub and fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Include the following details.

- The problem or goal, the related issue, and a minimal reproduction.
- The public version or commit you started from.
- What you changed and why.
- The checks you ran and their results, plus anything you could not verify.
- Any changes to third-party inputs or their sources.

Keep follow-up changes in the same PR during review. If a new public release appears, you can merge or rebase onto the updated `upstream/main`. Save your local changes first and avoid force-cleaning away your work. After a change in behavior, rerun the affected checks.

## What happens after review

Maintainers account for differences between the public release and the private upstream code when accepting contributions. An accepted change may need adaptation to the current implementation. If the published result differs substantially from the patch, the maintainer should explain the difference in the PR.

Typical statuses for app source PRs are *under review*, *changes requested*, *accepted, pending release*, and *released*. Once released, the maintainer links the actual public tag or commit and credits the contributor. Acceptance carries no promise of a specific release date. Independent public documentation and CI changes usually merge directly.

By submitting a contribution, you agree to contribute material you have the right to submit under the existing [license](LICENSE) for the affected part of the project. For third-party code, images, or other assets, include the source and licensing information so a maintainer can verify them.
