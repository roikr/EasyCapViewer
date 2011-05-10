/* Copyright (c) 2009, Ben Trask
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY BEN TRASK ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL BEN TRASK BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. */
#import "ECVCoreAudioSource.h"
#import <IOKit/audio/IOAudioDefines.h>

// Other Sources
#import "ECVDebug.h"
#import "ECVFoundationAdditions.h"

NSString *const ECVCoreAudioHardwareDevicesDidChangeNotification = @"ECVCoreAudioHardwareDevicesDidChange";

static OSStatus ECVCoreAudioHardwarePropertyListenerProc(AudioHardwarePropertyID propertyID, id obj)
{
	switch(propertyID) {
		case kAudioHardwarePropertyDevices: [[NSNotificationCenter defaultCenter] postNotificationName:ECVCoreAudioHardwareDevicesDidChangeNotification object:obj]; break;
	}
	return noErr;
}
static OSStatus ECVCoreAudioDeviceIOProc(AudioDeviceID inDevice, const AudioTimeStamp *inNow, const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime, ECVCoreAudioDevice *device)
{
	NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
	if(device.isInput) [device.delegate audioDevice:device didReceiveInput:inInputData atTime:inInputTime];
	else [device.delegate audioDevice:device didRequestOutput:outOutputData forTime:inOutputTime];
	[pool drain];
	return noErr;
}

@implementation ECVCoreAudioDevice

#pragma mark +NSObject

+ (void)initialize
{
	if([ECVCoreAudioDevice class] != self) return;
	ECVOSStatus(AudioHardwareAddPropertyListener(kAudioHardwarePropertyDevices, (AudioHardwarePropertyListenerProc)ECVCoreAudioHardwarePropertyListenerProc, self));
}

#pragma mark +ECVCoreAudioDevice

+ (NSArray *)allDevicesInput:(BOOL)flag
{
	NSMutableArray *const devices = [NSMutableArray array];
	UInt32 size = 0;
	ECVOSStatus(AudioHardwareGetPropertyInfo(kAudioHardwarePropertyDevices, &size, NULL));
	if(!size) return devices;
	AudioDeviceID *const deviceIDs = malloc(size);
	if(!deviceIDs) return devices;
	ECVOSStatus(AudioHardwareGetProperty(kAudioHardwarePropertyDevices, &size, deviceIDs));
	NSUInteger i = 0;
	for(; i < size / sizeof(AudioDeviceID); i++) {
		ECVCoreAudioDevice *const device = [[[self alloc] initWithDeviceID:deviceIDs[i] input:flag] autorelease];
		if([[device streams] count]) [devices addObject:device];
	}
	free(deviceIDs);
	return devices;
}
+ (id)defaultInputDevice
{
	AudioDeviceID deviceID = kAudioDeviceUnknown;
	UInt32 deviceIDSize = sizeof(deviceID);
	ECVOSStatus(AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice, &deviceIDSize, &deviceID));
	return [[[self alloc] initWithDeviceID:deviceID input:YES] autorelease];
}
+ (id)defaultOutputDevice
{
	AudioDeviceID deviceID = kAudioDeviceUnknown;
	UInt32 deviceIDSize = sizeof(deviceID);
	ECVOSStatus(AudioHardwareGetProperty(kAudioHardwarePropertyDefaultOutputDevice, &deviceIDSize, &deviceID));
	return [[[self alloc] initWithDeviceID:deviceID input:NO] autorelease];
}
+ (id)deviceWithUID:(NSString *)UID input:(BOOL)flag
{
	NSParameterAssert(UID);
	AudioDeviceID deviceID = kAudioDeviceUnknown;
	AudioValueTranslation deviceUIDTranslation = {
		&UID,
		sizeof(UID),
		&deviceID,
		sizeof(deviceID),
	};
	UInt32 translationSize = sizeof(deviceUIDTranslation);
	ECVOSStatus(AudioHardwareGetProperty(kAudioHardwarePropertyDeviceForUID, &translationSize, &deviceUIDTranslation));
	return [[[self alloc] initWithDeviceID:deviceID input:flag] autorelease];
}
+ (id)deviceWithIODevice:(io_service_t)device input:(BOOL)flag
{
	io_iterator_t iterator = IO_OBJECT_NULL;
	io_service_t subservice = IO_OBJECT_NULL;
	ECVIOReturn(IORegistryEntryCreateIterator(device, kIOServicePlane, kIORegistryIterateRecursively, &iterator));
	while((subservice = IOIteratorNext(iterator))) if(IOObjectConformsTo(subservice, kIOAudioEngineClassName)) {
		NSString *const UID = [(NSString *)IORegistryEntryCreateCFProperty(subservice, CFSTR(kIOAudioEngineGlobalUniqueIDKey), kCFAllocatorDefault, 0) autorelease];
		return UID ? [self deviceWithUID:UID input:flag] : nil;
	}
ECVGenericError:
ECVNoDeviceError:
	return nil;
}

#pragma mark -ECVCoreAudioDevice

- (id)initWithDeviceID:(AudioDeviceID)deviceID input:(BOOL)flag
{
	if((self = [super init])) {
		if(kAudioDeviceUnknown == deviceID) {
			[self release];
			return nil;
		}

		_deviceID = deviceID;
		_isInput = flag;

		Float64 rate = 0.0f;
		UInt32 rateSize= sizeof(rate);
		ECVOSStatus(AudioDeviceGetProperty([self deviceID], 0, [self isInput], kAudioDevicePropertyNominalSampleRate, &rateSize, &rate));

		AudioValueRange rateRange = {0.0f, 0.0f};
		UInt32 rangeSize = sizeof(rateRange);
		ECVOSStatus(AudioDeviceGetProperty([self deviceID], 0, [self isInput], kAudioDevicePropertyBufferFrameSizeRange, &rangeSize, &rateRange));

		UInt32 const size = (UInt32)CLAMP(rateRange.mMinimum, roundf(rate / 100.0f), rateRange.mMaximum); // Using either the minimum or the maximum frame size results in choppy audio. I don't know why the ideal buffer frame size is the 1% of the nominal sample rate, but it's what the MTCoreAudio framework uses and it works.
		ECVOSStatus(AudioDeviceSetProperty([self deviceID], NULL, 0, [self isInput], kAudioDevicePropertyBufferFrameSize, sizeof(size), &size));
	}
	return self;
}

#pragma mark -

@synthesize delegate;
@synthesize deviceID = _deviceID;
@synthesize isInput = _isInput;

#pragma mark -

- (NSString *)name
{
	if(_name) return [[_name retain] autorelease];
	NSString *name = nil;
	UInt32 nameSize = sizeof(name);
	ECVOSStatus(AudioDeviceGetProperty([self deviceID], 0, [self isInput], kAudioDevicePropertyDeviceNameCFString, &nameSize, &name));
	return [name autorelease];
}
- (void)setName:(NSString *)name
{
	if(ECVEqualObjects(_name, name)) return;
	[_name release];
	_name = [name copy];
}
- (NSArray *)streams
{
	UInt32 streamIDsSize = 0;
	ECVOSStatus(AudioDeviceGetPropertyInfo([self deviceID], 0, [self isInput], kAudioDevicePropertyStreams, &streamIDsSize, NULL));
	AudioStreamID *const streamIDs = malloc(streamIDsSize);
	ECVOSStatus(AudioDeviceGetProperty([self deviceID], 0, [self isInput], kAudioDevicePropertyStreams, &streamIDsSize, streamIDs));
	NSUInteger i = 0;
	NSMutableArray *const streams = [NSMutableArray array];
	for(; i < streamIDsSize / sizeof(AudioStreamID); i++) {
		ECVCoreAudioStream *const stream = [[[ECVCoreAudioStream alloc] initWithStreamID:streamIDs[i]] autorelease];
		[streams addObject:stream];
	}
	free(streamIDs);
	return streams;
}

#pragma mark -ECVSource

- (void)play
{
	if(_procID) return;
	if(noErr == AudioDeviceCreateIOProcID([self deviceID], (AudioDeviceIOProc)ECVCoreAudioDeviceIOProc, self, &_procID)) {
		if(noErr != AudioDeviceStart([self deviceID], _procID)) [self stop];
	}
}
- (void)stop
{
	if(!_procID) return;
	ECVOSStatus(AudioDeviceStop([self deviceID], _procID));
	ECVOSStatus(AudioDeviceDestroyIOProcID([self deviceID], _procID));
	_procID = NULL;
}

#pragma mark -NSObject

- (void)dealloc
{
	[self stop];
	[_name release];
	[super dealloc];
}

#pragma mark -<NSObject>

- (NSUInteger)hash
{
	return [[self class] hash] ^ _deviceID ^ _isInput;
}
- (BOOL)isEqual:(id)obj
{
	return [obj isKindOfClass:[ECVCoreAudioDevice class]] && [obj deviceID] == [self deviceID] && [obj isInput] == [self isInput];
}

#pragma mark -

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %p: %@ (%d, %@)>", [self class], self, [self name], [self deviceID], [self isInput] ? @"In" : @"Out"];
}

@end

@implementation NSObject(ECVCoreAudioDeviceDelegate)

- (void)audioDevice:(ECVCoreAudioDevice *)sender didReceiveInput:(AudioBufferList const *)bufferList atTime:(AudioTimeStamp const *)t {}
- (void)audioDevice:(ECVCoreAudioDevice *)sender didRequestOutput:(inout AudioBufferList *)bufferList forTime:(AudioTimeStamp const *)t {}

@end

@implementation ECVCoreAudioStream

#pragma mark -ECVCoreAudioStream

- (id)initWithStreamID:(AudioStreamID)streamID
{
	if((self = [super init])) {
		_streamID = streamID;
	}
	return self;
}

#pragma mark -

@synthesize streamID = _streamID;

#pragma mark -

- (AudioStreamBasicDescription)basicDescription
{
	AudioStreamBasicDescription description;
	UInt32 descriptionSize = sizeof(description);
	ECVOSStatus(AudioStreamGetProperty([self streamID], 0, kAudioStreamPropertyVirtualFormat, &descriptionSize, &description));
	return description;
}

#pragma mark -<NSObject>

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %p: %d>", [self class], self, [self streamID]];
}

@end