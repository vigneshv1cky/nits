APP      := Nits
BUNDLE   := build/$(APP).app
FRAMEWORKS := -framework Cocoa -framework IOKit -framework CoreDisplay -framework DisplayServices
PRIVATE  := -F /System/Library/PrivateFrameworks

.PHONY: all clean install run

all: $(BUNDLE)

$(BUNDLE): Sources/main.m Resources/Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS
	clang -fobjc-arc -O2 $(FRAMEWORKS) $(PRIVATE) -o $(BUNDLE)/Contents/MacOS/$(APP) Sources/main.m
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - $(BUNDLE)

install: all
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	open /Applications/$(APP).app

run: all
	open $(BUNDLE)

clean:
	rm -rf build
