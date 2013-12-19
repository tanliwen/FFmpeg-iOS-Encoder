//
//  CameraServer.m
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "CameraServer.h"
#import "AVEncoder.h"
#import "RTSPServer.h"
#import "NALUnit.h"
#import "HLSWriter.h"
#import "AACEncoder.h"

static const int VIDEO_WIDTH = 1280;
static const int VIDEO_HEIGHT = 720;

static CameraServer* theServer;

@interface CameraServer  () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
{
    AVCaptureSession* _session;
    AVCaptureVideoPreviewLayer* _preview;
    AVCaptureVideoDataOutput* _videoOutput;
    AVCaptureAudioDataOutput* _audioOutput;
    dispatch_queue_t _videoQueue;
    dispatch_queue_t _audioQueue;
    AVCaptureConnection* _audioConnection;
    AVCaptureConnection* _videoConnection;
    
    AVEncoder* _encoder;
    
    RTSPServer* _rtsp;
}

@property (nonatomic, strong) NSData *naluStartCode;
@property (nonatomic, strong) NSFileHandle *debugFileHandle;
@property (nonatomic, strong) HLSWriter *hlsWriter;
@property (nonatomic, strong) NSMutableData *videoSPSandPPS;
@property (nonatomic, strong) AACEncoder *aacEncoder;

@end


@implementation CameraServer

+ (void) initialize
{
    // test recommended to avoid duplicate init via subclass
    if (self == [CameraServer class])
    {
        theServer = [[CameraServer alloc] init];
    }
}

+ (CameraServer*) server
{
    return theServer;
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
        return [devices objectAtIndex:0];
    
    return nil;
}

- (void) startup
{
    if (_session == nil)
    {
        NSLog(@"Starting up server");
        NSUInteger naluLength = 4;
        uint8_t *nalu = (uint8_t*)malloc(naluLength * sizeof(uint8_t));
        nalu[0] = 0x00;
        nalu[1] = 0x00;
        nalu[2] = 0x00;
        nalu[3] = 0x01;
        _naluStartCode = [NSData dataWithBytesNoCopy:nalu length:naluLength freeWhenDone:YES];
        
        _aacEncoder = [[AACEncoder alloc] init];

        // create capture device with video input
        _session = [[AVCaptureSession alloc] init];
        
        /*
         * Create audio connection
         */
        AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:[self audioDevice] error:nil];
        if ([_session canAddInput:audioIn])
            [_session addInput:audioIn];
        
        _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
        _audioQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
        [_audioOutput setSampleBufferDelegate:self queue:_audioQueue];
        if ([_session canAddOutput:_audioOutput])
            [_session addOutput:_audioOutput];
        _audioConnection = [_audioOutput connectionWithMediaType:AVMediaTypeAudio];
        
        
        AVCaptureDevice* dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:nil];
        [_session addInput:input];
        
        // create an output for YUV output with self as delegate
        _videoQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
        _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        [_videoOutput setSampleBufferDelegate:self queue:_videoQueue];
        NSDictionary* setcapSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], kCVPixelBufferPixelFormatTypeKey,
                                        nil];
        _videoOutput.videoSettings = setcapSettings;
        _videoOutput.alwaysDiscardsLateVideoFrames = YES;
        [_session addOutput:_videoOutput];
        
        
        // create an encoder
        _encoder = [AVEncoder encoderForHeight:VIDEO_HEIGHT andWidth:VIDEO_WIDTH];
        [_encoder encodeWithBlock:^int(NSArray* dataArray, double pts) {
            [self writeVideoFrames:dataArray pts:pts];
            //[self writeDebugFileForDataArray:dataArray pts:pts];
            if (_rtsp != nil)
            {
                _rtsp.bitrate = _encoder.bitspersecond;
                [_rtsp onVideoData:dataArray time:pts];
            }
            return 0;
        } onParams:^int(NSData *data) {
            _rtsp = [RTSPServer setupListener:data];
            return 0;
        }];
        
        // start capture and a preview layer
        [_session startRunning];
        
        
        _preview = [AVCaptureVideoPreviewLayer layerWithSession:_session];
        _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
        

    }
}

- (void) writeVideoFrames:(NSArray*)frames pts:(double)pts {
    if (pts == 0) {
        NSLog(@"PTS of 0, skipping frame");
        return;
    }
    NSError *error = nil;
    if (!_hlsWriter) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
        NSTimeInterval time = [[NSDate date] timeIntervalSince1970];
        NSString *folderName = [NSString stringWithFormat:@"%f.hls", time];
        NSString *hlsDirectoryPath = [basePath stringByAppendingPathComponent:folderName];
        [[NSFileManager defaultManager] createDirectoryAtPath:hlsDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
        self.hlsWriter = [[HLSWriter alloc] initWithDirectoryPath:hlsDirectoryPath];
        [_hlsWriter setupVideoWithWidth:VIDEO_WIDTH height:VIDEO_HEIGHT];
        [_hlsWriter prepareForWriting:&error];
        if (error) {
            NSLog(@"Error preparing for writing: %@", error);
        }
        NSData* config = _encoder.getConfigData;
        
        avcCHeader avcC((const BYTE*)[config bytes], [config length]);
        SeqParamSet seqParams;
        seqParams.Parse(avcC.sps());
        
        NSData* spsData = [NSData dataWithBytes:avcC.sps()->Start() length:avcC.sps()->Length()];
        NSData *ppsData = [NSData dataWithBytes:avcC.pps()->Start() length:avcC.pps()->Length()];
        
        _videoSPSandPPS = [NSMutableData dataWithCapacity:avcC.sps()->Length() + avcC.pps()->Length() + _naluStartCode.length * 2];
        [_videoSPSandPPS appendData:_naluStartCode];
        [_videoSPSandPPS appendData:spsData];
        [_videoSPSandPPS appendData:_naluStartCode];
        [_videoSPSandPPS appendData:ppsData];
        
        /*NSMutableData *naluSPS = [[NSMutableData alloc] initWithData:_naluStartCode];
        [naluSPS appendData:spsData];
        NSMutableData *naluPPS = [[NSMutableData alloc] initWithData:_naluStartCode];
        [naluPPS appendData:ppsData];
         */
        //[_hlsWriter processVideoData:videoSPSandPPS presentationTimestamp:pts-200];
        //[_hlsWriter processVideoData:ppsData presentationTimestamp:pts-100];
    }
    
    for (NSData *data in frames) {
        unsigned char* pNal = (unsigned char*)[data bytes];
        //int idc = pNal[0] & 0x60;
        int naltype = pNal[0] & 0x1f;
        NSData *videoData = nil;
        if (naltype == 5) { // IDR
            NSMutableData *IDRData = [NSMutableData dataWithData:_videoSPSandPPS];
            [IDRData appendData:_naluStartCode];
            [IDRData appendData:data];
            videoData = IDRData;
        } else {
            NSMutableData *regularData = [NSMutableData dataWithData:_naluStartCode];
            [regularData appendData:data];
            videoData = regularData;
        }
        //NSMutableData *nalu = [[NSMutableData alloc] initWithData:_naluStartCode];
        //[nalu appendData:data];
        //NSLog(@"%f: %@", pts, videoData.description);
        [_hlsWriter processEncodedData:videoData presentationTimestamp:pts streamIndex:0];
    }
    
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // pass frame to encoder
    if (connection == _videoConnection) {
        [_encoder encodeFrame:sampleBuffer];
    } else if (connection == _audioConnection) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double dPTS = (double)(pts.value) / pts.timescale;
        [_aacEncoder encodeSampleBuffer:sampleBuffer completionBlock:^(NSData *encodedData) {
            [_hlsWriter processEncodedData:encodedData presentationTimestamp:dPTS streamIndex:1];
        }];
    }
}

- (void) shutdown
{
    NSLog(@"shutting down server");
    if (_session)
    {
        [_session stopRunning];
        _session = nil;
    }
    if (_rtsp)
    {
        [_rtsp shutdownServer];
    }
    if (_encoder)
    {
        [ _encoder shutdown];
    }
    if (_debugFileHandle) {
        [_debugFileHandle closeFile];
    }
}

- (NSString*) getURL
{
    NSString* ipaddr = [RTSPServer getIPAddress];
    NSString* url = [NSString stringWithFormat:@"rtsp://%@/", ipaddr];
    return url;
}

- (AVCaptureVideoPreviewLayer*) getPreviewLayer
{
    return _preview;
}

@end
