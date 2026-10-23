#!/usr/bin/env python3
"""Exercise the real isolated AU/VST3 host without opening any audio device."""
import argparse
import base64
import json
import math
import mmap
import os
from pathlib import Path
import plistlib
import queue
import select
import socket
import statistics
import struct
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'build/plugin-host/camitune-plugin-host'

def build_test_vst(unicode_factory=False, instrument=False, architecture=None):
    name = 'CamiTune' + ('Instrument' if instrument else 'Unicode' if unicode_factory else '') + 'Test' + (architecture or '')
    bundle = ROOT / ('build/plugin-host/' + name + '.vst3')
    executable = bundle / 'Contents/MacOS/CamiTuneTest'
    executable.parent.mkdir(parents=True, exist_ok=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'CamiTuneTest', 'CFBundleIdentifier': 'org.camitune.test-effect',
        'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1', 'CFBundleName': 'CamiTune Test Gain'}))
    source = ROOT / 'Tools/CamiTunePluginHost'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-bundle', '-mmacosx-version-min=13.0',
                    *(['-DCAMITUNE_UNICODE_FACTORY=1'] if unicode_factory or instrument else []),
                    *(['-DCAMITUNE_INSTRUMENT=1'] if instrument else []),
                    *(['-arch', architecture] if architecture else []),
                    '-I' + str(source / 'vendor'), '-framework', 'CoreFoundation',
                    str(source / 'fixtures/TestVST3.cpp'), str(source / 'vendor/pluginterfaces/base/funknown.cpp'),
                    '-o', str(executable)], check=True)
    result = subprocess.run((['/usr/bin/arch', '-'+architecture] if architecture else []) + [str(HOST), '--scan-vst3', str(bundle)], check=True, capture_output=True)
    plugins = json.loads(result.stdout)['plugins']
    assert len(plugins) == 1
    if instrument: assert plugins[0]['kind'] == 'instrument', plugins
    if unicode_factory:
        assert plugins[0]['name'] == 'CamiTune Écho 音' and plugins[0]['manufacturer'] == 'Créateur 音', plugins
    return plugins[0]

def compatibility(plugin):
    for mode in [12, 13, 14, 16, 17]:
        for roles in [['left', 'right'], ['center'],
                      ['left', 'right', 'center', 'lowFrequencyEffects', 'leftSurround', 'rightSurround']]:
            channels = len(roles)
            with Rack([(plugin, {'state': state(.5, mode)})], roles=roles) as rack:
                assert rack.ready['latencyFrames'] == 0
                for frames in [1, 63, 128, 257, 1024, 2048]:
                    samples = [.01*(c+1)*math.sin(f*.03) for f in range(frames) for c in range(channels)]
                    expected = [x*.5 for x in samples]
                    if mode in [16, 17] and channels > 1:
                        pairs = [(0,1)] + ([(4,5)] if channels == 6 else [])
                        for f in range(frames):
                            for left,right in pairs:
                                mean = .25*(samples[f*channels+left]+samples[f*channels+right])
                                expected[f*channels+left] = expected[f*channels+right] = mean
                    status, output = rack.render(samples)
                    assert status == 0 and all(abs(a-b)<1e-6 for a,b in zip(expected,output)), (mode,roles,frames,status)
                rack.command('testControl', wait_for='testControl', editorOpen=True, parameter=0, value=.25)
                time.sleep(.08)  # parameter-only flush must retain the selected precision
                saved = next(iter(rack.snapshot().values()))
            with Rack([(plugin, {'state': saved})], roles=roles) as restored:
                status, output = restored.render([.2]*channels*128)
                assert status == 0 and all(abs(v-.05)<1e-6 for v in output), (mode,roles,'restored')
    unicode_plugin = build_test_vst(unicode_factory=True)
    # Failed native layout negotiation creates linked copies from the same
    # factory; host context must survive that instance's destruction.
    with Rack([(unicode_plugin, {}), (unicode_plugin, {})], roles=['unknown']*6) as rack:
        status, output = rack.render([.2]*6*128)
        assert status == 0 and all(abs(v-.05)<1e-6 for v in output)
    print('PASS: VST3 64-bit-only DSP, fixed auxiliary buses, declined-but-valid layouts, mono/stereo adaptation, Unicode factories and shared host context')

def compatibility_au():
    for variant in [1, 2, 3]:
        plugin = dict(id='test-au-'+str(variant), name='AU compatibility fixture', manufacturer='CamiTune Tests',
                      format='AU', location='', componentType=0x61756678, componentSubtype=variant, componentManufacturer=0x43545473)
        for roles in [['left', 'right'], ['center'], ['left', 'right', 'center', 'lowFrequencyEffects', 'leftSurround', 'rightSurround']]:
            channels = len(roles)
            with Rack([(plugin, {})], roles=roles) as rack:
                assert rack.ready['latencyFrames'] == 0
                for frames in [1, 63, 128, 257, 1024, 2048]:
                    samples = [.01*(c+1)*math.sin(f*.03) for f in range(frames) for c in range(channels)]
                    expected = [x*.5 for x in samples]
                    if variant in [1, 2] and channels > 1:
                        for f in range(frames):
                            for left,right in [(0,1)] + ([(4,5)] if channels == 6 else []):
                                mean = .25*(samples[f*channels+left]+samples[f*channels+right])
                                expected[f*channels+left] = expected[f*channels+right] = mean
                    status, output = rack.render(samples)
                    assert status == 0 and all(abs(a-b)<1e-6 for a,b in zip(expected,output)), (variant,roles,frames,status)
    print('PASS: AU canonical stereo negotiation and mono/stereo adaptation in mono, stereo and surround racks')

class Rack:
    def __init__(self, plugins, sample_rate=48000, editor_only=False, roles=None, architecture=None):
        self.roles = roles if roles is not None else ["left", "right"]
        self.channels = len(self.roles)
        self.temp = tempfile.TemporaryDirectory(prefix='ct-host-test-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.buffer_file = (self.root / 'audio').open('w+b')
        self.buffer_file.truncate(2048 * (self.channels + 2 * len(plugins)) * 4)
        self.memory = mmap.mmap(self.buffer_file.fileno(), 2048 * (self.channels + 2 * len(plugins)) * 4)
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.root / 'socket')); self.listener.listen(1); self.listener.settimeout(20)
        slots = [dict(id=str(uuid.uuid4()).upper(), plugin=plugin, isEnabled=True, **extra) for plugin, extra in plugins]
        self.slots = slots
        (self.root / 'rack.json').write_text(json.dumps(dict(sampleRate=sample_rate, slots=slots, channelRoles=self.roles, editorOnly=editor_only)))
        self.process = subprocess.Popen((['/usr/bin/arch', '-'+architecture] if architecture else []) + [str(HOST), '--rack', str(self.root / 'rack.json'), str(self.root / 'audio'), str(self.root / 'socket')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.connection = None
        try:
            deadline = time.monotonic() + 20
            while True:
                assert select.select([self.process.stdout], [], [], max(0, deadline-time.monotonic()))[0], 'Host preparation timed out'
                line = self.process.stdout.readline()
                assert line, 'Host exited during preparation'
                event = json.loads(line)
                if event.get('event') == 'error': raise AssertionError(event)
                if event.get('event') == 'ready': self.ready = event; break
            self.connection, _ = self.listener.accept(); self.connection.settimeout(2)
        except BaseException:
            self.close(); raise
        self.sequence = 0
        self.events = queue.Queue()
        self.states = {}
        def read_events():
            for line in self.process.stdout:
                event = json.loads(line)
                if event.get('event') == 'state': self.states[event['slotID']] = event['state']
                else: self.events.put(event)
        self.reader = threading.Thread(target=read_events, daemon=True)
        self.reader.start()

    def command(self, command, wait_for=None, **values):
        self.process.stdin.write((json.dumps(dict(command=command, **values))+'\n').encode())
        self.process.stdin.flush()
        if wait_for:
            deadline = time.monotonic() + 3
            while True:
                event = self.events.get(timeout=max(.001, deadline-time.monotonic()))
                if event.get('event') == wait_for: return event
                assert event.get('event') != 'error', event

    def snapshot(self):
        token = 'snapshot-' + str(uuid.uuid4())
        self.command('snapshot', response=token)
        deadline = time.monotonic() + 3
        while True:
            event = self.events.get(timeout=max(.001, deadline-time.monotonic()))
            if event.get('event') == token: return self.states
            assert event.get('event') != 'error', event

    def render(self, samples, version=3, reset=False, sidechains=None):
        assert len(samples) % self.channels == 0
        self.sequence += 1
        self.memory[:len(samples)*4] = struct.pack('<' + 'f'*len(samples), *samples)
        for index in range(len(self.slots)):
            data = (sidechains or {}).get(index, [0.0] * (len(samples)//self.channels*2))
            offset = 2048 * (self.channels + index*2) * 4
            self.memory[offset:offset+len(data)*4] = struct.pack('<'+'f'*len(data), *data)
        self.connection.sendall(struct.pack('<4I', version, len(samples)//self.channels, self.sequence, int(reset)))
        response = bytearray()
        while len(response) < 16:
            part = self.connection.recv(16-len(response))
            if not part: raise EOFError('host exited')
            response.extend(part)
        protocol, status, sequence, _ = struct.unpack('<4I', response)
        assert protocol == 3 and sequence == self.sequence
        result = struct.unpack('<' + 'f'*len(samples), self.memory[:len(samples)*4])
        return status, result

    def close(self):
        if getattr(self, 'connection', None): self.connection.close()
        if getattr(self, 'process', None):
            if self.process.poll() is None: self.process.kill()
            self.process.wait(timeout=5)
            if getattr(self, 'reader', None): self.reader.join(timeout=2)
            self.process.stdin.close(); self.process.stdout.close()
        self.listener.close(); self.memory.close(); self.buffer_file.close(); self.temp.cleanup()
    def __enter__(self): return self
    def __exit__(self, *_): self.close()

def state(gain=0.5, mode=0):
    return base64.b64encode(plistlib.dumps({'component': struct.pack('<fI', gain, mode)}, fmt=plistlib.FMT_BINARY)).decode()

def continuity(plugin, sample_rate=48000, frames=1024, blocks=12, controls=False, extra=None):
    """The editor's idle path must not insert DSP time between real blocks.

    No audio device or editor window is opened. The Debug-only command enables
    the editor's worker idle path without touching the user's desktop.
    Compare identical continuous input, allowing the worker to idle each block.
    """
    result = []
    timings = []
    with Rack([(plugin, extra or {})], sample_rate=sample_rate) as reference, \
         Rack([(plugin, extra or {})], sample_rate=sample_rate) as edited:
        parameters = edited.command('testControl', wait_for='testControl', editorOpen=True)['parameters']
        for block in range(blocks):
            if controls:
                assert parameters, 'No editable parameters to exercise'
                parameter = parameters[0]
                value = parameter['min'] + (parameter['max']-parameter['min']) * (.2 + .6*block/max(1, blocks-1))
                for rack in [reference, edited]:
                    rack.command('testControl', wait_for='testControl', parameter=parameter['id'], value=value)
            samples = [0.2 * math.sin(2 * math.pi * 997 * (block * frames + f) / sample_rate)
                       for f in range(frames) for _ in range(2)]
            a, expected = reference.render(samples, reset=block == 0)
            start = time.perf_counter()
            b, actual = edited.render(samples, reset=block == 0)
            timings.append((time.perf_counter()-start)*1000)
            assert a == b == 0
            result.extend(abs(x-y) for x, y in zip(expected, actual))
            time.sleep(max(.025, frames / sample_rate))
    peak = max(result)
    print(json.dumps(dict(test='editor_timeline_continuity', plugin=plugin['name'],
                         sample_rate=sample_rate, frames=frames, peak_error=peak,
                         controls=controls, roundtrip_ms_max=max(timings),
                         rms_error=math.sqrt(sum(x*x for x in result)/len(result)))))
    assert peak < 1e-6, 'Editor idle processing changed the audible waveform'

def parameter_flush(plugin):
    # A stateful VST3 reports processed frames separately from parameter flushes.
    # Offline editing must reach saved component state without a single extra
    # audio frame; an unchanged editor must not keep invoking the processor.
    with Rack([(plugin, {'state': state(.5, 4)})], editor_only=True) as rack:
        assert rack.render([.1]*2048, reset=True)[0] == 0
        rack.command('testControl', wait_for='testControl', parameter=0, value=.75)
        saved = plistlib.loads(base64.b64decode(rack.snapshot()[rack.slots[0]['id']]))
        gain, mode, frames, flushes = struct.unpack('<fIQQ', saved['component'])
        assert gain == .75 and mode == 4 and frames == 1024 and flushes == 1, (gain, mode, frames, flushes)
        time.sleep(.1)
        unchanged = plistlib.loads(base64.b64decode(rack.snapshot()[rack.slots[0]['id']]))
        assert unchanged == saved, 'Unchanged editor kept invoking DSP'
        assert rack.render([.1]*2048)[0] == 0, 'Parameter flush advanced the VST3 sample clock'
    print('PASS: VST3 edits persist at rest with zero audio frames and no redundant processing')

LAYOUTS = {
    'mono': ['center'], 'stereo': ['left', 'right'],
    'quad': ['left', 'right', 'leftSurround', 'rightSurround'],
    '5.1': ['left', 'right', 'center', 'lowFrequencyEffects', 'leftSurround', 'rightSurround'],
}
LAYOUTS['7.1'] = LAYOUTS['5.1'] + ['leftRearSurround', 'rightRearSurround']
for base in ['5.1', '7.1']:
    LAYOUTS[base+'.2'] = LAYOUTS[base] + ['topMiddleLeft', 'topMiddleRight']
    LAYOUTS[base+'.4'] = LAYOUTS[base] + ['topFrontLeft', 'topFrontRight', 'topRearLeft', 'topRearRight']
LAYOUTS['9.1.6'] = LAYOUTS['7.1'] + ['wideLeft', 'wideRight', 'topFrontLeft', 'topFrontRight',
                                               'topMiddleLeft', 'topMiddleRight', 'topRearLeft', 'topRearRight']

def multichannel_vst(plugin):
    # Every supported width, including odd counts and anonymous discrete buses.
    for channels in range(1, 33):
        roles = ['unknown'] * channels
        with Rack([(plugin, {})], roles=roles) as rack:
            assert rack.ready['channels'] == channels and rack.ready['instances'] == [channels]
            for frames in [1, 127, 1024, 2048]:
                samples = [.002 * (c+1) * math.cos(f*.03) for f in range(frames) for c in range(channels)]
                status, output = rack.render(samples)
                assert status == 0 and all(abs(a*.5-b) < 1e-6 for a,b in zip(samples,output)), channels
            rack.command('testControl', wait_for='testControl', editorOpen=True, parameter=0, value=.25)
            saved = rack.snapshot()[rack.slots[0]['id']]
            samples = [.01*(c+1) for f in range(128) for c in range(channels)]
            status, output = rack.render(samples)
            assert status == 0 and all(abs(a*.25-b) < 1e-6 for a,b in zip(samples,output)), 'Controls did not reach every copy'
        if channels in [1, 3, 6, 16, 32]:
            with Rack([(plugin, {'state': saved})], roles=roles) as restored:
                status, output = restored.render(samples)
                assert status == 0 and all(abs(a*.25-b) < 1e-6 for a,b in zip(samples,output)), 'Preset lost linked settings'
    print('PASS: VST3 all 1–32 channel widths, odd/discrete buses, linked controls and preset restoration')
    for name, roles in LAYOUTS.items():
        for mode in [5, 6]:  # native multichannel and mono-only fallback
            with Rack([(plugin, {'state': state(.5, mode)})], roles=roles) as rack:
                assert rack.ready['instances'] == [1 if mode == 5 else len(roles)], (name,mode,rack.ready)
                samples = [.01*(c+1) for f in range(257) for c in range(len(roles))]
                status, output = rack.render(samples)
                assert status == 0 and all(abs(a*.5-b) < 1e-6 for a,b in zip(samples,output)), (name, mode)
    # Deliberately scramble both 5.1 and 7.1. Each native bus index has a unique
    # gain, so a symmetric-but-wrong host permutation cannot pass.
    for canonical in [LAYOUTS['5.1'], ['left','right','center','lowFrequencyEffects',
                                     'leftRearSurround','rightRearSurround','leftSurround','rightSurround']]:
        roles = list(reversed(canonical))
        with Rack([(plugin, {'state': state(.5, 8)})], roles=roles) as rack:
            assert rack.ready['instances'] == [1]
            samples = [.01*(c+1) for f in range(63) for c in range(len(roles))]
            status, output = rack.render(samples)
            expected = [x*.5*(canonical.index(roles[i%len(roles)])+1) for i,x in enumerate(samples)]
            assert status == 0 and all(abs(a-b)<1e-6 for a,b in zip(expected,output)), 'VST3 speaker order was wrong'
    # A stereo effect deliberately mixes L/R. C and LFE must not get paired;
    # the semantic front/surround pairs must work even in a shuffled bus order.
    roles = ['lowFrequencyEffects','rightSurround','center','right','leftSurround','left']
    with Rack([(plugin, {'state':state(1,9)})], roles=roles) as rack:
        assert rack.ready['instances'] == [4]
        for source in range(6):
            samples = [float(c==source)*.2 for f in range(64) for c in range(6)]
            status, output = rack.render(samples, reset=True)
            pairs = {1:4, 4:1, 3:5, 5:3}
            expected = [.2 if c==source and source not in pairs else
                        .15 if c==source else .05 if pairs.get(source)==c else 0 for c in range(6)]*64
            assert status==0 and all(abs(a-b)<1e-6 for a,b in zip(expected,output)), 'Speaker groups crossed'
    print('PASS: native surround/height buses, mono-only fallback, canonical VST3 order, isolated center/LFE and semantic stereo pairs')

def multichannel_au(scan):
    plugin = next(p for p in scan if p['name'] == 'AUBandpass')
    # A single-channel impulse may not appear on a different speaker. Exercise
    # all widths natively and the linked-stereo path using the same actual AU.
    for channels in range(1,33):
        roles = ['unknown']*channels
        with Rack([(plugin,{})], roles=roles) as rack:
            samples = [.1 if f==0 and c==channels-1 else 0 for f in range(128) for c in range(channels)]
            status, output = rack.render(samples, reset=True)
            assert status==0 and all(math.isfinite(x) for x in output)
            assert any(abs(output[f*channels+channels-1])>1e-8 for f in range(128))
            assert all(abs(x)<1e-8 for i,x in enumerate(output) if i%channels != channels-1), channels
    for roles in [LAYOUTS['5.1'], LAYOUTS['9.1.6'], ['unknown']*32]:
        with Rack([(plugin,{'testMaximumChannels':2})], roles=roles) as rack:
            assert rack.ready['instances'][0]>1
            parameters=rack.command('testControl',wait_for='testControl',editorOpen=True)['parameters']
            p=parameters[0]
            for block in range(12):
                value=p['min']+(p['max']-p['min'])*(.2+.5*block/11)
                rack.command('testControl',wait_for='testControl',parameter=p['id'],value=value)
                samples=[.2*math.sin((block*1024+f)*.12) for f in range(1024) for _ in roles]
                status, output=rack.render(samples,reset=block==0)
                assert status==0
                peak=max(abs(output[i]-output[(i//len(roles))*len(roles)]) for i in range(len(output)))
                assert peak<1e-6, ('AU linked parameters diverged',len(roles),peak)
                time.sleep(.025)  # retain the editor/crackle regression
    print('PASS: Apple AU all 1–32 widths, channel isolation and linked 5.1/9.1.6/32-channel editor sweeps')

def midi_input(plugin):
    source = 123456789  # Synthetic tests never subscribe to a user's device.
    def configure(rack, mappings=None, **changes):
        value = dict(isEnabled=True, sourceID=source, mappings=mappings or [])
        value.update(changes)
        rack.command('configureMIDI', wait_for='midiConfigured', configuration=value)
        rack.render([.2]*(128*rack.channels))  # publish the configuration before sending events
    def send(rack, status=0xb0, data1=7, data2=127, source_id=source):
        rack.command('testMIDI', wait_for='testMIDI', messages=[dict(source=source_id, status=status, data1=data1, data2=data2)])
    def gain(rack, expected):
        status, output = rack.render([.2]*256)
        assert status == 0 and all(abs(v-.2*expected)<1e-6 for v in output), (expected, output[:4])
    with Rack([(plugin, {})]) as rack:
        slot = rack.slots[0]['id']
        parameters = rack.command('parameters', wait_for='parameters', slotID=slot)['parameters']
        assert parameters[0]['name'] == 'Gain'
        mapping = dict(slotID=slot, parameterID=0, channel=1, controller=7, sourceID=source, lower=0, upper=1, pickup=True)
        configure(rack, [mapping])
        send(rack, data2=0); gain(rack, .5)  # pickup avoids a sudden jump
        send(rack, data2=127); gain(rack, 1) # crossing acquires control
        send(rack, data2=32); gain(rack, 32/127)
        send(rack, data2=127, source_id=source+1); gain(rack, 32/127)
        send(rack, status=0xb1, data2=127); gain(rack, 32/127)
        rack.command('setParameter', slotID=slot, parameterID=0, value=.8)
        time.sleep(.06)
        send(rack, data2=33); gain(rack, .8) # editor edit rearms pickup
        send(rack, data2=127); gain(rack, 1)
        configure(rack, [dict(mapping, lower=.8, upper=.2, pickup=False)])
        send(rack, data2=127); gain(rack, .2)
        for curve, transform in [('linear', lambda x:x), ('soft', math.sqrt), ('hard', lambda x:x*x), ('sCurve', lambda x:x*x*(3-2*x))]:
            configure(rack, [dict(mapping, lower=.8, upper=.2, pickup=False, curve=curve)])
            for value in [0, 32, 64, 127]:
                send(rack, data2=value); gain(rack, .8 - .6*transform(value/127))
        configure(rack, [dict(mapping, mode='button', lower=.2, upper=.8)])
        send(rack, data2=127); gain(rack, .8)
        send(rack, data2=0); gain(rack, .2)
        configure(rack, [dict(mapping, mode='toggle', lower=.2, upper=.8)])
        send(rack, data2=127); gain(rack, .8)
        send(rack, data2=127); gain(rack, .8)  # held button must not toggle twice
        send(rack, data2=0); gain(rack, .8)
        send(rack, data2=127); gain(rack, .2)
        note = dict(mapping, input='note', controller=60, mode='toggle', lower=.2, upper=.8)
        configure(rack, [note])
        send(rack, status=0x90, data1=60, data2=1); gain(rack, .8)  # quiet notes still press a button
        send(rack, status=0x80, data1=60, data2=64); gain(rack, .8)
        send(rack, status=0x90, data1=60, data2=100); gain(rack, .2)
        configure(rack, [dict(note, mode='button')])
        send(rack, status=0x90, data1=60, data2=10); gain(rack, .8)
        send(rack, status=0x90, data1=60, data2=0); gain(rack, .2)
        configure(rack, [dict(note, mode='velocity', curve='hard')])
        send(rack, status=0x90, data1=60, data2=64); gain(rack, .2 + .6*(64/127)**2)
        send(rack, status=0x80, data1=60, data2=100); gain(rack, .2 + .6*(64/127)**2)
        send(rack, data1=60, data2=127); gain(rack, .2 + .6*(64/127)**2)  # CC with same number is independent
        configure(rack, [dict(mapping, pickup=False, lower=.2, upper=.2)])
        send(rack, data2=127); gain(rack, .2)
        configure(rack, [mapping], isEnabled=False)
        send(rack, data2=127); gain(rack, .2)
        configure(rack)
        rack.command('learnMIDI', slotID=slot, parameterID=0)
        send(rack, data1=21)
        learned = rack.command('parameters', wait_for='midiLearned', slotID=slot)
        assert learned['parameterID']==0 and learned['controller']==21 and learned['sourceID']==source
        rack.command('learnMIDI', slotID=slot, parameterID=0)
        send(rack, status=0x90, data1=127, data2=64)
        learned_note = rack.command('parameters', wait_for='midiLearned', slotID=slot)
        assert learned_note['input']=='note' and learned_note['controller']==127
        rack.command('watchParameter', slotID=slot)
        rack.command('setParameter', slotID=slot, parameterID=0, value=.65)
        touched = rack.command('parameters', wait_for='parameterTouched', slotID=slot)
        assert touched['parameterID']==0
        saved = plistlib.loads(base64.b64decode(rack.snapshot()[slot]))
        assert abs(struct.unpack('<fI', saved['component'])[0]-.65)<1e-6
    for channels in [1, 6, 32]:
        with Rack([(plugin, {})], roles=['unknown']*channels) as rack:
            mapping = dict(slotID=rack.slots[0]['id'], parameterID=0, channel=1, controller=7, sourceID=source, lower=0, upper=1, pickup=False)
            configure(rack, [mapping]); send(rack, data2=95)
            status, output = rack.render([.2]*(128*channels))
            assert status==0 and all(abs(v-.2*95/127)<1e-6 for v in output)
            rack.command('testMIDI',wait_for='testMIDI',messages=[dict(source=source,status=0xb0,data1=7,data2=i%128) for i in range(256)])
            status, output = rack.render([.2]*(128*channels))
            assert status==0 and all(abs(v-.2)<1e-6 for v in output), 'A controller burst lost its final value'
    with Rack([(plugin, {'state':state(.5,10)})]) as rack:
        # Older profiles can contain this flag. Forward notes and controllers
        # even when it was saved as false, without affecting mapping consumption.
        configure(rack, sendsToPlugins=False)
        gain(rack,0)
        send(rack,status=0x90,data1=60,data2=100); gain(rack,.5)
        send(rack,data2=127); gain(rack,1) # VST3 IMidiMapping, without a CamiTune mapping
        send(rack,status=0x80,data1=60,data2=0); gain(rack,0)
        send(rack,status=0x91,data1=67,data2=100); gain(rack,1)
        rack.command('midiPanic', wait_for='midiPanic')
        rack.command('midiPanic', wait_for='midiPanic'); gain(rack,0)
        send(rack,status=0x90,data1=60,data2=100); gain(rack,1)
        configure(rack,isEnabled=False); gain(rack,0)
        configure(rack)
        # A burst above the per-cycle event budget must release held notes.
        rack.command('testMIDI',wait_for='testMIDI', messages=[dict(source=source,status=0x90,data1=i%128,data2=100) for i in range(500)])
        gain(rack,0)
    print('PASS: MIDI curves, velocity, momentary/toggle buttons, note Learn, MIDI Learn, pickup/reacquisition, ranges, source/channel filters, disabled input, linked channels, automatic note/controller forwarding with legacy settings, VST3 controller assignments and panic')
    virtual_midi(plugin)

def program_changes(plugin):
    source = 123456789
    au = dict(id='test-au-programs', name='AU program fixture', manufacturer='CamiTune Tests',
              format='AU', location='', componentType=0x61756d66, componentSubtype=6, componentManufacturer=0x43545473)
    for descriptor, extra, steps in [(plugin, {'state': state(.5, 24)}, 3), (au, {}, 127)]:
        for channels in [2, 6, 32]:
            with Rack([(descriptor, extra), (descriptor, extra)], roles=['unknown']*channels) as rack:
                first, second = [slot['id'] for slot in rack.slots]
                config = dict(isEnabled=True, sourceID=source, mappings=[])
                def configure(**changes):
                    config.update(changes)
                    rack.command('configureMIDI', wait_for='midiConfigured', configuration=config)
                    rack.render([.2]*(128*channels))
                def send(program, channel=1, input_source=source):
                    rack.command('testMIDI', wait_for='testMIDI', messages=[dict(source=input_source,
                        status=0xc0+channel-1, data1=program, data2=0)])
                def check(expected):
                    status, output = rack.render([.2]*(128*channels))
                    assert status == 0 and all(abs(v-.2*expected)<1e-6 for v in output), (descriptor['format'], channels, expected, output[:4])
                configure()
                send(steps); check(.25)  # old profiles default to Off
                configure(programChangeSlotID=second)
                send(steps, input_source=source+1); check(.25)
                send(steps); check(.5)  # only the second slot changes
                send(0, channel=16); check(0)
                send(steps, channel=16); check(.5)
                configure(channel=2)
                send(0); check(.5)
                send(1, channel=2); check(.5/steps)
                if steps < 127:
                    send(steps+1, channel=2); check(.5/steps)  # do not clamp to the last program
                    snapshot = rack.snapshot()
                    values = [struct.unpack('<fI', plistlib.loads(base64.b64decode(snapshot[s]))['component'])[0] for s in [first, second]]
                    assert abs(values[0]-.5)<1e-6 and abs(values[1]-1/steps)<1e-6, values
                    with Rack([(descriptor, {'state': snapshot[second]})], roles=rack.roles) as restored:
                        status, output = restored.render([.2]*(128*channels))
                        assert status == 0 and all(abs(v-.2/steps)<1e-6 for v in output), 'Program state did not restore'
                configure(isEnabled=False)
                send(0, channel=2); check(.5/steps)
                configure(isEnabled=True, programChangeSlotID=str(uuid.uuid4()))
                send(0, channel=2); check(.5/steps)  # removed/other-helper destination
                configure(programChangeSlotID=first)
                send(steps, channel=2); check(1/steps)
                configure(programChangeSlotID=None)
                send(0, channel=2); check(1/steps)
    # Program selection must never narrow parameter mappings to that slot.
    with Rack([(plugin, {'state': state(.5, 24)}), (plugin, {'state': state(.5, 24)})]) as rack:
        first, second = [slot['id'] for slot in rack.slots]
        mappings = [dict(slotID=slot, parameterID=0, channel=1, controller=7,
                         sourceID=source, lower=0, upper=1, pickup=False) for slot in [first, second]]
        for destination in [first, second, str(uuid.uuid4()), None]:
            rack.command('configureMIDI', wait_for='midiConfigured', configuration=dict(
                isEnabled=True, sourceID=source, mappings=mappings, programChangeSlotID=destination))
            rack.render([.2]*256)
            for value in [32, 96]:
                rack.command('testMIDI', wait_for='testMIDI', messages=[dict(
                    source=source, status=0xb0, data1=7, data2=value)])
                status, output = rack.render([.2]*256)
                expected = .2 * (value/127)**2
                assert status == 0 and all(abs(v-expected)<1e-6 for v in output), 'Program destination restricted profile mappings'
    print('PASS: mappings reach both plug-ins with either program destination, an unavailable destination, or Off')
    # A multitimbral VST3 maps MIDI channels to distinct program parameters.
    with Rack([(plugin, {'state': state(.5, 25)})]) as rack:
        slot = rack.slots[0]['id']
        rack.command('configureMIDI', wait_for='midiConfigured', configuration=dict(isEnabled=True,
            sourceID=source, mappings=[], programChangeSlotID=slot))
        for channel, program, expected, parameter in [(1, 2, 2/3, 1), (2, 2, 2/7, 2), (3, 0, 2/7, 2), (2, 127, 2/7, 2)]:
            rack.command('testMIDI', wait_for='testMIDI', messages=[dict(source=source,status=0xc0+channel-1,data1=program,data2=0)])
            status, output = rack.render([.2]*256)
            assert status == 0 and all(abs(v-.2*expected)<1e-6 for v in output), (channel, output[:4])
            saved = plistlib.loads(base64.b64decode(rack.snapshot()[slot]))
            assert struct.unpack('<fII', saved['component'])[2] == parameter
    with Rack([(plugin, {'state': state(.5, 11)})]) as rack:
        rack.command('configureMIDI', wait_for='midiConfigured', configuration=dict(isEnabled=True,
            sourceID=source, mappings=[], programChangeSlotID=rack.slots[0]['id']))
        rack.command('testMIDI', wait_for='testMIDI', messages=[dict(source=source,status=0xc0,data1=127,data2=0)])
        status, output = rack.render([.2]*256)
        assert status == 0 and all(abs(v-.1)<1e-6 for v in output), 'Unsupported plug-in changed'
    print('PASS: AU two-byte program changes; VST3 program scaling, bounds and channel/unit selection; destination isolation, Off, filters, missing targets, saved state and linked 2/6/32-channel racks')

def virtual_midi(plugin, architecture=None):
    executable = ROOT/'build/plugin-host/test-midi-source'
    subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-framework','CoreMIDI','-framework','CoreFoundation',
        str(ROOT/'Tools/CamiTunePluginHost/fixtures/TestMIDISource.mm'),'-o',str(executable)],check=True)
    process = subprocess.Popen([str(executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    try:
        source = int(process.stdout.readline())
        with Rack([(plugin, {'state':state(.5,10)})], architecture=architecture) as rack:
            rack.command('configureMIDI',wait_for='midiConfigured',configuration=dict(isEnabled=True,sourceID=source,mappings=[],programChangeSlotID=rack.slots[0]['id']))
            def send(status,data1,data2):
                process.stdin.write(f'{status} {data1} {data2}\n'); process.stdin.flush()
                assert process.stdout.readline().strip()=='sent'
                time.sleep(.03)
            send(0x90,60,100)
            status, output=rack.render([.2]*256)
            assert status==0 and all(abs(v-.1)<1e-6 for v in output), output[:4]
            send(0xc0,3,0)
            status, output=rack.render([.2]*256)
            assert status==0 and all(abs(v-.2)<1e-6 for v in output), ('CoreMIDI program change', output[:4])
            while not rack.events.empty(): rack.events.get_nowait()
            process.stdin.close(); process.wait(timeout=5)
            deadline = time.monotonic()+3
            notifications=[]
            while True:
                event=rack.events.get(timeout=max(.001,deadline-time.monotonic()))
                notifications.append(event)
                if event.get('event')=='midiStatus' and event.get('connected')==0: break
                assert time.monotonic()<deadline, notifications
            status, output=rack.render([.2]*256)
            assert status==0 and all(v==0 for v in output), 'Disconnect left a held note'
        print('PASS: real CoreMIDI virtual-source discovery, notes/program changes, routing and disconnect note release')
    finally:
        if process.poll() is None: process.kill(); process.wait()
        if not process.stdin.closed: process.stdin.close()
        process.stdout.close()

def midi_au(scan):
    plugin = next(p for p in scan if p['name']=='AULowpass')
    for roles in [['left','right'], ['unknown']*6, ['unknown']*32]:
        extra = {'testMaximumChannels':2} if len(roles)>2 else {}
        with Rack([(plugin,extra)],roles=roles) as mapped, Rack([(plugin,extra)],roles=roles) as reference:
            slot = mapped.slots[0]['id']
            parameter = mapped.command('parameters',wait_for='parameters',slotID=slot)['parameters'][0]
            mapping = dict(slotID=slot,parameterID=parameter['id'],channel=1,controller=21,sourceID=123456789,lower=0,upper=1,pickup=False)
            mapped.command('configureMIDI',wait_for='midiConfigured',configuration=dict(isEnabled=True,sourceID=123456789,mappings=[mapping]))
            for block in range(24):
                cc = 25+block*3
                mapped.command('testMIDI',wait_for='testMIDI',messages=[dict(source=123456789,status=0xb0,data1=21,data2=cc)])
                value = parameter['min']+(parameter['max']-parameter['min'])*cc/127
                reference.command('testControl',wait_for='testControl',parameter=parameter['id'],value=value)
                samples = [.1*math.sin((block*1024+f)*.1) for f in range(1024) for _ in roles]
                a,expected=reference.render(samples,reset=block==0)
                b,actual=mapped.render(samples,reset=block==0)
                assert a==b==0
                assert max(abs(x-y) for x,y in zip(expected,actual))<1e-5, ('AU MIDI waveform diverged',len(roles),block)
                time.sleep(.025)
            # AUv2 may report scheduled automation through the UI observer.
            # Choose in Editor must ignore those echoes and still catch a mouse edit.
            time.sleep(.1)
            while not mapped.events.empty(): mapped.events.get_nowait()
            mapped.command('watchParameter',slotID=slot)
            mapped.command('parameters',wait_for='parameters',slotID=slot)
            mapped.command('testMIDI',messages=[dict(source=123456789,status=0xb0,data1=21,data2=85)])
            time.sleep(.05); mapped.render([.1]*(1024*len(roles))); time.sleep(.1)
            events=[]
            while not mapped.events.empty(): events.append(mapped.events.get_nowait())
            assert not any(e['event']=='parameterTouched' for e in events), ('AU automation was treated as a UI gesture',len(roles),events)
            mapped.command('setParameter',slotID=slot,parameterID=parameter['id'],value=parameter['min']+(parameter['max']-parameter['min'])*.3)
            touched=mapped.command('parameters',wait_for='parameterTouched',slotID=slot)
            assert touched['parameterID']==parameter['id']
            mapped.command('testMIDI',wait_for='testMIDI',messages=[dict(source=123456789,status=0xb0,data1=21,data2=100)])
            time.sleep(.12)  # No render: an offline editor must still save this edit.
            expected=parameter['min']+(parameter['max']-parameter['min'])*100/127
            actual=mapped.command('testControl',wait_for='testControl')['parameters'][0]['value']
            assert abs(actual-expected)<.01, ('Stopped AU did not reflect MIDI',len(roles),actual,expected)
            saved=mapped.snapshot()[slot]
            with Rack([(plugin,dict(extra,state=saved))],roles=roles) as restored:
                actual=restored.command('testControl',wait_for='testControl')['parameters'][0]['value']
                assert abs(actual-expected)<.01, ('Stopped AU MIDI edit was not saved',len(roles),actual,expected)
            # A newer mouse edit at rest must win when playback resumes.
            latest=parameter['min']+(parameter['max']-parameter['min'])*.25
            mapped.command('testControl',wait_for='testControl',parameter=parameter['id'],value=latest)
            status,_=mapped.render([.1]*(1024*len(roles)))
            actual=mapped.command('testControl',wait_for='testControl')['parameters'][0]['value']
            assert status==0 and abs(actual-latest)<.01, ('A stale MIDI event overrode a newer UI edit',len(roles),actual,latest)
    print('PASS: Apple AU MIDI parameter sweeps match editor controls in stereo and linked 6/32-channel racks without advancing audio history')
    print('PASS: AU Choose in Editor distinguishes MIDI automation from UI gestures')
    print('PASS: stopped AU MIDI edits update actual parameters and restore from saved presets without rendering hidden audio')


def expanded_compatibility(plugin):
    synth = build_test_vst(instrument=True)
    intel = build_test_vst(instrument=True, architecture='x86_64')
    virtual_midi(build_test_vst(architecture='x86_64'), architecture='x86_64')
    source = dict(kind='application', id='org.camitune.synthetic', name='Synthetic app', channelOffset=0)
    layouts = [['unknown']*n for n in range(1,33)]
    layouts += [['center', 'lowFrequencyEffects', 'right', 'left', 'leftSurround', 'rightSurround']]
    for current, architecture in [(synth, None), (intel, 'x86_64')]:
        for roles in layouts:
            for mode in [20,21]:
                with Rack([(current, {'state': state(.5, mode)})], roles=roles, architecture=architecture) as rack:
                    assert rack.ready['capabilities'][0]['instrument']
                    assert rack.ready['instances'] == [1], rack.ready
                    channels = len(roles)
                    dry = [.01*(c+1) for _ in range(128) for c in range(channels)]
                    status, output = rack.render(dry)
                    assert status == 0 and all(abs(a-b)<1e-6 for a,b in zip(output,dry))
                    rack.command('configureMIDI', wait_for='midiConfigured', configuration=dict(isEnabled=True,sourceID=123456789,mappings=[]))
                    rack.render(dry)
                    rack.command('testMIDI', wait_for='testMIDI', messages=[dict(source=123456789,status=0x90,data1=60,data2=100)])
                    status, output = rack.render(dry)
                    expected = dry[:]
                    for f in range(128):
                        if channels == 1: expected[f] += .075
                        else:
                            l = roles.index('left') if 'left' in roles else 0
                            r = roles.index('right') if 'right' in roles else 1
                            expected[f*channels+l] += .05; expected[f*channels+r] += .1
                    assert status == 0 and all(abs(a-b)<1e-6 for a,b in zip(output,expected)), (architecture, roles, mode, status,output[:channels],expected[:channels])
                    rack.command('testMIDI', wait_for='testMIDI', messages=[dict(source=123456789,status=0x80,data1=60,data2=0)])
                    status, output = rack.render(dry)
                    assert status == 0 and all(abs(a-b)<1e-6 for a,b in zip(output,dry)), ('panic',architecture,roles)
    for roles in layouts:
        channels = len(roles)
        generator = dict(id='test-generator',name='AU Generator',manufacturer='CamiTune Tests',format='AU',location='',
                         kind='instrument',componentType=0x6175676e,componentSubtype=4,componentManufacturer=0x43545473)
        with Rack([(generator,{})],roles=roles) as rack:
            dry = [.01*(c+1) for _ in range(128) for c in range(channels)]
            status,output = rack.render(dry)
            expected = dry[:]
            for f in range(128):
                if channels == 1: expected[f]+=.15
                else:
                    l = roles.index('left') if 'left' in roles else 0; r = roles.index('right') if 'right' in roles else 1
                    expected[f*channels+l]+=.1; expected[f*channels+r]+=.2
            assert status==0 and all(abs(a-b)<1e-6 for a,b in zip(output,expected)), ('AU generator',roles,status)
        au = dict(generator,id='test-sidechain',name='AU Sidechain',kind='effect',componentType=0x61756678,componentSubtype=5)
        for current, extra in [(plugin,{'state':state(.5,22)}),(plugin,{'state':state(.5,23)}),(au,{})]:
            with Rack([(current,dict(extra,sidechain=source))],roles=roles) as rack:
                assert len(rack.ready['capabilities'][0]['sidechainBuses'])==1
                dry = [.2]*channels*128
                status,output=rack.render(dry,sidechains={0:[.4,.4]*128})
                assert status==0 and all(abs(v-.04)<1e-6 for v in output), ('sidechain',current['format'],roles,extra,status,output[:channels])
                status,output=rack.render(dry)
                assert status==0 and all(v==0 for v in output), ('stale sidechain',roles)
    # Adjacent slots must read separate detector banks.
    with Rack([(plugin,{'state':state(.5,22),'sidechain':source}),(plugin,{'state':state(.5,23),'sidechain':source})]) as rack:
        status,output=rack.render([.2]*256,sidechains={0:[.4]*256,1:[.6]*256})
        assert status==0 and all(abs(v-.012)<1e-6 for v in output)
    print('PASS: native/Intel 32/64-bit MIDI instruments and AU generators use one voice engine, preserve dry audio and cover all 1–32 channels; AU/VST3 external sidechains route independently and clear missing input')

def apple_instruments(scan):
    plugin = next(p for p in scan if p['name'] == 'DLSMusicDevice')
    assert plugin['kind'] == 'instrument'
    for rate in [44100, 48000, 96000]:
        for channels in [1, 2, 6, 32]:
            with Rack([(plugin,{})], sample_rate=rate, roles=['unknown']*channels) as rack:
                assert rack.ready['instances'] == [1]
                rack.command('configureMIDI',wait_for='midiConfigured',configuration=dict(isEnabled=True,sourceID=123456789,mappings=[]))
                rack.render([0.0]*128*channels)
                rack.command('testMIDI',wait_for='testMIDI',messages=[dict(source=123456789,status=0x90,data1=60,data2=100)])
                peak = 0
                for _ in range(20):
                    status,output = rack.render([0.0]*128*channels)
                    assert status == 0 and all(math.isfinite(x) for x in output)
                    peak = max(peak,max(abs(x) for x in output))
                assert peak > 1e-5, (rate,channels,peak)
                rack.command('midiPanic',wait_for='midiPanic')
    print('PASS: Apple DLSMusicDevice MIDI note rendering in mono/stereo/6/32-channel profiles at 44.1/48/96 kHz')

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--audio-units', action='store_true'); parser.add_argument('--midi-only', action='store_true'); parser.add_argument('--expanded-only', action='store_true'); args = parser.parse_args()
    plugin = build_test_vst()
    if args.expanded_only:
        expanded_compatibility(plugin); return
    midi_input(plugin)
    program_changes(plugin)
    if args.midi_only: return
    timings = []
    with Rack([(plugin, {})]) as rack:
        assert rack.ready['latencyFrames'] == 0
        for frames in [1, 63, 128, 257, 1024, 2048] + [128] * 200:
            samples = [0.25 * math.sin(i * .11) for i in range(frames * 2)]
            start = time.perf_counter(); status, output = rack.render(samples); timings.append((time.perf_counter()-start)*1000)
            assert status == 0
            assert all(abs(a * 0.5 - b) < 1e-6 for a, b in zip(samples, output))
        status, _ = rack.render([0.0]*256, version=1)
        assert status != 0, 'invalid protocol accepted'
    print('PASS: VST3 discovery, variable blocks, exact processing and protocol validation')
    with Rack([(plugin, {'state': state(.25)}), (plugin, {'state': state(.5)})]) as rack:
        status, output = rack.render([.4]*256)
        assert status == 0 and all(abs(value-.05) < 1e-6 for value in output)
    print('PASS: persisted state and serial effect chain')
    continuity(plugin, extra={'state': state(.5, 4)})
    continuity(plugin, extra={'state': state(.5, 4)}, controls=True)
    parameter_flush(plugin)
    for mode, expected in [(1, EOFError), (2, socket.timeout), (3, None)]:
        with Rack([(plugin, {'state': state(.5, mode)})]) as rack:
            rack.connection.settimeout(.05)
            for _ in range(3): assert rack.render([.1]*256)[0] == 0
            if expected:
                try: rack.render([.1]*256)
                except expected: pass
                else: raise AssertionError('fault was not detected')
            else:
                status, output = rack.render([.1]*256)
                assert status == 3 and all(math.isfinite(value) for value in output)
    print('PASS: crash, hang and non-finite output containment')
    multichannel_vst(plugin)
    compatibility(plugin)
    compatibility_au()
    expanded_compatibility(plugin)
    if args.audio_units:
        scan = json.loads(subprocess.check_output([str(HOST), '--scan-au']))['plugins']
        midi_au(scan)
        apple_instruments(scan)
        chosen = next(p for p in scan if p['name'] == 'AUBandpass')
        with Rack([(chosen, {})]) as rack:
            for frames in [64, 128, 256, 1024, 2048]:
                status, output = rack.render([.1]*frames*2)
                assert status == 0 and all(math.isfinite(value) for value in output)
        print('PASS: Apple Audio Unit discovery, instantiation and rendering')
        for name in ['AUBandpass', 'AULowpass', 'AUHipass', 'AUParametricEQ']:
            chosen = next(p for p in scan if p['name'] == name)
            for controls in [False, True]: continuity(chosen, controls=controls, blocks=24)
        # Exercise short/long blocks and different hardware sample rates. The
        # deliberate inter-block wait also covers scheduler/input jitter.
        chosen = next(p for p in scan if p['name'] == 'AULowpass')
        for rate in [44100, 48000, 96000]:
            for frames in [128, 256, 512, 1024, 2048]:
                continuity(chosen, sample_rate=rate, frames=frames, controls=True)
        print('PASS: Apple AU editor continuity and control sweeps at 44.1/48/96 kHz, 128–2048 frames')
        multichannel_au(scan)
    timings.sort()
    print(json.dumps({'transport_roundtrip_ms_median': statistics.median(timings), 'transport_roundtrip_ms_p99': timings[int(len(timings)*.99)], 'note': 'Synthetic helper round trip, not device playback latency.'}))

if __name__ == '__main__': main()
