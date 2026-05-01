# Releasing

Consumers of this action **must pin to a full commit SHA**, not `@main` or a
tag. A mutable ref means anyone who can push to this repo can run arbitrary
code in every consumer's CI.

## Cutting a release

1. Merge changes to `main`.
2. Note the merge commit SHA: `git rev-parse HEAD`.
3. Tag it: `git tag -a validate-plugins/vX.Y.Z -m "..." <SHA> && git push origin --tags`.
4. Update the "current SHA" line in the README usage block.
5. Open PRs against the consuming repos bumping their pinned SHA.

## Consumer pinning

```yaml
# Correct
- uses: anthropics/claude-plugins-community/.github/actions/validate-plugins@2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c

# Wrong — do not ship this
- uses: anthropics/claude-plugins-community/.github/actions/validate-plugins@main
- uses: anthropics/claude-plugins-community/.github/actions/validate-plugins@v1
```

The tag exists for human reference only. The `uses:` line takes the SHA.
