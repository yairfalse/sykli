VERSION ?= $(shell tr -d '[:space:]' < VERSION)

.PHONY: release publish dry-run check-version bump-version test-release-scripts

release:
	./scripts/release.sh $(VERSION)

publish:
	./scripts/publish-all.sh $(VERSION)

dry-run:
	./scripts/release.sh $(VERSION) --dry-run --publish

check-version:
	./scripts/check-version.sh

bump-version:
	./scripts/bump-version.sh $(VERSION)

test-release-scripts:
	./tests/release/run.sh
