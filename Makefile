# Use the full Xcode even when xcode-select points at the Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Sheaf.app
XCODEBUILD := xcodebuild -project Sheaf.xcodeproj -scheme Sheaf -derivedDataPath $(DERIVED) -destination 'platform=macOS'

.PHONY: project build test run ci corpus clean

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

clean:
	rm -rf $(DERIVED) Sheaf.xcodeproj Packages/SheafKit/.build
