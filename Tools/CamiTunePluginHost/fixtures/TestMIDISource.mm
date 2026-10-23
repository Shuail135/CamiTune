// Ephemeral virtual input for the offline CoreMIDI integration test.
#import <CoreMIDI/CoreMIDI.h>
#include <cstdio>
int main() {
    MIDIClientRef client = 0; MIDIEndpointRef source = 0;
    if (MIDIClientCreate(CFSTR("CamiTune MIDI test"), nullptr, nullptr, &client)
        || MIDISourceCreateWithProtocol(client, CFSTR("CamiTune test input"), kMIDIProtocol_1_0, &source)) return 1;
    SInt32 id = 0; MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id);
    printf("%d\n", id); fflush(stdout);
    unsigned status, data1, data2;
    while (scanf("%u %u %u", &status, &data1, &data2) == 3) {
        MIDIEventList list; auto packet = MIDIEventListInit(&list, kMIDIProtocol_1_0);
        UInt32 word = (2u << 28) | (status << 16) | (data1 << 8) | data2;
        MIDIEventListAdd(&list, sizeof(list), packet, 0, 1, &word);
        MIDIReceivedEventList(source, &list);
        puts("sent"); fflush(stdout);
    }
    MIDIEndpointDispose(source); MIDIClientDispose(client); return 0;
}
