# sample-workspace

A throwaway SwiftPM package for the code-buddy walkthrough (see [`../README.md`](../README.md)).
Small, pure logic, no dependencies — `swift test` finishes in a couple of seconds.

```
Package.swift
Sources/Geometry/Geometry.swift          # Rectangle + area / perimeter / isSquare / scaled — undocumented
Tests/GeometryTests/GeometryTests.swift  # 4 tests
```

**As shipped, all four tests pass.** The walkthrough's setup step copies this directory
somewhere disposable, `git init`s it, then makes a *second* commit that introduces one
regression — `scaled(_:by:)` stops scaling the height. That gives code-buddy something real to
do: run the tests, see the failure, use `git` to find the commit that caused it, fix the source,
re-run the tests. Nothing is broken here in the repo itself.

Don't run code-buddy against this copy directly — it lives inside the `locallm` git repo, so a
`git diff` here would be noisy and `git checkout` would fight the parent repo. Copy it elsewhere
and `git init` there; the walkthrough shows how.
