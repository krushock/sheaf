# Use the full Xcode even when xcode-select points at the Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Sheaf.app
XCODEBUILD := xcodebuild -project Sheaf.xcodeproj -scheme Sheaf -derivedDataPath $(DERIVED) -destination 'platform=macOS'

.PHONY: project build test run ci corpus strings help-book release clean

project: ## Generate Sheaf.xcodeproj from project.yml
	xcodegen generate --quiet

build: project ## Build the app
	$(XCODEBUILD) -quiet build

test: project ## Run the engine tests through the app scheme
	$(XCODEBUILD) -quiet test

run: build ## Build and launch
	open $(APP)

ci: test build ## What CI runs

corpus: build ## Run the engine over every PDF that ships with macOS and Xcode
	find /System/Library /Library /usr/share /Applications/Xcode.app /System/Applications -name '*.pdf' -size +1k 2>/dev/null > $(DERIVED)/corpus.txt || true
	cd Packages/SheafKit && SHEAF_CORPUS=$(CURDIR)/$(DERIVED)/corpus.txt swift test --filter CorpusTests 2>&1 | grep -E '^corpus:|^  /|✘'

strings: build ## Sync the string catalog with the code and apply the translations
	Scripts/localize.py

help-book: ## Write the Help Book from Scripts/make-help.py
	Scripts/make-help.py

release: ## Archive, sign, notarize and pack a disk image (see RELEASING.md)
	Scripts/release.sh

clean:
	rm -rf $(DERIVED) Sheaf.xcodeproj Packages/SheafKit/.build
