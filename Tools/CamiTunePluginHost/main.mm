#import "PluginHost.h"
#import "MIDIHost.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <thread>
#include <atomic>
#include <array>
#include <algorithm>
#include <cmath>
#include <stdexcept>

using namespace CamiTunePlugins;
static int protocolFD = -1;
static std::vector<std::unique_ptr<Effect>> effects;
static NSArray<NSDictionary*>* slots;
static NSMutableDictionary<NSString*, NSData*>* savedStates;
static std::atomic<bool> audioFailed{false};
static std::atomic<unsigned> openEditorCount{0};
static int audioSocket = -1;
static std::unique_ptr<MIDIHost> midiHost;

static bool transfer(int fd, void* bytes, size_t size, bool writing) {
    auto p = (uint8_t*)bytes;
    while (size) {
        ssize_t n = writing ? write(fd, p, size) : read(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false; p += n; size -= n;
    }
    return true;
}
void CamiTunePlugins::emit(NSDictionary* event) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data || data.length > 96 * 1024 * 1024) return;
    transfer(protocolFD, (void*)data.bytes, data.length, true); char newline = '\n'; transfer(protocolFD, &newline, 1, true);
}
static bool snapshot(NSUInteger only = NSNotFound) {
    bool succeeded = true;
    for (NSUInteger i = 0; i < effects.size(); ++i) {
        if (only != NSNotFound && i != only) continue;
        @try { try {
            NSData* data = effects[i]->saveState(); NSString* identifier = slots[i][@"id"];
            if (data.length > maximumStateBytes) throw std::runtime_error("The plug-in preset exceeded the size limit. The previous saved preset was kept.");
            if (!data) { succeeded = false; continue; }
            if ([savedStates[identifier] isEqual:data]) continue;
            savedStates[identifier] = data;
            emit(@{@"event": @"state", @"slotID": identifier, @"state": [data base64EncodedStringWithOptions:0]});
        } catch (const std::exception& error) {
            succeeded = false;
            emit(@{@"event": @"snapshotError", @"slotID": slots[i][@"id"], @"message": @(error.what())});
        } } @catch (NSException* error) {
            succeeded = false;
            emit(@{@"event": @"snapshotError", @"slotID": slots[i][@"id"],
                @"message": @"The plug-in could not save its preset. The previous saved preset was kept."});
        }
    }
    return succeeded;
}

// Match SliderThumb in the app, including its enlarged handle hit rectangle.
// NSSliderCell keeps its native track and keyboard/accessibility behavior.
@interface CTSettingsSliderCell : NSSliderCell
@end
@implementation CTSettingsSliderCell
- (NSRect)knobRectFlipped:(BOOL)flipped {
    NSRect native = [super knobRectFlipped:flipped];
    NSRect track = [self barRectFlipped:flipped];
    CGFloat width = self.isVertical ? 22.0 : 12.0;
    CGFloat height = self.isVertical ? 12.0 : 22.0;
    CGFloat x = self.isVertical ? NSMidX(track) : NSMidX(native);
    CGFloat y = self.isVertical ? NSMidY(native) : NSMidY(track);
    return NSUnionRect(native, NSMakeRect(x - width / 2, y - height / 2, width, height));
}
- (void)drawKnob:(NSRect)knobRect {
    CGFloat width = self.isVertical ? 22.0 : 10.0;
    CGFloat height = self.isVertical ? 10.0 : 22.0;
    NSRect track = [self barRectFlipped:self.controlView.isFlipped];
    CGFloat x = self.isVertical ? NSMidX(track) : NSMidX(knobRect);
    CGFloat y = self.isVertical ? NSMidY(knobRect) : NSMidY(track);
    NSRect rect = NSInsetRect(NSMakeRect(x - width / 2, y - height / 2, width, height), .25, .25);
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:5 yRadius:5];
    CGFloat opacity = self.isEnabled ? 1 : .45;
    [NSGraphicsContext saveGraphicsState];
    NSShadow* shadow = [NSShadow new];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(self.isHighlighted ? .24 : .16) * opacity];
    shadow.shadowBlurRadius = 1; shadow.shadowOffset = NSMakeSize(0, -1); [shadow set];
    NSGradient* fill = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:1 alpha:opacity]
        endingColor:[NSColor colorWithCalibratedWhite:.94 alpha:opacity]];
    [fill drawInBezierPath:path angle:self.controlView.isFlipped ? 90 : -90];
    [NSGraphicsContext restoreGraphicsState];
    [[NSColor.blackColor colorWithAlphaComponent:(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast ? .55 : .18) * opacity] setStroke];
    path.lineWidth = .5; [path stroke];
}
@end

@interface CTPluginEditor : NSObject <NSWindowDelegate, NSSearchFieldDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic) NSUInteger index;
@property(nonatomic, strong) NSSearchField* search;
@property(nonatomic, strong) NSScrollView* scroll;
@property(nonatomic, strong) NSArray<NSDictionary*>* parameters;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSNumber*>* addresses;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSSlider*>* sliders;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL nativeEditor;
@property(nonatomic) NSUInteger presentationRevision;
@property(nonatomic, strong) NSData* initialState;
@property(nonatomic, strong) NSDictionary* position;
- (void)open;
- (void)openContent;
- (void)showEditorError:(NSString*)message;
- (void)refreshValues;
- (void)rememberPosition;
- (void)restorePosition;
@end
static NSMutableDictionary<NSString*, CTPluginEditor*>* editors;
static NSMutableDictionary<NSString*, NSDictionary*>* editorPositions;

@implementation CTPluginEditor
- (void)open {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = [NSString stringWithFormat:@"%@ — CamiTune", slots[self.index][@"plugin"][@"name"]];
    self.window.releasedWhenClosed = NO;
    [self.window center]; [self restorePosition];
    self.window.delegate = self;
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self rememberPosition];
    [self openContent];
}
- (void)restorePosition {
    NSNumber* x = self.position[@"x"], *y = self.position[@"y"];
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]
        || !std::isfinite(x.doubleValue) || !std::isfinite(y.doubleValue)) return;
    NSPoint point = NSMakePoint(x.doubleValue, y.doubleValue);
    // A disconnected display must not leave the title bar unreachable.
    for (NSScreen* screen in NSScreen.screens) {
        if (NSPointInRect(NSMakePoint(point.x + 16, point.y - 16), screen.visibleFrame)) {
            [self.window setFrameTopLeftPoint:point]; return;
        }
    }
}
- (void)rememberPosition {
    if (self.closed) return;
    self.position = @{@"x": @(NSMinX(self.window.frame)), @"y": @(NSMaxY(self.window.frame))};
    editorPositions[slots[self.index][@"id"]] = self.position;
    emit(@{@"event": @"editorPosition", @"slotID": slots[self.index][@"id"], @"position": self.position});
}
- (void)windowDidMove:(NSNotification*)notification { [self rememberPosition]; }
- (void)openContent {
    self.nativeEditor = NO; self.sliders = nil;
    self.initialState = nil;
    self.window.subtitle = @"";
    NSView* parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];
    self.window.contentView = parent;
    NSTextField* loading = [NSTextField labelWithString:@"Opening plug-in editor…"];
    loading.frame = NSMakeRect(24, 190, 500, 24); [parent addSubview:loading];
    // Capture before editing; a linked rack is rebuilt only when its complete
    // preset changes. Ordinary viewing must not reset its processing history.
    if (effects[self.index]->instanceCount() > 1) {
        @try { try { self.initialState = effects[self.index]->saveState(); } catch (...) {} }
        @catch (NSException*) {}
    }
    __weak CTPluginEditor* weak = self;
    @try { try {
    effects[self.index]->editor(parent, ^(NSView* view, NSString* error) {
        CTPluginEditor* owner = weak; if (!owner || owner.closed) return;
        [loading removeFromSuperview];
        if (error) { [owner showEditorError:error]; return; }
        if (view) {
            NSSize size = view.frame.size;
            if (owner.window.contentView != view) owner.window.contentView = view;
            if (size.width > 0 && size.height > 0) [owner.window setContentSize:size];
            owner.nativeEditor = YES;
            if (effects[owner.index]->instanceCount() > 1)
                owner.window.subtitle = @"Linked channels · Preset changes apply to all channels when this window closes";
            emit(@{@"event": @"editorOpened", @"slotID": slots[owner.index][@"id"], @"native": @YES});
        } else { [owner showParameters]; }
    });
    } catch (const std::exception& error) { [self showEditorError:@(error.what())]; }
    } @catch (NSException*) { [self showEditorError:@"The plug-in could not open its native editor. Try opening it again."]; }
}
- (void)showEditorError:(NSString*)message {
    NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 240)]; self.window.contentView = root;
    [self.window setContentSize:root.frame.size];
    NSTextField* label = [NSTextField wrappingLabelWithString:message];
    label.frame = NSMakeRect(24, 105, 512, 100); [root addSubview:label];
    NSButton* retry = [NSButton buttonWithTitle:@"Retry Native Editor" target:self action:@selector(retryEditor:)];
    retry.frame = NSMakeRect(24, 48, 190, 32); [root addSubview:retry];
    NSButton* controls = [NSButton buttonWithTitle:@"Parameter Controls" target:self action:@selector(openParameters:)];
    controls.frame = NSMakeRect(232, 48, 190, 32); [root addSubview:controls];
    emit(@{@"event": @"editorError", @"slotID": slots[self.index][@"id"], @"message": message});
}
- (void)retryEditor:(id)sender { effects[self.index]->closeEditor(); [self openContent]; }
- (void)openParameters:(id)sender { effects[self.index]->closeEditor(); [self showParameters]; }
- (void)showParameters {
    self.nativeEditor = NO;
    self.window.subtitle = @"Plug-in parameter controls";
    self.parameters = effects[self.index]->parameters(); self.addresses = [NSMutableDictionary dictionary]; self.sliders = [NSMutableDictionary dictionary];
    NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)]; self.window.contentView = root;
    [self.window setContentSize:NSMakeSize(560, 420)];
    self.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(16, 378, 528, 26)]; self.search.placeholderString = @"Search parameters"; self.search.delegate = self; [root addSubview:self.search];
    self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, 528, 350)]; self.scroll.hasVerticalScroller = YES; [root addSubview:self.scroll];
    [self rebuildParameters];
    emit(@{@"event": @"editorOpened", @"slotID": slots[self.index][@"id"], @"native": @NO});
}
- (void)controlTextDidChange:(NSNotification*)notification { [self rebuildParameters]; }
- (void)rebuildParameters {
    NSString* query = self.search.stringValue;
    NSMutableArray* visible = [NSMutableArray array];
    for (NSDictionary* p in self.parameters) if (!query.length || [p[@"name"] localizedCaseInsensitiveContainsString:query]) [visible addObject:p];
    NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 510, std::max(350.0, visible.count * 54.0))];
    [self.addresses removeAllObjects];
    [self.sliders removeAllObjects];
    NSUInteger count = 0;
    for (NSDictionary* p in visible) {
        CGFloat y = content.frame.size.height - (++count) * 54;
        NSTextField* label = [NSTextField labelWithString:p[@"name"]]; label.frame = NSMakeRect(0, y + 29, 490, 20); [content addSubview:label];
        NSSlider* slider = [NSSlider new]; slider.cell = [CTSettingsSliderCell new];
        slider.minValue = [p[@"min"] doubleValue]; slider.maxValue = [p[@"max"] doubleValue]; slider.doubleValue = [p[@"value"] doubleValue];
        slider.target = self; slider.action = @selector(parameterChanged:);
        slider.frame = NSMakeRect(0, y + 5, 490, 24); slider.tag = count; slider.continuous = YES;
        slider.accessibilityLabel = p[@"name"]; self.addresses[@(count)] = p[@"id"]; self.sliders[p[@"id"]] = slider; [content addSubview:slider];
    }
    if (!visible.count) { NSTextField* label = [NSTextField labelWithString:self.parameters.count ? @"No matching parameters." : @"This plug-in has no editable parameters."]; label.frame = NSMakeRect(0, 300, 500, 24); [content addSubview:label]; }
    self.scroll.documentView = content;
    [self refreshValues];
}
- (void)refreshValues {
    if (self.closed) return;
    for (NSNumber* identifier in self.sliders) {
        NSSlider* slider = self.sliders[identifier];
        if (!slider.cell.isHighlighted) {
            double value = midiHost->parameterValue(self.index, identifier.unsignedLongLongValue, slider.doubleValue);
            if (slider.doubleValue != value) slider.doubleValue = value;
        }
    }
}
- (void)parameterChanged:(NSSlider*)sender { effects[self.index]->setParameter([self.addresses[@(sender.tag)] unsignedLongLongValue], sender.doubleValue); }
- (void)windowWillClose:(NSNotification*)notification {
    [self rememberPosition];
    self.closed = YES; effects[self.index]->closeEditor();
    NSString* identifier = slots[self.index][@"id"];
    emit(@{@"event": @"editorClosing", @"slotID": identifier});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        // A quick reopen owns a new window. Its eventual close will capture
        // the state; an old callback must not dismiss that new editor.
        if (editors[identifier] != self) return;
        const bool captured = snapshot(self.index);
        NSData* preset = savedStates[identifier];
        const bool linkedNative = self.nativeEditor && effects[self.index]->instanceCount() > 1;
        const bool reload = captured && linkedNative && preset && ![preset isEqual:self.initialState];
        NSMutableDictionary* event = [@{@"event": @"editorClosed", @"slotID": identifier, @"requiresReload": @(reload)} mutableCopy];
        if (reload) event[@"state"] = [preset base64EncodedStringWithOptions:0];
        if (linkedNative && !captured) emit(@{@"event": @"snapshotError", @"slotID": identifier,
            @"message": @"The plug-in could not save its full settings for the linked channels."});
        emit(event);
        if (editors[identifier] == self) [editors removeObjectForKey:identifier];
        openEditorCount = (unsigned)editors.count;
    });
}
@end

#ifdef CAMITUNE_PLUGIN_TESTING
#include "FixtureEffect.h"
#endif

static int runRack(NSString* configPath, NSString* memoryPath, NSString* socketPath) {
    NSDictionary* config = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:configPath] options:0 error:nil];
    double rate = [config[@"sampleRate"] doubleValue];
    slots = config[@"slots"];
    NSArray<NSString*>* roles = config[@"channelRoles"];
    if (![roles isKindOfClass:NSArray.class] || roles.count < 1 || roles.count > maximumChannels)
        throw std::runtime_error("Invalid plug-in channel layout.");
    for (id role in roles) if (![role isKindOfClass:NSString.class]) throw std::runtime_error("Invalid channel role.");
    uint32_t channels = (uint32_t)roles.count;
    size_t mainBytes = maximumFrames * channels * sizeof(float);
    size_t sharedBytes = mainBytes + maximumFrames * 2 * slots.count * sizeof(float);
    if (![slots isKindOfClass:NSArray.class] || slots.count > 16 || !std::isfinite(rate) || rate < 8000 || rate > 384000) throw std::runtime_error("Invalid plug-in rack configuration.");
    savedStates = [NSMutableDictionary dictionary]; editors = [NSMutableDictionary dictionary];
    editorPositions = [NSMutableDictionary dictionary];
    for (NSDictionary* slot in slots) {
        NSString* format = slot[@"plugin"][@"format"];
        emit(@{@"event": @"loading", @"slotID": slot[@"id"] ?: @"", @"name": slot[@"plugin"][@"name"] ?: @"Plug-in"});
        if ([format isEqual:@"AU"] || [format isEqual:@"VST3"]) effects.push_back(makeChannelEffect(slot, rate, roles));
#ifdef CAMITUNE_PLUGIN_TESTING
        else if ([format isEqual:@"Test"]) effects.push_back(std::make_unique<FixtureEffect>(slot, channels));
#endif
        else throw std::runtime_error("Unsupported plug-in format.");
        if ([slot[@"state"] isKindOfClass:NSString.class]) savedStates[slot[@"id"]] = [[NSData alloc] initWithBase64EncodedString:slot[@"state"] options:0];
    }
    midiHost = std::make_unique<MIDIHost>(effects, slots);
    int file = open(memoryPath.fileSystemRepresentation, O_RDWR | O_NOFOLLOW);
    struct stat info{};
    if (file < 0 || fstat(file, &info) || info.st_size != sharedBytes || info.st_uid != getuid()) throw std::runtime_error("Invalid shared audio buffer.");
    float* samples = (float*)mmap(nullptr, sharedBytes, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0); close(file);
    if (samples == MAP_FAILED) throw std::runtime_error("Could not map the shared audio buffer.");
    audioSocket = socket(AF_UNIX, SOCK_STREAM, 0); sockaddr_un address{}; address.sun_family = AF_UNIX;
    if (socketPath.length >= sizeof(address.sun_path)) throw std::runtime_error("The audio socket path is too long.");
    strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    if (connect(audioSocket, (sockaddr*)&address, sizeof(address))) throw std::runtime_error("Could not connect the audio stream.");
    int noSignal = 1; setsockopt(audioSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    bool editorOnly = [config[@"editorOnly"] boolValue];
    // 32 channels exceed the default macOS worker stack once an AU renders.
    // Allocate and touch all scratch storage before starting the audio thread.
    struct AudioBuffers {
        std::array<std::array<float, maximumFrames>, maximumChannels> first{}, second{};
        std::array<std::array<float, maximumFrames>, 2> sidechain{};
    };
    auto buffers = std::make_shared<AudioBuffers>();
    std::thread worker([samples, editorOnly, channels, buffers] {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        auto& first = buffers->first; auto& second = buffers->second;
        AudioRequest request{};
        while (true) {
            pollfd descriptor{audioSocket, POLLIN, 0};
            int available = poll(&descriptor, 1, 10);
            if (available < 0 && errno == EINTR) continue;
            if (available < 0) break;
            if (available == 0) {
                // A quiet socket is not a gap in the audio timeline: a normal
                // 1024-frame block at 48 kHz spans more than two 10 ms polls.
                // Rendering hidden silence here destroys effect history between
                // real blocks. Only flush edits, with zero samples, at rest.
                if (audioFailed.load() || (!editorOnly && !openEditorCount.load() && !midiHost->needsIdle())) continue;
                @autoreleasepool {
                    midiHost->process();
                    for (auto& effect : effects) if (!effect->flushParameters()) { audioFailed = true; break; }
                }
                continue;
            }
            if (!transfer(audioSocket, &request, sizeof(request), false)) break;
            AudioReply reply{protocolVersion, 0, request.sequence, 0};
            if (request.version != protocolVersion || request.frames == 0 || request.frames > maximumFrames || audioFailed.load()) reply.status = 1;
            else {
                @autoreleasepool {
                    for (uint32_t f = 0; f < request.frames; ++f) for (uint32_t c = 0; c < channels; ++c) first[c][f] = samples[f * channels + c];
                    if (request.reset) for (auto& effect : effects) effect->reset();
                    midiHost->process();
                    float* input[maximumChannels], *output[maximumChannels];
                    for (uint32_t c = 0; c < channels; ++c) { input[c] = first[c].data(); output[c] = second[c].data(); }
                    for (size_t index = 0; index < effects.size(); ++index) {
                        auto& effect = effects[index];
                        const float* external = samples + maximumFrames * channels + index * maximumFrames * 2;
                        for (uint32_t f = 0; f < request.frames; ++f) for (uint32_t c = 0; c < 2; ++c)
                            buffers->sidechain[c][f] = std::isfinite(external[f * 2 + c]) ? external[f * 2 + c] : 0;
                        float* sidechain[2]{buffers->sidechain[0].data(), buffers->sidechain[1].data()};
                        effect->setSidechain(sidechain);
                        for (uint32_t c = 0; c < channels; ++c) memset(output[c], 0, request.frames * sizeof(float));
                        if (!effect->render(input, output, request.frames)) { reply.status = 2; break; }
                        for (uint32_t c = 0; c < channels; ++c) std::swap(input[c], output[c]);
                    }
                    for (uint32_t f = 0; f < request.frames; ++f) for (uint32_t c = 0; c < channels; ++c) {
                        float value = input[c][f];
                        if (!std::isfinite(value)) { reply.status = 3; value = 0; }
                        samples[f * channels + c] = value;
                    }
                }
            }
            if (reply.status) audioFailed = true;
            if (!transfer(audioSocket, &reply, sizeof(reply), true)) break;
        }
        // The parent owns the rack lifetime. EOF must also close any editors.
        _exit(0);
    });
    worker.detach();
    uint64_t latency = 0; double tail = 0;
    NSMutableArray* instances = [NSMutableArray array];
    NSMutableArray* capabilities = [NSMutableArray array];
    for (size_t i = 0; i < effects.size(); ++i) [capabilities addObject:@{@"slotID": slots[i][@"id"],
        @"instrument": @(effects[i]->isInstrument()), @"sidechainBuses": effects[i]->sidechainBuses()}];
    for (auto& effect : effects) { latency += effect->latency(); tail += effect->tailSeconds(); [instances addObject:@(effect->instanceCount())]; }
    emit(@{@"event": @"ready", @"version": @(protocolVersion), @"channels": @(channels), @"instances": instances,
        @"capabilities": capabilities, @"latencyFrames": @(latency), @"tailSeconds": @(std::min(10.0, tail))});
    __block NSMutableData* commands = [NSMutableData data];
    dispatch_source_t inputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(inputSource, ^{
        char bytes[4096]; ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count <= 0) _exit(0);
        [commands appendBytes:bytes length:count]; if (commands.length > 1024 * 1024) _exit(2);
        while (true) {
            const char* start = (const char*)commands.bytes; const char* end = (const char*)memchr(start, '\n', commands.length);
            if (!end) break;
            NSData* data = [NSData dataWithBytes:start length:end - start]; [commands replaceBytesInRange:NSMakeRange(0, end - start + 1) withBytes:nullptr length:0];
            NSDictionary* command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([command[@"command"] isEqual:@"configureMIDI"]) {
                midiHost->configure(command[@"configuration"] ?: @{});
                emit(@{@"event": @"midiConfigured"});
            }
            midiHost->command(command);
#ifdef CAMITUNE_PLUGIN_TESTING
            // Exercise the real editor/parameter paths without opening windows
            // or audio devices in the host regression suite. Never in Release.
            if ([command[@"command"] isEqual:@"testControl"]) {
                if (command[@"editorOpen"]) openEditorCount = [command[@"editorOpen"] boolValue] ? 1 : 0;
                NSUInteger index = [command[@"index"] unsignedIntegerValue];
                if (index < effects.size() && command[@"parameter"] && command[@"value"])
                    effects[index]->setParameter([command[@"parameter"] unsignedLongLongValue], [command[@"value"] doubleValue]);
                emit(@{@"event": @"testControl", @"parameters": index < effects.size() ? effects[index]->parameters() : @[]});
            }
#endif
            if ([command[@"command"] isEqual:@"quit"]) { snapshot(); _exit(0); }
            if ([command[@"command"] isEqual:@"snapshot"] || [command[@"command"] isEqual:@"closeEditors"]) {
                NSMutableArray<NSDictionary*>* closingEditors = [NSMutableArray array];
                if ([command[@"command"] isEqual:@"closeEditors"]) {
                    for (CTPluginEditor* editor in editors.allValues)
                        [closingEditors addObject:@{@"editor": editor, @"revision": @(editor.presentationRevision)}];
                }
                // Allow the audio worker to consume the last UI parameter edit
                // before taking a processor-state snapshot, including at rest.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    snapshot();
                    for (NSDictionary* target in closingEditors) {
                        CTPluginEditor* editor = target[@"editor"];
                        if (!editor.closed && editor.presentationRevision == [target[@"revision"] unsignedIntegerValue])
                            [editor.window close];
                    }
                    NSString* response = command[@"response"];
                    if ([response isKindOfClass:NSString.class] && [response hasPrefix:@"snapshot-"]) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(@{@"event": response}); });
                    }
                });
            }
            if ([command[@"command"] isEqual:@"editor"]) {
                NSString* identifier = command[@"slotID"];
                for (NSUInteger i = 0; i < slots.count; ++i) if ([slots[i][@"id"] isEqual:identifier]) {
                    CTPluginEditor* editor = editors[identifier];
                    if (!editor || editor.closed) {
                        editor = [CTPluginEditor new]; editor.index = i;
                        editor.position = [command[@"position"] isKindOfClass:NSDictionary.class] ? command[@"position"] : editorPositions[identifier];
                        editors[identifier] = editor; openEditorCount = (unsigned)editors.count; [editor open];
                    }
                    else {
                        // A new open request supersedes a queued delayed close.
                        ++editor.presentationRevision;
                        [editor.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
                    }
                }
            }
        }
    });
    dispatch_resume(inputSource);
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*) {
        midiHost->idle();
        for (CTPluginEditor* editor in editors.allValues) [editor refreshValues];
    }];
    __block uint64_t previousLatency = latency;
    __block double previousTail = std::min(10.0, tail);
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer*) {
        try {
            uint64_t currentLatency = 0; double currentTail = 0;
            for (auto& effect : effects) {
                effect->idle(); currentLatency += effect->latency(); currentTail += effect->tailSeconds();
                std::string failure = effect->failure();
                if (!failure.empty() && !audioFailed.exchange(true)) emit(@{@"event": @"error", @"message": @(failure.c_str())});
            }
            currentTail = std::min(10.0, currentTail);
            if (currentLatency != previousLatency || currentTail != previousTail) {
                previousLatency = currentLatency; previousTail = currentTail;
                emit(@{@"event": @"latency", @"latencyFrames": @(currentLatency), @"tailSeconds": @(currentTail)});
            }
            if (openEditorCount.load() || midiHost->takeStateChanges()) snapshot();
        } catch (const std::exception& error) { emit(@{@"event": @"error", @"message": @(error.what())}); }
    }];
    [NSApp run]; return 0;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // Third-party stdout is never allowed to corrupt the control protocol.
        protocolFD = dup(STDOUT_FILENO); dup2(STDERR_FILENO, STDOUT_FILENO); signal(SIGPIPE, SIG_IGN);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        try {
            if (argc == 2 && !strcmp(argv[1], "--midi-sources")) { emit(@{@"event": @"scan", @"sources": midiSources()}); return 0; }
            if (argc == 2 && !strcmp(argv[1], "--scan-au")) { emit(@{@"event": @"scan", @"plugins": scanAU()}); return 0; }
            if (argc == 3 && !strcmp(argv[1], "--scan-vst3")) { emit(@{@"event": @"scan", @"plugins": scanVST3(@(argv[2]))}); return 0; }
            if (argc == 5 && !strcmp(argv[1], "--rack")) return runRack(@(argv[2]), @(argv[3]), @(argv[4]));
            emit(@{@"event": @"error", @"message": @"Invalid host arguments."}); return 2;
        } catch (const std::exception& error) { emit(@{@"event": @"error", @"message": @(error.what())}); return 1; }
    }
}
